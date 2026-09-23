//! Command registry. Each command lives in its own file and exposes
//! `run(args, out, err)`; add new ones to `Command` and `run` below.

const std = @import("std");
const Writer = std.Io.Writer;

pub const greet = @import("greet.zig");

pub const Command = enum {
    greet,
    help,
};

/// Runs `command` with the arguments that follow it. `help` is handled by
/// the CLI router since it needs the top-level usage text.
pub fn run(command: Command, args: []const []const u8, out: *Writer, err: *Writer) Writer.Error!u8 {
    return switch (command) {
        .greet => greet.run(args, out, err),
        .help => unreachable,
    };
}

test {
    std.testing.refAllDecls(@This());
}
