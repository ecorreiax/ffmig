//! `ffmig status`
//!
//! Lists every migration as `up` (recorded in `schema_migrations`) or
//! `down`, in version order. An `up` migration shows when it was applied,
//! in UTC, and `(changed)` if its file has changed since. A recorded
//! version without a file is listed as `up` with `(no file)`. Rows
//! recorded before ffmig kept the time and checksum show neither.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
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
    return status(env.io, arena, project, conn, out, err);
}

/// `run` after connecting, split out so tests can pass a fake database.
pub fn status(
    io: Io,
    arena: Allocator,
    project: migrations.Project,
    conn: migrations.Connection,
    out: *Writer,
    err: *Writer,
) Writer.Error!u8 {
    const applied = try migrations.readApplied(arena, conn, err) orelse return 1;

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
            std.mem.order(u8, files[f].version, applied[a].version);
        switch (order) {
            .lt => {
                try out.print("down  {s}{s}/{s}\n", .{ no_time, project.path, files[f].name });
                f += 1;
            },
            .eq => {
                const changed = try project.changed(io, arena, files[f], applied[a], err) orelse return 1;
                try out.writeAll("up    ");
                try appliedAt(out, applied[a].applied_at);
                try out.print("{s}/{s}{s}\n", .{ project.path, files[f].name, if (changed) " (changed)" else "" });
                f += 1;
                a += 1;
            },
            .gt => {
                try out.writeAll("up    ");
                try appliedAt(out, applied[a].applied_at);
                try out.print("{s} (no file)\n", .{applied[a].version});
                a += 1;
            },
        }
    }
    return 0;
}

/// Blank space as wide as what `appliedAt` writes.
const no_time = " " ** "YYYY-MM-DD HH:MM:SS UTC  ".len;

/// `seconds` since 1970 as `YYYY-MM-DD HH:MM:SS UTC` and two spaces, or
/// as blank space when it is unknown.
fn appliedAt(out: *Writer, seconds: ?i64) Writer.Error!void {
    const s = seconds orelse return out.writeAll(no_time);
    if (s < 0) return out.writeAll(no_time);
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(s) };
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day = es.getDaySeconds();
    try out.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC  ", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
    });
}
