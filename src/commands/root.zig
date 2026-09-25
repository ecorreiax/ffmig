//! Command registry. Each command lives in its own file and exposes
//! `run(env, args, out, err)` and a `usage` text listing its flags; add
//! new ones to `Command`, `run`, `usage` and `Globals.of` below.

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
pub const redo = @import("redo.zig");
pub const status = @import("status.zig");
pub const dump = @import("dump.zig");
pub const load = @import("load.zig");
pub const create = @import("create.zig");
pub const drop = @import("drop.zig");
pub const protect = @import("protect.zig");
pub const unprotect = @import("unprotect.zig");
pub const database = @import("database.zig");
pub const migrations = @import("migrations.zig");
pub const flags = @import("flags.zig");
const config = @import("../utils/config.zig");

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
    /// `--config`: the config file, relative to `cwd`.
    config: []const u8 = config.file_name,
    /// `--url`: the database URL, which beats `FFMIG_DATABASE_URL` and
    /// the config's. `init` writes it to the config instead.
    url: ?[]const u8 = null,
    /// Runs another program, for `dump`, which runs `pg_dump`. Tests
    /// replace it.
    run_program: *const RunProgram = runProgram,
};

/// Runs `argv` to completion with `environ` as its whole environment,
/// and returns its output, allocated in `arena`.
pub const RunProgram = fn (io: Io, arena: Allocator, argv: []const []const u8, environ: *const std.process.Environ.Map) ProgramError!ProgramResult;

pub const ProgramError = error{ ProgramNotFound, CannotRunProgram, OutOfMemory };

pub const ProgramResult = struct {
    /// Null when the program did not exit on its own, e.g. on a signal.
    exit_code: ?u8,
    stdout: []const u8,
    stderr: []const u8,
};

/// `RunProgram` on the real process: looks `argv[0]` up in `PATH`
/// unless it holds a `/`.
pub fn runProgram(io: Io, arena: Allocator, argv: []const []const u8, environ: *const std.process.Environ.Map) ProgramError!ProgramResult {
    const result = std.process.run(arena, io, .{ .argv = argv, .environ_map = environ }) catch |e| return switch (e) {
        error.FileNotFound => error.ProgramNotFound,
        error.OutOfMemory => error.OutOfMemory,
        else => error.CannotRunProgram,
    };
    return .{
        .exit_code = switch (result.term) {
            .exited => |code| code,
            else => null,
        },
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

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
    redo,
    status,
    dump,
    load,
    help,
    version,
};

/// Which of the flags `--config` and `--url` the CLI router reads into
/// `Env` for a command, before the command sees its arguments. A command
/// that takes neither rejects them like any unknown flag.
pub const Globals = struct {
    config: bool = false,
    url: bool = false,

    pub fn of(command: Command) Globals {
        return switch (command) {
            .init, .create, .drop, .protect, .unprotect, .migrate, .rollback, .redo, .status, .dump, .load => .{ .config = true, .url = true },
            .new, .check => .{ .config = true },
            .sql, .help, .version => .{},
        };
    }
};

pub const help_usage =
    \\Usage:
    \\
    \\      ffmig help [command]
    \\
    \\Show the commands, or one command's usage and flags. So does
    \\'ffmig <command> --help'.
    \\
;

pub const version_usage =
    \\Usage:
    \\
    \\      ffmig version
    \\
    \\Print the version of ffmig. So does 'ffmig --version'.
    \\
;

/// The usage text of `command`, listing its flags.
pub fn usage(command: Command) []const u8 {
    return switch (command) {
        .init => init.usage,
        .create => create.usage,
        .drop => drop.usage,
        .protect => protect.usage,
        .unprotect => unprotect.usage,
        .new => new.usage,
        .check => check.usage,
        .sql => sql.usage,
        .migrate => migrate.usage,
        .rollback => rollback.usage,
        .redo => redo.usage,
        .status => status.usage,
        .dump => dump.usage,
        .load => load.usage,
        .help => help_usage,
        .version => version_usage,
    };
}

/// Runs `command` with the arguments that follow it. `help` and
/// `version` are handled by the CLI router, which holds the top-level
/// usage text and the version.
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
        .redo => redo.run(env, args, out, err),
        .status => status.run(env, args, out, err),
        .dump => dump.run(env, args, out, err),
        .load => load.run(env, args, out, err),
        .help, .version => unreachable,
    };
}
