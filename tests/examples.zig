//! Keeps `examples/` valid: every file parses, has a down plan, and writes
//! SQL for every dialect it runs on. The SQL itself is checked by the golden
//! cases in `tests/sql`.

const std = @import("std");
const ffmig = @import("ffmig");
const mig = ffmig.mig;
const sql = ffmig.sql;
const ast = mig.ast;
const token = mig.token;
const Diagnostic = mig.Diagnostic;

const testing = std.testing;

/// Read at test time; `build.zig` runs the tests from the project root.
const examples_dir = "examples";

test "every file in examples is a valid migration" {
    const io = testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, examples_dir, .{ .iterate = true });
    defer dir.close(io);

    var examples: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".mig")) continue;
        errdefer std.debug.print("example: {s}/{s}\n", .{ examples_dir, entry.name });
        try expectValid(dir, entry.name);
        examples += 1;
    }
    try testing.expect(examples > 0);
}

fn expectValid(dir: std.Io.Dir, name: []const u8) !void {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source = try dir.readFileAlloc(io, name, arena, .unlimited);
    var diag: Diagnostic = .{};
    const migration = mig.parseMigration(arena, source, &diag) catch |err| {
        const pos = token.lineCol(source, diag.span.start);
        std.debug.print("{d}:{d}: {s}\n", .{ pos.line, pos.col, diag.message });
        return err;
    };
    // Examples show the reversible form of each operation, so `rollback`
    // works on every one of them.
    const plan = mig.reverse.plan(arena, migration, &diag) catch |err| {
        const pos = token.lineCol(source, diag.span.start);
        std.debug.print("{d}:{d}: {s}\n", .{ pos.line, pos.col, diag.message });
        return err;
    };

    inline for (comptime std.enums.values(sql.Dialect)) |dialect| {
        // An `execute` with `dialect:` naming another database skips this one.
        if (runsOn(dialect, plan)) {
            var out: std.Io.Writer.Allocating = .init(arena);
            try sql.write(dialect, plan.up, &out.writer);
            try sql.write(dialect, plan.down, &out.writer);
            try testing.expect(out.written().len > 0);
        }
    }
}

fn runsOn(dialect: sql.Dialect, plan: mig.reverse.Plan) bool {
    for ([_][]const ast.Operation{ plan.up, plan.down }) |ops| {
        for (ops) |op| if (sql.unsupported(dialect, op) != null) return false;
    }
    return true;
}
