//! `ffmig new <name>`
//!
//! Creates `<timestamp>_<snake_name>.mig` in the configured migrations
//! directory. The timestamp is the current UTC time as YYYYMMDDHHMMSS.

const std = @import("std");
const Io = std.Io;
const Writer = Io.Writer;
const Env = @import("root.zig").Env;
const flags = @import("flags.zig");
const migrations = @import("migrations.zig");
const fs = @import("../utils/fs.zig");

pub const usage =
    \\Usage:
    \\
    \\      ffmig new [flags] <name>
    \\
    \\Create <timestamp>_<name>.mig in the migrations directory, e.g.
    \\'ffmig new create_users'.
    \\
    \\Flags:
    \\
++ flags.config_option ++ flags.help_option;

pub fn run(env: Env, args: []const []const u8, out: *Writer, err: *Writer) Writer.Error!u8 {
    return generate(env, args, fs.now(env.io), out, err);
}

/// `run` with the clock injected so tests get stable file names.
pub fn generate(env: Env, args: []const []const u8, now: u64, out: *Writer, err: *Writer) Writer.Error!u8 {
    var positional: ?[]const u8 = null;
    var it: flags.Iterator = .{ .args = args };
    while (it.next()) |arg| {
        if (arg == .flag or positional != null) {
            try err.writeAll(usage);
            return 1;
        }
        positional = arg.positional;
    }
    const name = positional orelse {
        try err.writeAll(usage);
        return 1;
    };
    if (!fs.isValidName(name)) {
        try err.print(
            "ffmig: invalid migration name '{s}'; use letters, digits and underscores, not starting with a digit\n",
            .{name},
        );
        return 1;
    }

    var arena_state: std.heap.ArenaAllocator = .init(env.gpa);
    defer arena_state.deinit();
    const cfg = try migrations.loadConfig(env, arena_state.allocator(), err) orelse return 1;

    const file_name = fs.migrationFileName(env.gpa, now, name) catch {
        try err.writeAll("ffmig: out of memory\n");
        return 1;
    };
    defer env.gpa.free(file_name);

    var content_buf: [512]u8 = undefined;
    const content = writeTemplate(&content_buf, fs.migrationName(file_name)) catch {
        try err.print("ffmig: migration name '{s}' is too long\n", .{name});
        return 1;
    };

    env.cwd.createDirPath(env.io, cfg.path) catch |e| {
        try err.print("ffmig: cannot create directory {s}: {t}\n", .{ cfg.path, e });
        return 1;
    };
    var dir = env.cwd.openDir(env.io, cfg.path, .{}) catch |e| {
        try err.print("ffmig: cannot open directory {s}: {t}\n", .{ cfg.path, e });
        return 1;
    };
    defer dir.close(env.io);

    dir.writeFile(env.io, .{
        .sub_path = file_name,
        .data = content,
        .flags = .{ .exclusive = true },
    }) catch |e| {
        try err.print("ffmig: cannot create {s}/{s}: {t}\n", .{ cfg.path, file_name, e });
        return 1;
    };

    try out.print("Created {s}/{s}\n", .{ cfg.path, file_name });
    return 0;
}

/// The body of a new migration, named after its snake_case file name.
fn writeTemplate(buf: []u8, snake: []const u8) Writer.Error![]const u8 {
    var w: Writer = .fixed(buf);
    try w.writeAll("migration ");
    try fs.writePascalCase(&w, snake);
    try w.writeAll(" {\n  change {\n  }\n}\n");
    return w.buffered();
}
