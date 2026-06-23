const std = @import("std");
const app = @import("../cli/app.zig");
const git = @import("../git/git.zig");

// The incremental-review machinery, modeled on rapid-review's --git-dir trick:
// a throwaway "review repo" R that shares the project's object database via
// objects/info/alternates and keeps its own HEAD/index/refs so the real .git is
// never touched.
//
//   HEAD (refs/heads/review) = the reviewed baseline; starts at the merge-base
//     and advances each time the reviewer commits a batch.
//   working tree            = the full target content the reviewer reads.
//   `git status`            = working tree vs index(HEAD) = exactly what is left
//                             to review.
//
// `cb refresh` re-fetches the target and uses `git restore --source` to update
// the working tree only, so amended-but-already-reviewed code reappears without
// discarding committed review progress.

pub const target_ref = "refs/cb/target";
pub const mainline_ref = "refs/cb/mainline";
pub const review_branch = "refs/heads/review";

pub fn reviewDir(ctx: *app.Context, proj: []const u8, key: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(ctx.state_path) orelse ".";
    const leaf = try std.fmt.allocPrint(ctx.gpa, "{s}--{s}.git", .{ proj, key });
    defer ctx.gpa.free(leaf);
    return std.fs.path.join(ctx.gpa, &.{ dir, "reviews", leaf });
}

fn isolated(ctx: *app.Context, git_dir: []const u8, work_tree: ?[]const u8) git.Git {
    var g = ctx.git;
    g.git_dir = git_dir;
    g.work_tree = work_tree;
    return g;
}

fn must(ctx: *app.Context, out: *git.Output) !void {
    if (!out.ok()) {
        ctx.warn("{s}", .{out.stderr});
        return error.GitFailed;
    }
}

fn runMust(ctx: *app.Context, g: git.Git, cwd: ?[]const u8, argv: []const []const u8) !void {
    var out = try g.run(cwd, argv);
    defer out.deinit();
    try must(ctx, &out);
}

fn initIsolated(ctx: *app.Context, git_dir: []const u8, project_dir: []const u8) !void {
    try std.fs.cwd().makePath(git_dir);
    try runMust(ctx, ctx.git, null, &.{ "--git-dir", git_dir, "init", "-q", "--bare" });

    // Share the project's objects so target/base trees need no re-download.
    const alt_path = try std.fs.path.join(ctx.gpa, &.{ git_dir, "objects", "info", "alternates" });
    defer ctx.gpa.free(alt_path);
    const objects = try std.fs.path.join(ctx.gpa, &.{ project_dir, ".git", "objects" });
    defer ctx.gpa.free(objects);
    const f = try std.fs.cwd().createFile(alt_path, .{});
    defer f.close();
    try f.writeAll(objects);
    try f.writeAll("\n");
}

fn fetchRef(ctx: *app.Context, git_dir: []const u8, from: []const u8, src: []const u8, dst: []const u8) !void {
    const spec = try std.fmt.allocPrint(ctx.gpa, "+{s}:{s}", .{ src, dst });
    defer ctx.gpa.free(spec);
    try runMust(ctx, ctx.git, null, &.{ "--git-dir", git_dir, "fetch", "-q", from, spec });
}

/// Set HEAD/refs/heads/review to `base_commit` and reset the index to it.
fn seedBaseline(ctx: *app.Context, g: git.Git, git_dir: []const u8, base_commit: []const u8) !void {
    const sha = try ctx.git.capture(null, &.{ "--git-dir", git_dir, "rev-parse", base_commit });
    defer ctx.gpa.free(sha);
    try runMust(ctx, ctx.git, null, &.{ "--git-dir", git_dir, "update-ref", review_branch, sha });
    try runMust(ctx, ctx.git, null, &.{ "--git-dir", git_dir, "symbolic-ref", "HEAD", review_branch });
    try runMust(ctx, g, null, &.{ "read-tree", "HEAD" });
}

pub const RemoteOpts = struct {
    project_dir: []const u8,
    branch: []const u8,
    default_branch: []const u8,
    base_arg: ?[]const u8,
    no_merge_base: bool,
    git_dir: []const u8,
    work_tree: []const u8,
};

