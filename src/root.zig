//! ffmig core library.

pub const cli = @import("cli.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
