const std = @import("std");
const app = @import("../app.zig");
const args = @import("../args.zig");
const store = @import("../../state/store.zig");
const model = @import("../../state/model.zig");
const sanitize = @import("../../util/sanitize.zig");
const engine = @import("../../review/engine.zig");
const common = @import("common.zig");

// Review-flow commands. `review`/`review-local` create a review worktree and its
// isolated review repo; `refresh` pulls new changes into the batch; `review-shell`
// drops into an interactive shell wired to the review repo; `review-done`/
// `review-confirm-exit` back the in-shell `cb done`/`cb exit`.

pub fn review(ctx: *app.Context, rest: []const []const u8) !void {
    var a = try args.parse(ctx.gpa, rest, &.{ "no-merge-base", "shell" });
    defer a.deinit();

    const proj_key = a.pos(0) orelse return error.MissingArgument;
    const branch = a.pos(1) orelse return error.MissingArgument;

    var state = try common.loadState(ctx);
    defer state.deinit();
    const project = try common.requireProject(&state, proj_key);

    const key = try sanitize.branchToDir(ctx.gpa, branch);
    defer ctx.gpa.free(key);
    if (project.worktrees.get(key) != null) return error.WorktreeExists;

    const default_branch = try ctx.git.defaultBranch(project.dir);
    defer ctx.gpa.free(default_branch);

    const container = try common.worktreeContainer(ctx, project);
    defer ctx.gpa.free(container);
    std.fs.cwd().makePath(container) catch {};
    const work_tree = try common.worktreeDir(ctx, container, branch);
    defer ctx.gpa.free(work_tree);

    const git_dir = try engine.reviewDir(ctx, proj_key, key);
    defer ctx.gpa.free(git_dir);

    try engine.setupRemote(ctx, .{
        .project_dir = project.dir,
        .branch = branch,
        .default_branch = default_branch,
        .base_arg = a.value(&.{"base"}),
        .no_merge_base = a.flag(&.{"no-merge-base"}),
        .git_dir = git_dir,
        .work_tree = work_tree,
    });

    try store.appendEvent(ctx.gpa, ctx.state_path, store.WorktreeCreated{
        .at = ctx.now_unix,
        .project = proj_key,
        .key = key,
        .branch = branch,
        .dir = work_tree,
        .kind = "review",
        .ticket = a.value(&.{ "t", "ticket" }),
        .note = a.value(&.{ "n", "note" }),
        .base = a.value(&.{"base"}),
        .reviewBranch = branch,
    });
    ctx.print("review ready: {s}\n", .{work_tree});

    if (a.flag(&.{"shell"})) {
        try spawnReviewShell(ctx, proj_key, key, work_tree, git_dir);
    }
}

pub fn reviewLocal(ctx: *app.Context, rest: []const []const u8) !void {
    var a = try args.parse(ctx.gpa, rest, &.{});
    defer a.deinit();

    const proj_key = a.pos(0) orelse return error.MissingArgument;
    const target_dir = a.pos(1) orelse return error.MissingArgument;

    var state = try common.loadState(ctx);
    defer state.deinit();
    const project = try common.requireProject(&state, proj_key);

    const key = std.fs.path.basename(target_dir);
    if (project.worktrees.get(key) != null) return error.WorktreeExists;

    const default_branch = try ctx.git.defaultBranch(project.dir);
    defer ctx.gpa.free(default_branch);

    const git_dir = try engine.reviewDir(ctx, proj_key, key);
    defer ctx.gpa.free(git_dir);

    try engine.setupLocal(ctx, .{
        .project_dir = project.dir,
        .target_dir = target_dir,
        .default_branch = default_branch,
        .base_arg = a.value(&.{"base"}),
        .git_dir = git_dir,
    });

    try store.appendEvent(ctx.gpa, ctx.state_path, store.WorktreeCreated{
        .at = ctx.now_unix,
        .project = proj_key,
        .key = key,
        .branch = default_branch,
        .dir = target_dir,
        .kind = "review_local",
        .ticket = a.value(&.{ "t", "ticket" }),
        .note = a.value(&.{ "n", "note" }),
        .base = a.value(&.{"base"}),
        .targetDir = target_dir,
    });
    ctx.print("local review ready: {s}\n", .{target_dir});
}

pub fn refresh(ctx: *app.Context, rest: []const []const u8) !void {
    var a = try args.parse(ctx.gpa, rest, &.{});
    defer a.deinit();

    const ref = try resolveReviewRef(ctx, &a);
    defer ref.deinit(ctx);

    var state = try common.loadState(ctx);
    defer state.deinit();
    const project = try common.requireProject(&state, ref.project);
    const wt = project.worktrees.get(ref.key) orelse return error.WorktreeNotFound;

    const git_dir = try engine.reviewDir(ctx, ref.project, ref.key);
    defer ctx.gpa.free(git_dir);

    switch (wt.kind) {
        .review => try engine.refreshRemote(ctx, git_dir, wt.dir, project.dir, wt.review_branch orelse wt.branch),
        .review_local => ctx.print("local review tracks the working tree live; nothing to fetch\n", .{}),
        .work => return error.WorktreeNotFound,
    }

    try store.appendEvent(ctx.gpa, ctx.state_path, store.ReviewRefreshed{
        .at = ctx.now_unix,
        .project = ref.project,
        .key = ref.key,
    });
    ctx.print("refreshed '{s}'\n", .{ref.key});
}

