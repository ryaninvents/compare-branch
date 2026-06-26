const std = @import("std");

// The release pipeline cross-compiles these four targets from a single
// pinned-Zig Docker image; keep this list in sync with scripts/release.sh.
const release_targets = [_]std.Target.Query{
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
};

// The shell wrapper files under shell/ live outside the src/ module root, so
// they are exposed to `@embedFile` by name rather than by relative path. Every
// compile of main.zig (default exe, release targets, unit tests) must register
// them or the build fails to resolve the embed.
fn embedShellAssets(b: *std.Build, module: *std.Build.Module) void {
    module.addAnonymousImport("cb_zsh", .{ .root_source_file = b.path("shell/cb.zsh") });
    module.addAnonymousImport("cb_bash", .{ .root_source_file = b.path("shell/cb.bash") });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "cb-bin",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    embedShellAssets(b, exe.root_module);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run cb-bin");
    run_step.dependOn(&run_cmd.step);

    // `zig build release` emits one binary per target under zig-out/release/<triple>/.
    const release_step = b.step("release", "Cross-compile all release targets");
    for (release_targets) |query| {
        const resolved = b.resolveTargetQuery(query);
        const rel_exe = b.addExecutable(.{
            .name = "cb-bin",
            .root_source_file = b.path("src/main.zig"),
            .target = resolved,
            .optimize = .ReleaseSafe,
        });
        embedShellAssets(b, rel_exe.root_module);
        const triple = query.zigTriple(b.allocator) catch @panic("OOM");
        const install = b.addInstallArtifact(rel_exe, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("release/{s}", .{triple}) } },
        });
        release_step.dependOn(&install.step);
    }

    // `zig build e2e` builds the binary then runs the hermetic review tests.
    const e2e = b.addSystemCommand(&.{ "bash", "e2e/review_e2e.sh" });
    e2e.step.dependOn(b.getInstallStep());
    const e2e_step = b.step("e2e", "Run end-to-end review tests");
    e2e_step.dependOn(&e2e.step);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    embedShellAssets(b, unit_tests.root_module);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
