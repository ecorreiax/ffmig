//! `ffmig init [--path <dir>] [--url <url>] [--config <path>]`
//!
//! Writes `ffmig.toml` (or the `--config` file) and creates the migrations
//! directory, which the config names relative to itself. Refuses to
//! overwrite an existing config. The config shows `lock_timeout`
//! commented out. `--url` and `--config` reach it through `Env`, read by
//! the CLI router as for the other commands.

const std = @import("std");
const Io = std.Io;
const Writer = Io.Writer;
const Env = @import("root.zig").Env;
const config = @import("../utils/config.zig");
const flags = @import("flags.zig");

pub const usage =
    \\Usage: ffmig init [flags]
    \\
    \\Create ffmig.toml and the migrations directory.
    \\
    \\Flags:
    \\  --path <dir>     Migrations directory, relative to the config
    \\                   (default: migrations)
    \\  --url <url>      Database URL to write (default: ${DATABASE_URL})
    \\  --config <path>  Config file to create (default: ffmig.toml)
    \\
++ flags.help_option;

const default_path = config.default_path;
pub const default_url = "${DATABASE_URL}";

/// Off by default so the server's settings apply, but shown so new
/// projects see the recommendation.
const lock_timeout_hint =
    \\# Fail a migration that waits longer than this for a lock, instead of
    \\# blocking every query queued behind it:
    \\# lock_timeout = "5s"
    \\
;

const Options = struct {
    path: []const u8 = default_path,
    url: []const u8 = default_url,
};

pub fn run(env: Env, args: []const []const u8, out: *Writer, err: *Writer) Writer.Error!u8 {
    var opts = parseArgs(args) orelse {
        try err.writeAll(usage);
        return 1;
    };
    if (env.url) |url| opts.url = url;
    const config_file = env.config;

    var buffer: [4096]u8 = undefined;
    var rendered: Writer = .fixed(&buffer);
    renderConfig(&rendered, opts) catch {
        try err.writeAll("ffmig: --path or --url is too long\n");
        return 1;
    };

    if (std.fs.path.dirname(config_file)) |dir| env.cwd.createDirPath(env.io, dir) catch |e| {
        try err.print("ffmig: cannot create directory {s}: {t}\n", .{ dir, e });
        return 1;
    };
    env.cwd.writeFile(env.io, .{
        .sub_path = config_file,
        .data = rendered.buffered(),
        .flags = .{ .exclusive = true },
    }) catch |e| switch (e) {
        error.PathAlreadyExists => {
            try err.print("ffmig: {s} already exists\n", .{config_file});
            return 1;
        },
        else => {
            try err.print("ffmig: cannot create {s}: {t}\n", .{ config_file, e });
            return 1;
        },
    };
    try out.print("Created {s}\n", .{config_file});

    const path = config.resolvePath(env.gpa, config_file, opts.path) catch {
        try err.writeAll("ffmig: out of memory\n");
        return 1;
    };
    defer env.gpa.free(path);
    const existed = if (env.cwd.access(env.io, path, .{})) true else |_| false;
    env.cwd.createDirPath(env.io, path) catch |e| {
        try err.print("ffmig: cannot create directory {s}: {t}\n", .{ path, e });
        return 1;
    };
    if (!existed) try out.print("Created {s}/\n", .{path});

    return 0;
}

/// The options, or null for invalid arguments.
fn parseArgs(args: []const []const u8) ?Options {
    var opts: Options = .{};
    var it: flags.Iterator = .{ .args = args };
    while (it.next()) |arg| switch (arg) {
        .flag => |f| if (f.is("--path")) {
            opts.path = it.value(f) orelse return null;
        } else return null,
        .positional => return null,
    };
    return opts;
}

fn renderConfig(w: *Writer, opts: Options) Writer.Error!void {
    try w.writeAll("[migration]\npath = ");
    try writeTomlString(w, opts.path);
    try w.writeAll("\n" ++ lock_timeout_hint ++ "\n[database]\nurl = ");
    try writeTomlString(w, opts.url);
    try w.writeAll("\n");
}

/// Writes `s` as a TOML basic string, escaping quotes and backslashes.
fn writeTomlString(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"', '\\' => {
            try w.writeByte('\\');
            try w.writeByte(c);
        },
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}
