//! Command-line router. Takes already-split arguments and writers so it
//! stays independent of the process and is easy to test.

const std = @import("std");
const Writer = std.Io.Writer;
const commands = @import("commands/root.zig");

pub const usage =
    \\Usage: ffmig <command> [args]
    \\
    \\Commands:
    \\  init           Create ffmig.toml and the migrations directory
    \\                   --path <dir>  Migrations directory (default: migrations)
    \\                   --url <url>   Database URL (default: ${DATABASE_URL})
    \\  new <name>     Create a timestamped migration file, e.g. new create_users
    \\  check [files]  Check .mig files (default: all in the migrations directory)
    \\                   --ast         Print the parsed migration
    \\                   --down        Print it as up / down, deriving down for change
    \\  help           Show this message
    \\
;

pub fn run(env: commands.Env, args: []const []const u8, out: *Writer, err: *Writer) Writer.Error!u8 {
    if (args.len == 0) {
        try err.writeAll(usage);
        return 1;
    }

    const command = std.meta.stringToEnum(commands.Command, args[0]) orelse {
        try err.print("ffmig: unknown command '{s}'\n\n", .{args[0]});
        try err.writeAll(usage);
        return 1;
    };

    return switch (command) {
        .help => {
            try out.writeAll(usage);
            return 0;
        },
        else => commands.run(env, command, args[1..], out, err),
    };
}
