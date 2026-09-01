const std = @import("std");

// The single source of truth for the version `cb --version` reports. Typed so
// the ZON import satisfies Zig 0.14's "known result type" requirement; `paths`
// is a slice (not a fixed-length tuple) so this type doesn't need updating
// every time an entry is added to build.zig.zon's `.paths`.
const zon: struct {
    name: @Type(.enum_literal),
    version: []const u8,
    fingerprint: u64,
    minimum_zig_version: []const u8,
    dependencies: struct {},
    paths: []const []const u8,
} = @import("build.zig.zon");

// One row per man page under `man/`. `section` is the conventional man
// section directory name (`man1`, `man5`, `man7`) under `share/man/`; a new
// user-visible command, flag, environment variable, or file is not complete
// until `man/cb.1` (or `cb-config.5`/`cb-review.7`) documents it in the same
// commit — see CLAUDE.md.
const ManPage = struct { file: []const u8, section: []const u8 };
const man_pages = [_]ManPage{
    .{ .file = "cb.1", .section = "man1" },
    .{ .file = "cb-config.5", .section = "man5" },
    .{ .file = "cb-review.7", .section = "man7" },
};

// The release pipeline cross-compiles these four targets from a single
// pinned-Zig Docker image; keep this list in sync with scripts/release.sh.
const release_targets = [_]std.Target.Query{
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
};

// The shell wrapper files under shell/ live outside the src/ module root, so
// they are exposed to `@embedFile` by name rather than by relative path, and
// the version is exposed as a build option — every compile of main.zig
// (default exe, release targets, unit tests) must register both or the build
// fails to resolve the embed / the `build_options` import.
fn configureModule(b: *std.Build, module: *std.Build.Module, options: *std.Build.Step.Options) void {
    module.addAnonymousImport("cb_zsh", .{ .root_source_file = b.path("shell/cb.zsh") });
    module.addAnonymousImport("cb_bash", .{ .root_source_file = b.path("shell/cb.bash") });
    module.addOptions("build_options", options);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);

    const exe = b.addExecutable(.{
        .name = "cb-bin",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    configureModule(b, exe.root_module, options);
    b.installArtifact(exe);

    // `share/man/<section>/<page>` is the standard search layout `man(1)`
    // expects under a `-M`/`MANPATH` prefix.
    for (man_pages) |page| {
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
            b.path(b.fmt("man/{s}", .{page.file})),
            .{ .custom = b.fmt("share/man/{s}", .{page.section}) },
            page.file,
        ).step);
    }

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
        configureModule(b, rel_exe.root_module, options);
        const triple = query.zigTriple(b.allocator) catch @panic("OOM");
        const install = b.addInstallArtifact(rel_exe, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("release/{s}", .{triple}) } },
        });
        release_step.dependOn(&install.step);
    }

    // `zig build e2e` builds the binary then runs the hermetic e2e scripts.
    const e2e_step = b.step("e2e", "Run end-to-end tests");
    for (&[_][]const u8{ "e2e/review_e2e.sh", "e2e/rm_safety_e2e.sh", "e2e/doctor_e2e.sh", "e2e/hooks_e2e.sh", "e2e/standalone_e2e.sh", "e2e/man_check.sh" }) |script| {
        const e2e = b.addSystemCommand(&.{ "bash", script });
        e2e.step.dependOn(b.getInstallStep());
        e2e_step.dependOn(&e2e.step);
    }

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    configureModule(b, unit_tests.root_module, options);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // `zig build fmt-check` fails if any tracked .zig file isn't `zig fmt`-clean.
    const fmt_check = b.addFmt(.{
        .paths = &.{ "src", "build.zig" },
        .check = true,
    });
    const fmt_check_step = b.step("fmt-check", "Check formatting (zig fmt --check)");
    fmt_check_step.dependOn(&fmt_check.step);
}
