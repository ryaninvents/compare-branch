const std = @import("std");
const app = @import("cli/app.zig");
const config = @import("config/config.zig");
const git = @import("git/git.zig");
const paths = @import("util/paths.zig");

// Composition root: construct every dependency for the real environment, wire
// them into a Context, and dispatch. No logic lives here beyond wiring.

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const raw = try std.process.argsAlloc(gpa);
    var argv = try gpa.alloc([]const u8, if (raw.len > 1) raw.len - 1 else 0);
    for (raw[@min(1, raw.len)..], 0..) |arg, i| argv[i] = arg;

    const config_path = try paths.configPath(gpa);
    var cfg = try config.load(gpa, config_path);
    defer cfg.deinit();

    const state_path = try paths.statePath(gpa);

    var ctx = app.Context{
        .gpa = gpa,
        .config = &cfg,
        .git = .{ .allocator = gpa },
        .state_path = state_path,
        .now_unix = std.time.timestamp(),
        .stdout = std.io.getStdOut().writer(),
        .stderr = std.io.getStdErr().writer(),
    };

    const code = try app.run(&ctx, argv);
    std.process.exit(code);
}

// Pull in modules that carry unit tests so `zig build test` runs them.
test {
    std.testing.refAllDeclsRecursive(@This());
    _ = @import("util/sanitize.zig");
    _ = @import("config/template.zig");
    _ = @import("cli/args.zig");
    _ = @import("state/store.zig");
}
