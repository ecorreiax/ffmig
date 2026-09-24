//! Library root. `main.zig` and the tests in `tests/` import this as the
//! `ffmig` module.

pub const cli = @import("cli.zig");
pub const commands = @import("commands/root.zig");
pub const db = @import("db/root.zig");
pub const config = @import("utils/config.zig");
pub const fs = @import("utils/fs.zig");
pub const mig = @import("mig/root.zig");
pub const sql = @import("sql/root.zig");

/// From `build.zig.zon`.
pub const version = @import("build_options").version;
