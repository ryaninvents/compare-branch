const std = @import("std");
const app = @import("../app.zig");
const common = @import("common.zig");

// `cb-bin __complete <what> [args]` emits newline-separated candidates for shell
// completion. It is hidden from the usage text and must stay quiet: unknown or
// missing arguments, or an empty/absent state log, print nothing and exit 0 so a
// tab-press never surfaces an error to the user.

pub fn complete(ctx: *app.Context, rest: []const []const u8) !void {
    const what = if (rest.len > 0) rest[0] else return;
    if (std.mem.eql(u8, what, "projects")) return projects(ctx);
    if (std.mem.eql(u8, what, "worktrees")) return worktrees(ctx, rest[1..]);
}

fn projects(ctx: *app.Context) !void {
    var state = common.loadState(ctx) catch return;
    defer state.deinit();

    var it = state.projects.keyIterator();
    while (it.next()) |key| ctx.print("{s}\n", .{key.*});
}

fn worktrees(ctx: *app.Context, rest: []const []const u8) !void {
    const project_key = if (rest.len > 0) rest[0] else return;

    var state = common.loadState(ctx) catch return;
    defer state.deinit();

    const project = state.getProject(project_key) orelse return;
    var it = project.worktrees.keyIterator();
    while (it.next()) |key| ctx.print("{s}\n", .{key.*});
}
