const std = @import("std");
const manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    // The PostgreSQL driver (`src/db/postgres.zig`). Found through
    // pkg-config, which the nix dev shell sets up, unless `-Dlibpq` names
    // the library file, as release builds do: a nix path would not exist
    // on the machines that run the binary.
    if (b.option([]const u8, "libpq", "Link this libpq file (libpq.so.5, libpq.5.dylib, libpq.dll.a) instead of the one pkg-config finds")) |path| {
        if (target.result.os.tag == .windows) {
            // The driver's `extern "pq"` functions need `-lpq` to find
            // the import library, which Zig looks for as `pq.lib`.
            const lib = b.addWriteFiles();
            _ = lib.addCopyFile(.{ .cwd_relative = path }, "pq.lib");
            mod.addLibraryPath(lib.getDirectory());
            mod.linkSystemLibrary("pq", .{ .use_pkg_config = .no, .preferred_link_mode = .dynamic });
        } else {
            mod.addObjectFile(.{ .cwd_relative = path });
        }
    } else {
        mod.linkSystemLibrary("pq", .{});
    }
    // libpq calls into libc, which must then start up with the program.
    // Without this, a Linux binary crashes in its first libpq call.
    mod.link_libc = true;
    // `ffmig --version` prints the version from `build.zig.zon`.
    const options = b.addOptions();
    options.addOption([]const u8, "version", manifest.version);
    mod.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "ffmig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ffmig", .module = mod }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run ffmig");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ffmig", .module = mod }},
        }),
    });
    const test_step = b.step("test", "Run tests");
    const run_tests = b.addRunArtifact(tests);
    // Golden tests read `tests/mig` relative to the project root.
    run_tests.setCwd(b.path("."));
    test_step.dependOn(&run_tests.step);

    // Needs a PostgreSQL server; `make integration` starts one.
    const integration = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ffmig", .module = mod }},
        }),
    });
    const integration_step = b.step("integration", "Run integration tests against PostgreSQL");
    const run_integration = b.addRunArtifact(integration);
    // The database is outside the build graph, so never reuse a result.
    run_integration.has_side_effects = true;
    integration_step.dependOn(&run_integration.step);
}
