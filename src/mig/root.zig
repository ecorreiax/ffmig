//! The `.mig` language front end. See `docs/mig.md` for the specification.

const std = @import("std");

pub const token = @import("token.zig");
pub const Lexer = @import("lexer.zig").Lexer;
pub const syntax = @import("syntax.zig");
pub const parser = @import("parser.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("lexer.zig");
    _ = @import("parser.zig");
}
