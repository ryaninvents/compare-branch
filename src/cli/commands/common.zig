const std = @import("std");
const app = @import("../app.zig");
const store = @import("../../state/store.zig");
const model = @import("../../state/model.zig");
const sanitize = @import("../../util/sanitize.zig");
const locate = @import("../../state/locate.zig");
const args = @import("../args.zig");

// Helpers shared across command handlers: state access, worktree path
// computation, and an interactive confirmation prompt.

pub fn loadState(ctx: *app.Context) !model.State {
    return store.load(ctx.gpa, ctx.state_path);
}

pub fn requireProject(state: *model.State, key: []const u8) !*model.Project {
    return state.getProject(key) orelse error.ProjectNotFound;
}

pub const Ref = struct { project: []const u8, key: []const u8 };

/// Resolve a `<project-key> <worktree-key>` pair from explicit positionals, or
/// by inferring the worktree containing the current directory when both are
/// omitted. Never guesses on ambiguity or a project-only match (a worktree key
/// is required here) — those fail loudly rather than silently picking one.
pub fn resolveRef(ctx: *app.Context, state: *model.State, a: *const args.Args) !Ref {
    if (a.pos(0)) |p| {
        if (a.pos(1)) |k| return .{ .project = p, .key = k };
        return error.MissingArgument;
    }
    const loc = try locateCwd(ctx, state);
    return switch (loc) {
        .worktree => |w| .{ .project = w.project, .key = w.worktree },
        .project => error.MissingArgument,
        .none => error.NotInWorktree,
        .ambiguous => error.AmbiguousContext,
    };
}

/// Resolve a project key from an explicit positional, or by inferring the
/// project containing the current directory (whether that's the project's
/// main checkout or one of its worktrees) when omitted.
pub fn resolveProjectKey(ctx: *app.Context, state: *model.State, a: *const args.Args) ![]const u8 {
    if (a.pos(0)) |p| return p;
    const loc = try locateCwd(ctx, state);
    return switch (loc) {
        .worktree => |w| w.project,
        .project => |p| p.project,
        .none => error.NotInWorktree,
        .ambiguous => error.AmbiguousContext,
    };
}

fn locateCwd(ctx: *app.Context, state: *model.State) !locate.Location {
    const raw_cwd = std.process.getCwdAlloc(ctx.gpa) catch return error.NoHome;
    defer ctx.gpa.free(raw_cwd);
    const cwd = try locate.canonicalize(ctx.gpa, raw_cwd);
    defer ctx.gpa.free(cwd);
    return locate.locate(state, cwd);
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
