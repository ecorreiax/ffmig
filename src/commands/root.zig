//! Command registry. Each command lives in its own file and exposes
//! `run(env, args, out, err)`; add new ones to `Command` and `run` below.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;

pub const init = @import("init.zig");
pub const new = @import("new.zig");
pub const check = @import("check.zig");

/// Process resources a command may need, injected so tests can point
/// commands at a temporary directory.
pub const Env = struct {
    io: Io,
    cwd: Io.Dir,
    gpa: Allocator,
};

pub const Command = enum {
    init,
    new,
    check,
    help,
};

/// Runs `command` with the arguments that follow it. `help` is handled by
/// the CLI router since it needs the top-level usage text.
pub fn run(env: Env, command: Command, args: []const []const u8, out: *Writer, err: *Writer) Writer.Error!u8 {
    return switch (command) {
        .init => init.run(env, args, out, err),
        .new => new.run(env, args, out, err),
        .check => check.run(env, args, out, err),
        .help => unreachable,
    };
}

test {
    std.testing.refAllDecls(@This());
}