pub fn setupRemote(ctx: *app.Context, o: RemoteOpts) !void {
    try initIsolated(ctx, o.git_dir, o.project_dir);

    // Best-effort: refresh origin so the branch tip is current. Tolerate
    // offline by ignoring failure here; the fetch into R below is what matters.
    var fo = try ctx.git.run(o.project_dir, &.{ "fetch", "-q", "origin", o.branch });
    fo.deinit();

    const origin_target = try std.fmt.allocPrint(ctx.gpa, "refs/remotes/origin/{s}", .{o.branch});
    defer ctx.gpa.free(origin_target);
    try fetchRef(ctx, o.git_dir, o.project_dir, origin_target, target_ref);

    const mainline_src = o.base_arg orelse try std.fmt.allocPrint(ctx.gpa, "refs/remotes/origin/{s}", .{o.default_branch});
    const owns_mainline = o.base_arg == null;
    defer if (owns_mainline) ctx.gpa.free(mainline_src);
    try fetchRef(ctx, o.git_dir, o.project_dir, mainline_src, mainline_ref);

    const base_commit = if (o.no_merge_base)
        try ctx.gpa.dupe(u8, mainline_ref)
    else
        try ctx.git.capture(null, &.{ "--git-dir", o.git_dir, "merge-base", target_ref, mainline_ref });
    defer ctx.gpa.free(base_commit);

    try populateAndSeed(ctx, o.git_dir, o.work_tree, base_commit);
}

/// Fill the (empty) work tree with the target's content, then reset the index
/// and HEAD to the base so everything from base→target reads as "to review".
fn populateAndSeed(ctx: *app.Context, git_dir: []const u8, work_tree: []const u8, base_commit: []const u8) !void {
    try std.fs.cwd().makePath(work_tree);
    const g = isolated(ctx, git_dir, work_tree);
    try runMust(ctx, g, null, &.{ "read-tree", target_ref });
    try runMust(ctx, g, null, &.{ "checkout-index", "-a", "-f" });
    try seedBaseline(ctx, g, git_dir, base_commit);
}

pub const LocalOpts = struct {
    project_dir: []const u8,
    target_dir: []const u8,
    default_branch: []const u8,
    base_arg: ?[]const u8,
    git_dir: []const u8,
};

pub fn setupLocal(ctx: *app.Context, o: LocalOpts) !void {
    try initIsolated(ctx, o.git_dir, o.project_dir);

    const mainline_src = o.base_arg orelse try std.fmt.allocPrint(ctx.gpa, "refs/remotes/origin/{s}", .{o.default_branch});
    const owns = o.base_arg == null;
    defer if (owns) ctx.gpa.free(mainline_src);
    // Fall back to the local branch ref if there's no origin remote.
    fetchRef(ctx, o.git_dir, o.project_dir, mainline_src, mainline_ref) catch {
        const local_ref = try std.fmt.allocPrint(ctx.gpa, "refs/heads/{s}", .{o.default_branch});
        defer ctx.gpa.free(local_ref);
        try fetchRef(ctx, o.git_dir, o.project_dir, local_ref, mainline_ref);
    };

    // Work tree is the live target dir; only the index is seeded (files stay).
    const g = isolated(ctx, o.git_dir, o.target_dir);
    try seedBaseline(ctx, g, o.git_dir, mainline_ref);
}

pub fn refreshRemote(ctx: *app.Context, git_dir: []const u8, work_tree: []const u8, project_dir: []const u8, branch: []const u8) !void {
    var fo = try ctx.git.run(project_dir, &.{ "fetch", "-q", "origin", branch });
    fo.deinit();
    const origin_target = try std.fmt.allocPrint(ctx.gpa, "refs/remotes/origin/{s}", .{branch});
    defer ctx.gpa.free(origin_target);
    try fetchRef(ctx, git_dir, project_dir, origin_target, target_ref);

    // Update only the working tree to the new target; index (reviewed baseline)
    // is left intact so amended reviewed files resurface as unreviewed.
    const g = isolated(ctx, git_dir, work_tree);
    var out = try g.run(work_tree, &.{ "restore", "--source", target_ref, "--worktree", "--", "." });
    defer out.deinit();
    try must(ctx, &out);
}
