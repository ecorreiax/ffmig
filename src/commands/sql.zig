//! `ffmig sql [--down] <file>`
//!
//! Prints the SQL for a migration's `up` plan, or its `down` plan with
//! `--down`. A debugging and review tool: nothing touches a database.
//! Errors are reported like `ffmig check`; an irreversible `change`
//! migration has no `down` plan and fails with `--down`.

const std = @import("std");
const Writer = std.Io.Writer;
const Env = @import("root.zig").Env;
const check = @import("check.zig");
const mig = @import("../mig/root.zig");
const sql = @import("../sql/root.zig");

pub const usage = "Usage: ffmig sql [--down] <file>\n";

pub fn run(env: Env, args: []const []const u8, out: *Writer, err: *Writer) Writer.Error!u8 {
    var down = false;
    var file: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--down")) {
            down = true;
        } else if (std.mem.startsWith(u8, arg, "--") or file != null) {
            try err.writeAll(usage);
            return 1;
        } else {
            file = arg;
        }
    }
    const path = file orelse {
        try err.writeAll(usage);
        return 1;
    };

    var arena_state: std.heap.ArenaAllocator = .init(env.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source = env.cwd.readFileAlloc(env.io, path, arena, .limited(check.max_source_size)) catch |e| {
        try err.print("ffmig: cannot read {s}: {t}\n", .{ path, e });
        return 1;
    };

    var diag: mig.Diagnostic = .{};
    const migration = mig.parseMigration(arena, source, &diag) catch |e| switch (e) {
        error.OutOfMemory => return outOfMemory(err),
        error.InvalidSyntax, error.InvalidMigration => {
            try check.report(err, path, source, diag.span, "{s}", .{diag.message});
            return 1;
        },
    };

    const ops = if (!down) switch (migration.body) {
        .change => |ops| ops,
        .up_down => |b| b.up,
    } else plan: {
        const p = mig.reverse.plan(arena, migration, &diag) catch |e| switch (e) {
            error.OutOfMemory => return outOfMemory(err),
            error.Irreversible => {
                try check.report(err, path, source, diag.span, "{s}; use 'up' / 'down' blocks to make it reversible", .{diag.message});
                return 1;
            },
        };
        break :plan p.down;
    };

    try sql.write(.postgres, ops, out);
    return 0;
}

fn outOfMemory(err: *Writer) Writer.Error!u8 {
    try err.writeAll("ffmig: out of memory\n");
    return 1;
}
