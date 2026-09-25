const std = @import("std");
const Writer = std.Io.Writer;
const ffmig = @import("ffmig");
const commands = ffmig.commands;
const run = ffmig.cli.run;
const usage = ffmig.cli.usage;

const testing = std.testing;

fn expectRun(args: []const []const u8, code: u8, stdout: []const u8, stderr: []const u8) !void {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err: Writer.Allocating = .init(testing.allocator);
    defer err.deinit();

    try testing.expectEqual(code, try run(.{ .io = testing.io, .cwd = std.Io.Dir.cwd(), .gpa = testing.allocator }, args, &out.writer, &err.writer));
    try testing.expectEqualStrings(stdout, out.written());
    try testing.expectEqualStrings(stderr, err.written());
}

test "dispatches to init" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err: Writer.Allocating = .init(testing.allocator);
    defer err.deinit();

    const env: commands.Env = .{ .io = testing.io, .cwd = tmp.dir, .gpa = testing.allocator };
    try testing.expectEqual(0, try run(env, &.{"init"}, &out.writer, &err.writer));
    try testing.expectEqualStrings("Created ffmig.toml\nCreated migrations/\n", out.written());
    try testing.expectEqualStrings("", err.written());
}

test "help prints usage" {
    try expectRun(&.{"help"}, 0, usage, "");
}

test "unknown command fails" {
    try expectRun(&.{"nope"}, 1, "", "ffmig: unknown command 'nope'\n\n" ++ usage);
}

test "no command prints usage" {
    try expectRun(&.{}, 1, "", usage);
}

/// Runs `ffmig <args>` in `dir` with `environ` and checks the result.
fn expectRunIn(
    dir: std.Io.Dir,
    environ: ?*const std.process.Environ.Map,
    args: []const []const u8,
    code: u8,
    stdout: []const u8,
    stderr: []const u8,
) !void {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err: Writer.Allocating = .init(testing.allocator);
    defer err.deinit();

    const env: commands.Env = .{ .io = testing.io, .cwd = dir, .gpa = testing.allocator, .environ = environ };
    try testing.expectEqual(code, try run(env, args, &out.writer, &err.writer));
    try testing.expectEqualStrings(stdout, out.written());
    try testing.expectEqualStrings(stderr, err.written());
}

test "version" {
    const expected = "ffmig " ++ ffmig.version ++ "\n";
    try testing.expectEqualStrings("ffmig 0.1.0\n", expected);
    try expectRun(&.{"--version"}, 0, expected, "");
    try expectRun(&.{"version"}, 0, expected, "");
    try expectRun(&.{ "version", "x" }, 1, "", commands.version_usage);
    try expectRun(&.{ "--version", "x" }, 1, "", commands.version_usage);
    try expectRun(&.{ "version", "--help" }, 0, commands.version_usage, "");
}

test "-h and --help print usage" {
    try expectRun(&.{"-h"}, 0, usage, "");
    try expectRun(&.{"--help"}, 0, usage, "");
    try expectRun(&.{ "help", "--help" }, 0, commands.help_usage, "");
}

test "help for one command" {
    const migrate = commands.migrate.usage;
    try expectRun(&.{ "help", "migrate" }, 0, migrate, "");
    try expectRun(&.{ "-h", "migrate" }, 0, migrate, "");
    try expectRun(&.{ "migrate", "--help" }, 0, migrate, "");
    try expectRun(&.{ "migrate", "-h" }, 0, migrate, "");
    // Wins over other arguments, valid or not.
    try expectRun(&.{ "migrate", "--bogus", "--help" }, 0, migrate, "");
    try expectRun(&.{ "check", "a.mig", "-h" }, 0, commands.check.usage, "");
    try expectRun(&.{ "help", "help" }, 0, commands.help_usage, "");
    try expectRun(&.{ "help", "version" }, 0, commands.version_usage, "");

    try expectRun(&.{ "help", "nope" }, 1, "", "ffmig: unknown command 'nope'\n\n" ++ usage);
    try expectRun(&.{ "help", "migrate", "status" }, 1, "", commands.help_usage);
}

test "every usage lists its flags" {
    for (std.enums.values(commands.Command)) |command| {
        const text = commands.usage(command);
        const globals: commands.Globals = .of(command);
        const prefix = "Usage:\n\n      ffmig ";
        try testing.expect(std.mem.startsWith(u8, text, prefix));
        try testing.expect(std.mem.startsWith(u8, text[prefix.len..], @tagName(command)));
        try testing.expectEqual(command != .help and command != .version, std.mem.indexOf(u8, text, "-h, --help") != null);
        try testing.expectEqual(globals.config, std.mem.indexOf(u8, text, "--config <path>") != null);
        try testing.expectEqual(globals.url, std.mem.indexOf(u8, text, "--url <url>") != null);
    }
}

