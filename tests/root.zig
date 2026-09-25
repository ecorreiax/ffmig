//! Test root. Each file tests the matching module in `src/` through the
//! `ffmig` module.

const std = @import("std");
const ffmig = @import("ffmig");

test {
    // Analyze every public declaration so unused code still has to compile.
    inline for (.{ ffmig, ffmig.cli, ffmig.commands, ffmig.config, ffmig.fs, ffmig.mig, ffmig.sql, ffmig.db }) |module| {
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
    _ = @import("sql.zig");
    _ = @import("sql_command.zig");
    _ = @import("examples.zig");
    _ = @import("migrate.zig");
    _ = @import("database.zig");
}
