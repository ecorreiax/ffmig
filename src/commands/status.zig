//! `ffmig status`
//!
//! Lists every migration as `up` (recorded in `schema_migrations`) or
//! `down`, in version order. A recorded version without a file is listed
//! as `up` with `(no file)`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Env = @import("root.zig").Env;
const migrations = @import("migrations.zig");

pub const usage = "Usage: ffmig status\n";

pub fn run(env: Env, args: []const []const u8, out: *Writer, err: *Writer) Writer.Error!u8 {
    if (args.len != 0) {
        try err.writeAll(usage);
        return 1;
    }

    var arena_state: std.heap.ArenaAllocator = .init(env.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var project = try migrations.Project.load(env, arena, err) orelse return 1;
    defer project.close(env.io);
    const conn = try migrations.connect(env, arena, project.url, err) orelse return 1;
    defer conn.db.close();
    return status(arena, project, conn, out, err);
}

/// `run` after connecting, split out so tests can pass a fake database.
pub fn status(
    arena: Allocator,
    project: migrations.Project,
    conn: migrations.Connection,
    out: *Writer,
    err: *Writer,
) Writer.Error!u8 {
    const applied = try migrations.appliedVersions(arena, conn, err) orelse return 1;

    // Merge the two sorted lists.
    const files = project.files;
    var f: usize = 0;
    var a: usize = 0;
    while (f < files.len or a < applied.len) {
        const order: std.math.Order = if (f == files.len)
            .gt
        else if (a == applied.len)
            .lt
        else
            std.mem.order(u8, files[f].version, applied[a]);
        switch (order) {
            .lt => {
                try out.print("down  {s}/{s}\n", .{ project.path, files[f].name });
                f += 1;
            },
            .eq => {
                try out.print("up    {s}/{s}\n", .{ project.path, files[f].name });
                f += 1;
                a += 1;
            },
            .gt => {
                try out.print("up    {s} (no file)\n", .{applied[a]});
                a += 1;
            },
        }
    }
    return 0;
}
