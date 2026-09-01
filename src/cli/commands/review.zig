const std = @import("std");
const app = @import("../app.zig");
const args = @import("../args.zig");
const store = @import("../../state/store.zig");
const model = @import("../../state/model.zig");
const sanitize = @import("../../util/sanitize.zig");
const engine = @import("../../review/engine.zig");
const common = @import("common.zig");
const pr = @import("../../review/pr.zig");

// Review-flow commands. `review`/`review-local` create a review worktree and its
// isolated review repo; `refresh` pulls new changes into the batch; `review-shell`
// drops into an interactive shell wired to the review repo; `review-done`/
// `review-confirm-exit` back the in-shell `cb done`/`cb exit`.

pub fn review(ctx: *app.Context, rest: []const []const u8) !void {
    var a = try args.parse(ctx.gpa, rest, &.{ "no-merge-base", "shell" });
    defer a.deinit();

    const proj_key = a.pos(0) orelse return error.MissingArgument;
    const target = a.pos(1) orelse return error.MissingArgument;

    var state = try common.loadState(ctx);
    defer state.deinit();
    const project = try common.requireProject(&state, proj_key);

    // A bare number or a PR URL resolves via `gh` to its head branch; anything
    // else is treated as a branch name directly, exactly as before.
    var pr_info: ?pr.PrInfo = null;
    defer if (pr_info) |*p| p.deinit(ctx.gpa);
    const pr_number = pr.detectPrNumber(target);
    if (pr_number) |n| {
        pr_info = try resolvePr(ctx, project.dir, n);
        if (pr_info.?.is_cross_repository) {
            ctx.warn(
                "cb review: PR #{s} is from a fork; origin/<branch> won't exist locally.\n" ++
                    "  Fetch it manually (e.g. git fetch origin refs/pull/{s}/head:<local-branch>)\n" ++
                    "  and run `cb review {s} <local-branch>` instead.\n",
                .{ n, n, proj_key },
            );
            return error.ForkPrNotSupported;
        }
    }

    const branch: []const u8 = if (pr_info) |p| p.head_ref else target;
    const key: []u8 = if (pr_number) |n|
        try std.fmt.allocPrint(ctx.gpa, "pr-{s}", .{n})
    else
        try sanitize.branchToDir(ctx.gpa, target);
    defer ctx.gpa.free(key);
    if (project.worktrees.get(key) != null) return error.WorktreeExists;

    const default_branch = try ctx.git.defaultBranch(project.dir);
    defer ctx.gpa.free(default_branch);

    const container = try common.worktreeContainer(ctx, project);
    defer ctx.gpa.free(container);
    std.fs.cwd().makePath(container) catch {};
    const raw_work_tree = try common.worktreeDir(ctx, container, branch);
    defer ctx.gpa.free(raw_work_tree);

    const git_dir = try engine.reviewDir(ctx, proj_key, key);
    defer ctx.gpa.free(git_dir);

    try engine.setupRemote(ctx, .{
        .project_dir = project.dir,
        .branch = branch,
        .default_branch = default_branch,
        .base_arg = a.value(&.{"base"}),
        .no_merge_base = a.flag(&.{"no-merge-base"}),
        .git_dir = git_dir,
        .work_tree = raw_work_tree,
    });

    // Canonicalize now that the worktree exists, so this dir compares
    // correctly against std.process.getCwdAlloc()'s resolved output in
    // state/locate.zig (e.g. macOS's /tmp -> /private/tmp) — same reasoning
    // as worktree.mk().
    const work_tree = std.fs.cwd().realpathAlloc(ctx.gpa, raw_work_tree) catch try ctx.gpa.dupe(u8, raw_work_tree);
    defer ctx.gpa.free(work_tree);

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
        .prTitle = if (pr_info) |p| p.title else null,
        .prAuthor = if (pr_info) |p| p.author else null,
        .prUrl = if (pr_info) |p| p.url else null,
    });
    ctx.print("review ready: {s}\n", .{work_tree});
    if (pr_info) |p| {
        if (p.title) |t| ctx.print("  PR: {s}\n", .{t});
        if (p.author) |au| ctx.print("  author: {s}\n", .{au});
    }

    if (a.flag(&.{"shell"})) {
        try spawnReviewShell(ctx, proj_key, key, work_tree, git_dir);
    }
}