pub fn reviewShell(ctx: *app.Context, rest: []const []const u8) !void {
    var a = try args.parse(ctx.gpa, rest, &.{});
    defer a.deinit();
    const proj_key = a.pos(0) orelse return error.MissingArgument;
    const wt_key = a.pos(1) orelse return error.MissingArgument;

    var state = try common.loadState(ctx);
    defer state.deinit();
    const project = try common.requireProject(&state, proj_key);
    const wt = project.worktrees.get(wt_key) orelse return error.WorktreeNotFound;

    const git_dir = try engine.reviewDir(ctx, proj_key, wt_key);
    defer ctx.gpa.free(git_dir);
    try spawnReviewShell(ctx, proj_key, wt_key, wt.dir, git_dir);
}

pub fn reviewDone(ctx: *app.Context, rest: []const []const u8) !void {
    var a = try args.parse(ctx.gpa, rest, &.{"force"});
    defer a.deinit();
    const proj_key = a.pos(0) orelse return error.MissingArgument;
    const wt_key = a.pos(1) orelse return error.MissingArgument;

    var state = try common.loadState(ctx);
    defer state.deinit();
    const project = try common.requireProject(&state, proj_key);
    const wt = project.worktrees.get(wt_key) orelse return error.WorktreeNotFound;

    if (!a.flag(&.{"force"})) {
        const ok = try common.confirm(ctx, "finish review and delete this worktree?");
        if (!ok) return error.Aborted;
    }

    // Remote reviews own their worktree dir and can be deleted; local reviews
    // point at the user's own directory, which we must never remove.
    if (wt.kind == .review) std.fs.cwd().deleteTree(wt.dir) catch {};
    const git_dir = try engine.reviewDir(ctx, proj_key, wt_key);
    defer ctx.gpa.free(git_dir);
    std.fs.cwd().deleteTree(git_dir) catch {};

    try store.appendEvent(ctx.gpa, ctx.state_path, store.WorktreeRemoved{
        .at = ctx.now_unix,
        .project = proj_key,
        .key = wt_key,
    });
    ctx.warn("review complete; worktree '{s}' removed\n", .{wt_key});
}

pub fn confirmExit(ctx: *app.Context, rest: []const []const u8) !void {
    _ = rest;
    const ok = try common.confirm(ctx, "exit the review shell?");
    if (!ok) return error.Aborted;
}

// --- helpers ---

const ReviewRef = struct {
    project: []const u8,
    key: []const u8,
    owned: bool,

    fn deinit(self: ReviewRef, ctx: *app.Context) void {
        if (self.owned) {
            ctx.gpa.free(self.project);
            ctx.gpa.free(self.key);
        }
    }
};

/// In a review shell `cb refresh` takes no args; recover the target from the
/// CB_REVIEW="<project> <key>" env set when the shell was spawned.
fn resolveReviewRef(ctx: *app.Context, a: *const args.Args) !ReviewRef {
    if (a.pos(0)) |p| {
        if (a.pos(1)) |k| return .{ .project = p, .key = k, .owned = false };
    }
    const env = std.process.getEnvVarOwned(ctx.gpa, "CB_REVIEW") catch return error.MissingArgument;
    defer ctx.gpa.free(env);
    const sp = std.mem.indexOfScalar(u8, env, ' ') orelse return error.MissingArgument;
    return .{
        .project = try ctx.gpa.dupe(u8, env[0..sp]),
        .key = try ctx.gpa.dupe(u8, env[sp + 1 ..]),
        .owned = true,
    };
}

fn spawnReviewShell(ctx: *app.Context, proj: []const u8, key: []const u8, work_tree: []const u8, git_dir: []const u8) !void {
    const shell_path = std.process.getEnvVarOwned(ctx.gpa, "SHELL") catch try ctx.gpa.dupe(u8, "/bin/sh");
    defer ctx.gpa.free(shell_path);

    var env = try std.process.getEnvMap(ctx.gpa);
    defer env.deinit();
    try env.put("GIT_DIR", git_dir);
    try env.put("GIT_WORK_TREE", work_tree);
    const marker = try std.fmt.allocPrint(ctx.gpa, "{s} {s}", .{ proj, key });
    defer ctx.gpa.free(marker);
    try env.put("CB_REVIEW", marker);

    ctx.warn("entering review shell — `git status` shows what's left; `cb refresh`, `cb done`, `cb exit`.\n", .{});

    var child = std.process.Child.init(&.{shell_path}, ctx.gpa);
    child.cwd = work_tree;
    child.env_map = &env;
    _ = child.spawnAndWait() catch return error.SpawnFailed;
}
