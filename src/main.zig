const std = @import("std");
const Io = std.Io;
const cli = @import("ffmig").cli;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .initStreaming(.stdout(), init.io, &stdout_buffer);
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer: Io.File.Writer = .initStreaming(.stderr(), init.io, &stderr_buffer);

    var stdin_buffer: [1024]u8 = undefined;
    var stdin_reader: Io.File.Reader = .initStreaming(.stdin(), init.io, &stdin_buffer);
    const stdin: ?*Io.Reader = if (try Io.File.stdin().isTty(init.io)) &stdin_reader.interface else null;

    const status = try cli.run(
        .{ .io = init.io, .cwd = .cwd(), .gpa = init.gpa, .environ = init.environ_map, .stdin = stdin },
        args[1..],
        &stdout_writer.interface,
        &stderr_writer.interface,
    );

    try stdout_writer.interface.flush();
    try stderr_writer.interface.flush();
    return status;
}
