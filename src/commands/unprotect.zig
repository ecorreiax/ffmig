//! `ffmig unprotect`
//!
//! Removes the mark that `ffmig protect` sets, so `drop` works again.

const Writer = @import("std").Io.Writer;
const Env = @import("root.zig").Env;
const protect = @import("protect.zig");
const flags = @import("flags.zig");

pub const usage =
    \\Usage:
    \\
    \\      ffmig unprotect [flags]
    \\
    \\Remove the mark that 'ffmig protect' sets, so drop works again.
    \\
    \\Flags:
    \\
++ flags.config_option ++ flags.url_option ++ flags.help_option;

pub fn run(env: Env, args: []const []const u8, out: *Writer, err: *Writer) Writer.Error!u8 {
    return protect.runWith(env, args, false, out, err);
}