pub fn reviewLocal(ctx: *app.Context, rest: []const []const u8) !void {
    var a = try args.parse(ctx.gpa, rest, &.{});
    defer a.deinit();

    const proj_key = a.pos(0) orelse return error.MissingArgument;
    const raw_target_dir = a.pos(1) orelse return error.MissingArgument;
    // Canonicalize so this compares correctly against
    // std.process.getCwdAlloc()'s resolved output in state/locate.zig (e.g.
    // macOS's /tmp -> /private/tmp) — same reasoning as worktree.mk().
    const target_dir = std.fs.cwd().realpathAlloc(ctx.gpa, raw_target_dir) catch try ctx.gpa.dupe(u8, raw_target_dir);
    defer ctx.gpa.free(target_dir);

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

    var state = try common.loadState(ctx);
    defer state.deinit();

    const ref = try resolveReviewRef(ctx, &state, &a);
    defer ref.deinit(ctx);

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
    var a = try args.parse(ctx.gpa, rest, &.{"i"});
    defer a.deinit();

    var state = try common.loadState(ctx);
    defer state.deinit();

    var proj_key: []const u8 = undefined;
    var wt_key: []const u8 = undefined;
    if (a.flag(&.{"i"})) {
        proj_key = if (a.pos(0)) |p| p else (try common.pickProjectKey(ctx, &state)) orelse return error.Aborted;
        const pick_project = try common.requireProject(&state, proj_key);
        wt_key = (try common.pickWorktreeKey(ctx, pick_project, isReviewKind)) orelse return error.Aborted;
    } else {
        proj_key = a.pos(0) orelse return error.MissingArgument;
        wt_key = a.pos(1) orelse return error.MissingArgument;
    }

    const project = try common.requireProject(&state, proj_key);
    const wt = project.worktrees.get(wt_key) orelse return error.WorktreeNotFound;

    const git_dir = try engine.reviewDir(ctx, proj_key, wt_key);
    defer ctx.gpa.free(git_dir);
    try spawnReviewShell(ctx, proj_key, wt_key, wt.dir, git_dir);
}

fn isReviewKind(kind: model.Kind) bool {
    return kind == .review or kind == .review_local;
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
/// CB_REVIEW="<project> <key>" env set when the shell was spawned. Outside a
/// review shell with no args, fall back to inferring the worktree containing
/// the current directory (common.resolveRef) — the env check goes first since
/// it's an exact match rather than a path-prefix guess.
fn resolveReviewRef(ctx: *app.Context, state: *model.State, a: *const args.Args) !ReviewRef {
    if (a.pos(0)) |p| {
        if (a.pos(1)) |k| return .{ .project = p, .key = k, .owned = false };
    }
    if (std.process.getEnvVarOwned(ctx.gpa, "CB_REVIEW")) |env| {
        defer ctx.gpa.free(env);
        if (std.mem.indexOfScalar(u8, env, ' ')) |sp| {
            return .{
                .project = try ctx.gpa.dupe(u8, env[0..sp]),
                .key = try ctx.gpa.dupe(u8, env[sp + 1 ..]),
                .owned = true,
            };
        }
    } else |_| {}
    const ref = try common.resolveRef(ctx, state, a);
    return .{ .project = ref.project, .key = ref.key, .owned = false };
}

/// Resolves a PR number via `gh pr view`. No `--repo`/`--hostname` override:
/// `gh` infers the target host from the project's git remote, so this works
/// against GitHub Enterprise the same way it works against github.com, as
/// long as `gh auth login --hostname <host>` has been run once for that host.
fn resolvePr(ctx: *app.Context, project_dir: []const u8, pr_number: []const u8) !pr.PrInfo {
    const argv = &.{ "gh", "pr", "view", pr_number, "--json", "headRefName,title,author,url,isCrossRepository" };
    const result = std.process.Child.run(.{
        .allocator = ctx.gpa,
        .argv = argv,
        .cwd = project_dir,
        .max_output_bytes = 1 * 1024 * 1024,
    }) catch |err| return switch (err) {
        error.FileNotFound => error.GhNotFound,
        else => error.GhFailed,
    };
    defer ctx.gpa.free(result.stdout);
    defer ctx.gpa.free(result.stderr);

    const ok = switch (result.term) {
        .Exited => |c| c == 0,
        else => false,
    };
    if (!ok) {
        ctx.warn("{s}", .{result.stderr});
        return error.GhFailed;
    }

    return pr.parsePrJson(ctx.gpa, result.stdout) catch return error.GhFailed;
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
