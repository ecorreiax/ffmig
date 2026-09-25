//! Command-line arguments, read the same way by every command. A flag is
//! `--name` or `-n`; one that takes a value is followed by it, as
//! `--name value` or `--name=value`. Anything else, `-` included, is a
//! positional argument.

const std = @import("std");

pub const Arg = union(enum) {
    flag: Flag,
    positional: []const u8,
};

pub const Flag = struct {
    /// With its dashes, e.g. `--lock-wait`.
    name: []const u8,
    /// What follows `=`, when given as `--name=value`.
    inline_value: ?[]const u8,

    /// Whether this is the flag `name`, whatever its value.
    pub fn is(f: Flag, name: []const u8) bool {
        return std.mem.eql(u8, f.name, name);
    }

    /// Whether this is the switch `name`: `--name=value` is not.
    pub fn isSwitch(f: Flag, name: []const u8) bool {
        return f.is(name) and f.inline_value == null;
    }
};

pub const Iterator = struct {
    args: []const []const u8,
    index: usize = 0,

    pub fn next(it: *Iterator) ?Arg {
        if (it.index == it.args.len) return null;
        const arg = it.args[it.index];
        it.index += 1;
        if (arg.len < 2 or arg[0] != '-') return .{ .positional = arg };
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
            return .{ .flag = .{ .name = arg[0..eq], .inline_value = arg[eq + 1 ..] } };
        }
        return .{ .flag = .{ .name = arg, .inline_value = null } };
    }

    /// The argument `next` returned last, as written. Call it before
    /// `value`, which may move past the flag's value.
    pub fn raw(it: Iterator) []const u8 {
        return it.args[it.index - 1];
    }

    /// The value of `flag`: what follows `=`, or else the next argument.
    /// Null when it is missing or empty.
    pub fn value(it: *Iterator, flag: Flag) ?[]const u8 {
        const v = flag.inline_value orelse v: {
            if (it.index == it.args.len) return null;
            it.index += 1;
            break :v it.args[it.index - 1];
        };
        return if (v.len == 0) null else v;
    }
};

/// Whether `arg` is `-h` or `--help`.
pub fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

/// Whether `args` asks for a command's usage with `-h` or `--help`.
pub fn wantsHelp(args: []const []const u8) bool {
    for (args) |arg| if (isHelp(arg)) return true;
    return false;
}

/// Usage lines for the options that `cli.run` reads on the commands'
/// behalf, aligned like each command's own.
pub const config_option =
    \\      --config <path>       Config file (default: ffmig.toml)
    \\
;
pub const url_option =
    \\      --url <url>           Database connection string
    \\
;
pub const help_option =
    \\      -h, --help            Show this message
    \\
;
