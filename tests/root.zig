//! Test root. Each file tests the matching module in `src/` through the
//! `ffmig` module.

const std = @import("std");
const ffmig = @import("ffmig");

test {
    // Analyze every public declaration so unused code still has to compile.
    inline for (.{ ffmig, ffmig.cli, ffmig.commands, ffmig.config, ffmig.fs, ffmig.mig }) |module| {
        std.testing.refAllDecls(module);
    }
    _ = @import("cli.zig");
    _ = @import("check.zig");
    _ = @import("init.zig");
    _ = @import("new.zig");
    _ = @import("config.zig");
    _ = @import("fs.zig");
    _ = @import("token.zig");
    _ = @import("lexer.zig");
    _ = @import("parser.zig");
    _ = @import("lower.zig");
    _ = @import("reverse.zig");
    _ = @import("mig.zig");
}
