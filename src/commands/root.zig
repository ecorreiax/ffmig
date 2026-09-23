//! Command registry. Each command lives in its own file and exposes
//! `run(env, args, out, err)`; add new ones to `Command` and `run` below.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;

pub const init = @import("init.zig");
pub const new = @import("new.zig");
pub const check = @import("check.zig");
pub const sql = @import("sql.zig");
pub const migrate = @import("migrate.zig");
pub const rollback = @import("rollback.zig");
pub const status = @import("status.zig");
pub const create = @import("create.zig");
pub const drop = @import("drop.zig");
pub const protect = @import("protect.zig");
pub const unprotect = @import("unprotect.zig");
pub const database = @import("database.zig");
pub const migrations = @import("migrations.zig");

/// Process resources a command may need, injected so tests can point
/// commands at a temporary directory.
pub const Env = struct {
    io: Io,
    cwd: Io.Dir,
    gpa: Allocator,
    /// Environment variables, for `${VAR}` in the database URL. Null
    /// behaves like an empty environment.
    environ: ?*const std.process.Environ.Map = null,
    /// Standard input when it is a terminal, for confirmation prompts.
    /// Null means nobody can answer, so commands that need confirmation
    /// refuse unless forced.
    stdin: ?*Io.Reader = null,
};

pub const Command = enum {
    init,
    create,
    drop,
    protect,
    unprotect,
    new,
    check,
    sql,
    migrate,
    rollback,
    status,
    help,
};

/// Runs `command` with the arguments that follow it. `help` is handled by
/// the CLI router since it needs the top-level usage text.
pub fn run(env: Env, command: Command, args: []const []const u8, out: *Writer, err: *Writer) Writer.Error!u8 {
    return switch (command) {
        .init => init.run(env, args, out, err),
        .create => create.run(env, args, out, err),
        .drop => drop.run(env, args, out, err),
        .protect => protect.run(env, args, out, err),
        .unprotect => unprotect.run(env, args, out, err),
        .new => new.run(env, args, out, err),
        .check => check.run(env, args, out, err),
        .sql => sql.run(env, args, out, err),
        .migrate => migrate.run(env, args, out, err),
        .rollback => rollback.run(env, args, out, err),
        .status => status.run(env, args, out, err),
        .help => unreachable,
    };
}
