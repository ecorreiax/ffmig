//! Keeps the spec in step with the code: every ` ```mig ` block in
//! `MIG.md` that holds a whole migration is valid.

const std = @import("std");
const ffmig = @import("ffmig");
const mig = ffmig.mig;
const token = mig.token;
const Diagnostic = mig.Diagnostic;

const testing = std.testing;

test "every whole migration in MIG.md is valid" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    // Read at test time; `build.zig` runs the tests from the project root.
    const migrations = try checkFile(arena_state.allocator(), "MIG.md");
    try testing.expect(migrations > 0);
}

/// Parses each ` ```mig ` block in `name` that starts with `migration`,
/// after any comments, and returns how many there were. Other blocks are
/// snippets of a migration and are left alone.
fn checkFile(arena: std.mem.Allocator, name: []const u8) !usize {
    const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, name, arena, .unlimited);

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
