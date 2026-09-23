//! `ffmig init [--path <dir>] [--url <url>]`
//!
//! Writes `ffmig.toml` to the working directory and creates the migrations
//! directory. Refuses to overwrite an existing config.

const std = @import("std");
const Io = std.Io;
const Writer = Io.Writer;
const Env = @import("root.zig").Env;
const config = @import("../utils/config.zig");

pub const usage = "Usage: ffmig init [--path <dir>] [--url <url>]\n";

const config_file = config.file_name;
const default_path = config.default_path;
pub const default_url = "${DATABASE_URL}";

const Options = struct {
    path: []const u8 = default_path,
    url: []const u8 = default_url,
};

pub fn run(env: Env, args: []const []const u8, out: *Writer, err: *Writer) Writer.Error!u8 {
    const opts = parseArgs(args) orelse {
        try err.writeAll(usage);
        return 1;
    };

    var buffer: [4096]u8 = undefined;
    var rendered: Writer = .fixed(&buffer);
    renderConfig(&rendered, opts) catch {
        try err.writeAll("ffmig: --path or --url is too long\n");
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

    const existed = if (env.cwd.access(env.io, opts.path, .{})) true else |_| false;
    env.cwd.createDirPath(env.io, opts.path) catch |e| {
        try err.print("ffmig: cannot create directory {s}: {t}\n", .{ opts.path, e });
        return 1;
    };
    if (!existed) try out.print("Created {s}/\n", .{opts.path});

    return 0;
}

/// Accepts `--flag value` and `--flag=value`. Returns null on bad input.
fn parseArgs(args: []const []const u8) ?Options {
    var opts: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const name, const inline_value = if (std.mem.indexOfScalar(u8, arg, '=')) |eq|
            .{ arg[0..eq], @as(?[]const u8, arg[eq + 1 ..]) }
        else
            .{ arg, @as(?[]const u8, null) };

        const slot = if (std.mem.eql(u8, name, "--path"))
            &opts.path
        else if (std.mem.eql(u8, name, "--url"))
            &opts.url
        else
            return null;

        const value = inline_value orelse blk: {
            i += 1;
            if (i == args.len) return null;
            break :blk args[i];
        };
        if (value.len == 0) return null;
        slot.* = value;
    }
    return opts;
}

fn renderConfig(w: *Writer, opts: Options) Writer.Error!void {
    try w.writeAll("[migration]\npath = ");
    try writeTomlString(w, opts.path);
    try w.writeAll("\n\n[database]\nurl = ");
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
