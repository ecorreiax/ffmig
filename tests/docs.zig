//! Keeps the docs in step with the code: every ` ```mig ` block in
//! `docs/` and `MIG.md` that holds a whole migration is valid, and
//! `docs/commands.md` has a section for every command.

const std = @import("std");
const ffmig = @import("ffmig");
const mig = ffmig.mig;
const token = mig.token;
const Diagnostic = mig.Diagnostic;

const testing = std.testing;

/// Read at test time; `build.zig` runs the tests from the project root.
const docs_dir = "docs";

test "every whole migration in the docs is valid" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var migrations: usize = 0;
    migrations += try checkFile(arena, std.Io.Dir.cwd(), "MIG.md");

    var dir = try std.Io.Dir.cwd().openDir(io, docs_dir, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".md")) continue;
        migrations += try checkFile(arena, dir, entry.name);
    }
    try testing.expect(migrations > 0);
}

test "docs/commands.md has a section for every command" {
    const io = testing.io;
    const source = try std.Io.Dir.cwd().readFileAlloc(io, docs_dir ++ "/commands.md", testing.allocator, .unlimited);
    defer testing.allocator.free(source);

    inline for (comptime std.enums.values(ffmig.commands.Command)) |command| {
        const heading = "\n### " ++ @tagName(command) ++ "\n";
        if (std.mem.indexOf(u8, source, heading) == null) {
            std.debug.print("docs/commands.md has no '### {s}' section\n", .{@tagName(command)});
            return error.TestExpectedEqual;
        }
    }
}

/// Parses each ` ```mig ` block in `name` that starts with `migration`,
/// after any comments, and returns how many there were. Other blocks are
/// snippets of a migration and are left alone.
fn checkFile(arena: std.mem.Allocator, dir: std.Io.Dir, name: []const u8) !usize {
    const source = try dir.readFileAlloc(testing.io, name, arena, .unlimited);

    var migrations: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_no: usize = 0;
    while (lines.next()) |line| {
        line_no += 1;
        if (!std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), "```mig")) continue;
        const start = line_no;

        var block: std.ArrayList(u8) = .empty;
        while (lines.next()) |body| {
            line_no += 1;
            if (std.mem.eql(u8, std.mem.trim(u8, body, " \t\r"), "```")) break;
            try block.appendSlice(arena, body);
            try block.append(arena, '\n');
        } else return error.UnterminatedCodeBlock;

        if (!isWholeMigration(block.items)) continue;
        errdefer std.debug.print("in the block at {s}:{d}\n", .{ name, start });
        var diag: Diagnostic = .{};
        _ = mig.parseMigration(arena, block.items, &diag) catch |err| {
            const pos = token.lineCol(block.items, diag.span.start);
            std.debug.print("{d}:{d}: {s}\n", .{ pos.line, pos.col, diag.message });
            return err;
        };
        migrations += 1;
    }
    return migrations;
}

fn isWholeMigration(block: []const u8) bool {
    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " \t\r");
        if (text.len == 0 or text[0] == '#') continue;
        return std.mem.startsWith(u8, text, "migration ");
    }
    return false;
}
