const std = @import("std");
const app = @import("../app.zig");
const store = @import("../../state/store.zig");
const model = @import("../../state/model.zig");
const sanitize = @import("../../util/sanitize.zig");

// Helpers shared across command handlers: state access, worktree path
// computation, and an interactive confirmation prompt.

pub fn loadState(ctx: *app.Context) !model.State {
    return store.load(ctx.gpa, ctx.state_path);
}

pub fn requireProject(state: *model.State, key: []const u8) !*model.Project {
    return state.getProject(key) orelse error.ProjectNotFound;
}

/// Directory that holds a project's worktrees. An explicit --worktrees path
/// wins; otherwise worktrees sit in workDir, optionally nested under a category.
pub fn worktreeContainer(ctx: *app.Context, project: *const model.Project) ![]u8 {
    if (project.worktrees_path) |p| return ctx.gpa.dupe(u8, p);
    const work_dir = try ctx.config.renderWorkDir(ctx.gpa, ctx.now_unix);
    defer ctx.gpa.free(work_dir);
    if (project.category) |cat| {
        return std.fs.path.join(ctx.gpa, &.{ work_dir, cat });
    }
    return ctx.gpa.dupe(u8, work_dir);
}

pub fn worktreeDir(ctx: *app.Context, container: []const u8, branch: []const u8) ![]u8 {
    const dir_name = try sanitize.branchToDir(ctx.gpa, branch);
    defer ctx.gpa.free(dir_name);
    return std.fs.path.join(ctx.gpa, &.{ container, dir_name });
}

/// Prompt y/N on stderr, read a line from stdin. Defaults to no.
pub fn confirm(ctx: *app.Context, prompt: []const u8) !bool {
    ctx.warn("{s} [y/N] ", .{prompt});
    var buf: [16]u8 = undefined;
    const stdin = std.io.getStdIn().reader();
    const line = stdin.readUntilDelimiterOrEof(&buf, '\n') catch return false;
    const answer = std.mem.trim(u8, line orelse return false, " \t\r");
    return answer.len > 0 and (answer[0] == 'y' or answer[0] == 'Y');
}
