//! `ffmig unprotect`
//!
//! Removes the mark that `ffmig protect` sets, so `drop` works again.

const Writer = @import("std").Io.Writer;
const Env = @import("root.zig").Env;
const protect = @import("protect.zig");

pub const usage = "Usage: ffmig unprotect\n";

pub fn run(env: Env, args: []const []const u8, out: *Writer, err: *Writer) Writer.Error!u8 {
    return protect.runWith(env, args, false, out, err);
}
