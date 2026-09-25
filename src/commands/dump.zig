//! `ffmig dump`
//!
//! Writes the database's schema to `schema.sql`, or the `[dump] path` in
//! `ffmig.toml`: what `pg_dump --schema-only` prints, cleaned so that the
//! same schema always gives the same file (see `db.pg_dump.clean`), then
//! an insert of every applied migration into `schema_migrations`. So
//! `ffmig load` makes a database that `migrate` sees as up to date,
//! without running the migrations, and the file's diff in a pull request
//! shows what a migration really changed.
//!
//! With `[dump] auto = true`, `migrate`, `rollback` and `redo` dump after
//! changing the database (`after`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Env = @import("root.zig").Env;
const migrations = @import("migrations.zig");
const flags = @import("flags.zig");
const sql = @import("../sql/root.zig");
const db = @import("../db/root.zig");

pub const usage =
    \\Usage:
    \\
    \\      ffmig dump [flags]
    \\
    \\Write the database schema, and which migrations it has applied, to
    \\schema.sql or the [dump] path in ffmig.toml. Runs pg_dump, which must
    \\be as new as the server.
    \\
    \\Flags:
    \\
++ flags.config_option ++ flags.url_option ++ flags.help_option;

pub fn run(env: Env, args: []const []const u8, out: *Writer, err: *Writer) Writer.Error!u8 {
    if (args.len != 0) {
        try err.writeAll(usage);
        return 1;
    }

    var arena_state: std.heap.ArenaAllocator = .init(env.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var project = try migrations.Project.load(env, arena, err) orelse return 1;
    defer project.close(env.io);
    const conn = try project.connect(env, arena, err) orelse return 1;
    defer conn.db.close();
    return if (try dump(env, arena, project, conn, out, err)) 0 else 1;
}

/// Dumps after a `migrate`, `rollback` or `redo` that changed the
/// database, when `[dump] auto` is set. Reports failure to `err`, noting
/// that the migrations themselves went through, and returns false.
pub fn after(env: Env, arena: Allocator, project: migrations.Project, conn: migrations.Connection, out: *Writer, err: *Writer) Writer.Error!bool {
    if (!project.dump.auto) return true;
    if (try dump(env, arena, project, conn, out, err)) return true;
    try err.print("ffmig: the migrations ran, but {s} is out of date\n", .{project.dump.path.?});
    return false;
}

/// Writes the dump file. Reports failure to `err` and returns false.
pub fn dump(env: Env, arena: Allocator, project: migrations.Project, conn: migrations.Connection, out: *Writer, err: *Writer) Writer.Error!bool {
    const path = project.dump.path.?;
    const applied = try migrations.readApplied(arena, conn, err) orelse return false;
    const schema = try trackingSchema(arena, conn, err) orelse return false;
    const schema_sql = try runDump(env, arena, project, conn, err) orelse return false;

    var file: Writer.Allocating = .init(arena);
    write(arena, &file.writer, conn.dialect, schema_sql, schema, applied) catch {
        try migrations.outOfMemory(err);
        return false;
    };
    env.cwd.writeFile(env.io, .{ .sub_path = path, .data = file.written() }) catch |e| {
        try err.print("ffmig: cannot write {s}: {t}\n", .{ path, e });
        return false;
    };
    try out.print("Dumped the schema to {s}\n", .{path});
    return true;
}

/// The dump file: the cleaned schema, then the applied migrations.
fn write(
    arena: Allocator,
    w: *Writer,
    dialect: sql.Dialect,
    schema_sql: []const u8,
    schema: []const u8,
    applied: []const migrations.Applied,
) (Writer.Error || Allocator.Error)!void {
    try w.writeAll(schema_sql);
    if (applied.len == 0) return;
    const rows = try arena.alloc(sql.TrackingRow, applied.len);
    for (applied, rows) |a, *r| r.* = .{ .version = a.version, .checksum = a.checksum };
    try w.writeAll("\n--\n-- The migrations this schema has applied\n--\n\n");
    try sql.writeTracking(dialect, .{ .insert_all = .{ .schema = schema, .rows = rows } }, w);
    try w.writeAll(";\n");
}

/// The schema that holds the tracking table, which `readApplied` made
/// sure exists.
fn trackingSchema(arena: Allocator, conn: migrations.Connection, err: *Writer) Writer.Error!?[]const u8 {
    var statement: Writer.Allocating = .init(arena);
    sql.writeTracking(conn.dialect, .schema, &statement.writer) catch {
        try migrations.outOfMemory(err);
        return null;
    };
    var diag: db.Diagnostic = .{};
    const rows = conn.db.query(arena, statement.written(), &diag) catch |e| {
        try migrations.dbError(e, err, "cannot find " ++ sql.tracking_table, diag);
        return null;
    };
    if (rows.len == 0) {
        try err.writeAll("ffmig: cannot find " ++ sql.tracking_table ++ "\n");
        return null;
    }
    return rows[0][0].?;
}

/// Runs the dialect's dump program and returns its cleaned output.
fn runDump(env: Env, arena: Allocator, project: migrations.Project, conn: migrations.Connection, err: *Writer) Writer.Error!?[]const u8 {
    switch (conn.dialect) {
        .postgres => {
            const program = project.dump.pg_dump.?;
            const command = db.pg_dump.command(arena, program, conn.url, project.schema) catch return oomNull(err);
            var environ: std.process.Environ.Map = if (env.environ) |e| e.clone(arena) catch return oomNull(err) else .init(arena);
            if (command.password) |p| environ.put("PGPASSWORD", p) catch return oomNull(err);

            const result = env.run_program(env.io, arena, command.argv, &environ) catch |e| {
                switch (e) {
                    error.OutOfMemory => try migrations.outOfMemory(err),
                    error.ProgramNotFound => try err.print("ffmig: cannot run {s}: not found; install the PostgreSQL client tools, or set [dump] pg_dump in {s}\n", .{ program, env.config }),
                    error.CannotRunProgram => try err.print("ffmig: cannot run {s}\n", .{program}),
                }
                return null;
            };
            if (result.exit_code != 0) {
                try err.writeAll(result.stderr);
                if (result.stderr.len > 0 and result.stderr[result.stderr.len - 1] != '\n') try err.writeByte('\n');
                if (db.pg_dump.versionMismatch(result.stderr)) {
                    try err.print("ffmig: {s} is older than the server; install a newer PostgreSQL client, or set [dump] pg_dump in {s}\n", .{ program, env.config });
                } else {
                    try err.print("ffmig: {s} failed\n", .{program});
                }
                return null;
            }
            return db.pg_dump.clean(arena, result.stdout) catch return oomNull(err);
        },
    }
}

fn oomNull(err: *Writer) Writer.Error!?[]const u8 {
    try migrations.outOfMemory(err);
    return null;
}