test "commands reject unknown flags with their usage" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    for (std.enums.values(commands.Command)) |command| {
        if (command == .help or command == .version) continue;
        try expectRunIn(tmp.dir, null, &.{ @tagName(command), "--bogus" }, 1, "", commands.usage(command));
        try expectRunIn(tmp.dir, null, &.{ @tagName(command), "-x" }, 1, "", commands.usage(command));
    }
    // Switches take no value.
    try expectRunIn(tmp.dir, null, &.{ "migrate", "--strict=yes" }, 1, "", commands.migrate.usage);
    try expectRunIn(tmp.dir, null, &.{ "check", "--ast=1" }, 1, "", commands.check.usage);
    // Commands that do not read the config do not take the shared flags.
    try expectRunIn(tmp.dir, null, &.{ "sql", "--url", "postgres://localhost/app", "a.mig" }, 1, "", commands.sql.usage);
    try expectRunIn(tmp.dir, null, &.{ "sql", "--config", "ffmig.toml", "a.mig" }, 1, "", commands.sql.usage);
    try expectRunIn(tmp.dir, null, &.{ "new", "--url", "postgres://localhost/app", "x" }, 1, "", commands.new.usage);
    try expectRunIn(tmp.dir, null, &.{ "check", "--url", "postgres://localhost/app" }, 1, "", commands.check.usage);
    // The shared flags need a value.
    try expectRunIn(tmp.dir, null, &.{ "status", "--url" }, 1, "", commands.status.usage);
    try expectRunIn(tmp.dir, null, &.{ "status", "--config=" }, 1, "", commands.status.usage);
}

test "flags take --name=value" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Past argument parsing: no ffmig.toml in the empty directory.
    const missing = "ffmig: ffmig.toml not found; run 'ffmig init' first\n";
    try expectRunIn(tmp.dir, null, &.{ "rollback", "--step=2", "--lock-wait=0" }, 1, "", missing);
    try expectRunIn(tmp.dir, null, &.{ "migrate", "--lock-wait=5", "--strict" }, 1, "", missing);
}

/// A project whose config names a PostgreSQL database, so a `mysql://` or
/// `sqlite://` error shows which URL won without connecting anywhere.
fn project(tmp: *testing.TmpDir) !void {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ffmig.toml", .data = "[database]\nurl = \"postgres://localhost/app\"\n" });
    try tmp.dir.createDirPath(testing.io, "migrations");
}

test "--url beats FFMIG_DATABASE_URL, which beats the config" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try project(&tmp);
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    const mysql = "ffmig: unsupported database 'mysql'; supported: postgres\n";
    const sqlite = "ffmig: unsupported database 'sqlite'; supported: postgres\n";
    try expectRunIn(tmp.dir, &environ, &.{ "status", "--url", "mysql://localhost/app" }, 1, "", mysql);
    try expectRunIn(tmp.dir, &environ, &.{ "migrate", "--url=mysql://localhost/app", "--strict" }, 1, "", mysql);
    try expectRunIn(tmp.dir, &environ, &.{ "create", "--url", "mysql://localhost/app" }, 1, "", mysql);

    try environ.put("FFMIG_DATABASE_URL", "sqlite://app.db");
    try expectRunIn(tmp.dir, &environ, &.{"status"}, 1, "", sqlite);
    try expectRunIn(tmp.dir, &environ, &.{ "status", "--url", "mysql://localhost/app" }, 1, "", mysql);

    // Taken as given: no `${VAR}` expansion.
    try environ.put("FFMIG_DATABASE_URL", "${DATABASE_URL}");
    try expectRunIn(tmp.dir, &environ, &.{"drop"}, 1, "", "ffmig: the database url must start with a scheme such as postgres://\n");

    // Empty counts as unset, so the config's url applies.
    try environ.put("FFMIG_DATABASE_URL", "");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ffmig.toml", .data = "[database]\nurl = \"mysql://localhost/app\"\n" });
    try expectRunIn(tmp.dir, &environ, &.{"status"}, 1, "", mysql);
}

test "--url stands in for a config without one" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ffmig.toml", .data = "[migration]\npath = \"migrations\"\n" });
    try tmp.dir.createDirPath(testing.io, "migrations");

    try expectRunIn(tmp.dir, null, &.{"status"}, 1, "", "ffmig: no database url; set [database] url in ffmig.toml or FFMIG_DATABASE_URL, or pass --url\n");
    try expectRunIn(tmp.dir, null, &.{ "protect", "--url", "postgres://localhost" }, 1, "", "ffmig: the database url from --url must name a database in its path, e.g. postgres://localhost/app_dev\n");
}

test "--config reads another config, its path relative to it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "config/db");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "config/app.toml",
        .data = "[migration]\npath = \"db\"\n",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "config/bad.toml",
        .data = "[migration]\npath = \"db\"\nlock_timeout = \"5\"\n",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "config/db/20260101000000_create_users.mig",
        .data = "migration CreateUsers {\n  change {\n    create_table :users {\n    }\n  }\n}\n",
    });

    try expectRunIn(tmp.dir, null, &.{ "check", "--config", "config/app.toml" }, 0, "ok config/db/20260101000000_create_users.mig\n", "");
    try expectRunIn(tmp.dir, null, &.{ "status", "--config=config/bad.toml" }, 1, "", "ffmig: config/bad.toml:3: lock_timeout must be a duration such as \"5s\" or \"500ms\", or \"0\" for no limit\n");
    try expectRunIn(tmp.dir, null, &.{ "new", "x", "--config", "nope.toml" }, 1, "", "ffmig: nope.toml not found; run 'ffmig init' first\n");
}
