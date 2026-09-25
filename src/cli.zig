//! Command-line router. Takes already-split arguments and writers so it
//! stays independent of the process and is easy to test.
//!
//! It answers `help`, `version` and every `--help` itself, and reads the
//! flags that several commands share (`commands.Globals`) into
//! `commands.Env`, so each command parses only its own.

const std = @import("std");
const Writer = std.Io.Writer;
const commands = @import("commands/root.zig");
const flags = commands.flags;
const version = @import("build_options").version;

pub const usage =
    \\FFMig is a tool for managing Database migrations.
    \\
    \\Usage:
    \\
    \\      ffmig <command> [flags]
    \\
    \\Commands:
    \\      init            Create ffmig.toml and the empty migrations directory
    \\      create          Create the database named by the database url
    \\      drop            Drop that database and schema_migrations
    \\      protect         Prevent the database from being dropped
    \\      unprotect       Remove the drop protection
    \\      new             Create a migration file
    \\      check           Check the migration files
    \\      sql             Print the SQL translation for a migration
    \\      migrate         Apply every pending migration
    \\      rollback        Undo the last applied migration
    \\      redo            Undo the last applied migration and apply it again
    \\      status          List migrations as up or down, with when each ran
    \\      dump            Write the database schema to schema.sql
    \\      load            Create the schema from schema.sql in an empty database
    \\      help            Show this message, or a command's flags
    \\      version         Print the version
    \\
    \\Use "ffmig help <command>" for more information about a command.
    \\
;

pub fn run(env: commands.Env, args: []const []const u8, out: *Writer, err: *Writer) Writer.Error!u8 {
    if (args.len == 0) {
        try err.writeAll(usage);
        return 1;
    }

    const command: commands.Command = if (flags.isHelp(args[0]))
        .help
    else if (std.mem.eql(u8, args[0], "--version"))
        .version
    else
        try parseCommand(args[0], err) orelse return 1;
    const rest = args[1..];

    if (flags.wantsHelp(rest)) {
        try out.writeAll(commands.usage(command));
        return 0;
    }
    switch (command) {
        .help => return help(rest, out, err),
        .version => {
            if (rest.len != 0) {
                try err.writeAll(commands.version_usage);
                return 1;
            }
            try out.print("ffmig {s}\n", .{version});
            return 0;
        },
        else => {},
    }

    const globals: commands.Globals = .of(command);
    if (!globals.config and !globals.url) return commands.run(env, command, rest, out, err);

    // The command's own arguments, in order, without the shared flags.
    var own: std.ArrayList([]const u8) = .empty;
    defer own.deinit(env.gpa);
    var command_env = env;
    var it: flags.Iterator = .{ .args = rest };
    while (it.next()) |arg| {
        if (arg == .flag) {
            const f = arg.flag;
            if (globals.config and f.is("--config")) {
                command_env.config = it.value(f) orelse return badArguments(command, err);
                continue;
            }
            if (globals.url and f.is("--url")) {
                command_env.url = it.value(f) orelse return badArguments(command, err);
                continue;
            }
        }
        own.append(env.gpa, it.raw()) catch {
            try err.writeAll("ffmig: out of memory\n");
            return 1;
        };
    }
    return commands.run(command_env, command, own.items, out, err);
}

/// `ffmig help [command]`, also reached as `ffmig -h [command]`.
fn help(args: []const []const u8, out: *Writer, err: *Writer) Writer.Error!u8 {
    switch (args.len) {
        0 => try out.writeAll(usage),
        1 => try out.writeAll(commands.usage(try parseCommand(args[0], err) orelse return 1)),
        else => {
            try err.writeAll(commands.help_usage);
            return 1;
        },
    }
    return 0;
}

/// The command called `name`, or null after reporting that there is none.
fn parseCommand(name: []const u8, err: *Writer) Writer.Error!?commands.Command {
    return std.meta.stringToEnum(commands.Command, name) orelse {
        try err.print("ffmig: unknown command '{s}'\n\n", .{name});
        try err.writeAll(usage);
        return null;
    };
}

fn badArguments(command: commands.Command, err: *Writer) Writer.Error!u8 {
    try err.writeAll(commands.usage(command));
    return 1;
}
