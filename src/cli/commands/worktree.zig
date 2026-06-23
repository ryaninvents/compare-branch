const std = @import("std");
const app = @import("../app.zig");
const args = @import("../args.zig");
const store = @import("../../state/store.zig");
const common = @import("common.zig");

// `cb mk` creates a branch + git worktree for a project; `cb rm` tears one down;
// `cb cd`/`cd-path` resolves the directory the shell wrapper cd's into.

pub fn mk(ctx: *app.Context, rest: []const []const u8) !void {
    var a = try args.parse(ctx.gpa, rest, &.{});
    defer a.deinit();

    const proj_key = a.pos(0) orelse return error.MissingArgument;
    const wt_key = a.pos(1) orelse return error.MissingArgument;

    var state = try common.loadState(ctx);
    defer state.deinit();
    const project = try common.requireProject(&state, proj_key);
    if (project.worktrees.get(wt_key) != null) return error.WorktreeExists;

    const ticket = a.value(&.{ "t", "ticket" });
    const note = a.value(&.{ "n", "note" });

    const branch = try resolveBranchName(ctx, &a, wt_key, ticket);
    defer ctx.gpa.free(branch);

    const base = try resolveBase(ctx, &a, project.dir);
    defer ctx.gpa.free(base);

    const container = try common.worktreeContainer(ctx, project);
    defer ctx.gpa.free(container);
    std.fs.cwd().makePath(container) catch {};

    const dir = try common.worktreeDir(ctx, container, branch);
    defer ctx.gpa.free(dir);

    try addWorktree(ctx, project.dir, branch, dir, base);

    try store.appendEvent(ctx.gpa, ctx.state_path, store.WorktreeCreated{
        .at = ctx.now_unix,
        .project = proj_key,
        .key = wt_key,
        .branch = branch,
        .dir = dir,
        .kind = "work",
        .ticket = ticket,
        .note = note,
        .base = base,
    });
    ctx.print("created worktree '{s}' on {s}\n{s}\n", .{ wt_key, branch, dir });
}

fn resolveBranchName(
    ctx: *app.Context,
    a: *const args.Args,
    wt_key: []const u8,
    ticket: ?[]const u8,
) ![]u8 {
    if (a.value(&.{"branch-name"})) |name| return ctx.gpa.dupe(u8, name);
    return ctx.config.renderBranchName(ctx.gpa, wt_key, ticket, ctx.now_unix);
}

fn resolveBase(ctx: *app.Context, a: *const args.Args, project_dir: []const u8) ![]u8 {
    if (a.value(&.{"base"})) |b| return ctx.gpa.dupe(u8, b);
    return ctx.git.defaultBranch(project_dir);
}

fn addWorktree(ctx: *app.Context, project_dir: []const u8, branch: []const u8, dir: []const u8, base: []const u8) !void {
    var out = try ctx.git.run(project_dir, &.{ "worktree", "add", "-b", branch, dir, base });
    defer out.deinit();
    if (!out.ok()) {
        ctx.warn("{s}", .{out.stderr});
        return error.GitFailed;
    }
}

pub fn rm(ctx: *app.Context, rest: []const []const u8) !void {
    var a = try args.parse(ctx.gpa, rest, &.{"force"});
    defer a.deinit();

    const proj_key = a.pos(0) orelse return error.MissingArgument;
    const wt_key = a.pos(1) orelse return error.MissingArgument;

    var state = try common.loadState(ctx);
    defer state.deinit();
    const project = try common.requireProject(&state, proj_key);
    const wt = project.worktrees.get(wt_key) orelse return error.WorktreeNotFound;

    if (!a.flag(&.{"force"})) {
        const ok = try common.confirm(ctx, "remove this worktree?");
        if (!ok) return error.Aborted;
    }

    var out = try ctx.git.run(project.dir, &.{ "worktree", "remove", "--force", wt.dir });
    defer out.deinit();
    // Even if the git worktree is already gone, drop it from our state so the
    // registry doesn't accumulate ghosts.
    if (!out.ok()) ctx.warn("warning: git worktree remove failed: {s}", .{out.stderr});

    try store.appendEvent(ctx.gpa, ctx.state_path, store.WorktreeRemoved{
        .at = ctx.now_unix,
        .project = proj_key,
        .key = wt_key,
    });
    ctx.print("removed worktree '{s}'\n", .{wt_key});
}

pub fn cdPath(ctx: *app.Context, rest: []const []const u8) !void {
    var a = try args.parse(ctx.gpa, rest, &.{});
    defer a.deinit();

    const proj_key = a.pos(0) orelse return error.MissingArgument;
    var state = try common.loadState(ctx);
    defer state.deinit();
    const project = try common.requireProject(&state, proj_key);

    if (a.pos(1)) |wt_key| {
        const wt = project.worktrees.get(wt_key) orelse return error.WorktreeNotFound;
        ctx.print("{s}\n", .{wt.dir});
        return;
    }
    ctx.print("{s}\n", .{project.dir});
}
