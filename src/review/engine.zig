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
//   working tree            = a real `git worktree add` checkout of the target
//     branch in the project repo, so plain `git`/`gh` work in it outside the
//     review shell (log, status, remotes, `gh pr view --web`).
//   `git status`            = (inside the review shell, GIT_DIR/GIT_WORK_TREE
//                             pointed at R) working tree vs index(HEAD) =
//                             exactly what is left to review.
//
// The two views share the same directory but never fight: R's HEAD/index live
// entirely in R's own git-dir, untouched by the project-side worktree's HEAD/
// index. `cb refresh` re-fetches the target and `git reset --hard`s the
// project-side worktree to the new tip — updating the shared working tree
// files exactly as a `restore` would, but also keeping the plain `cd` view's
// history and status accurate. It also re-derives the base the same way setup
// did (refs/cb/base tracks the last one) and 3-way-merges mainline's delta
// into the reviewed baseline, so a merge-from-main or a moved base branch
// reads as already-reviewed instead of muddying the diff with someone else's
// already-landed code.

pub const target_ref = "refs/cb/target";
pub const mainline_ref = "refs/cb/mainline";
pub const base_ref = "refs/cb/base";
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

/// Fetch the mainline/base branch into refs/cb/mainline. `base_arg` (--base)
/// wins when given; otherwise origin/<default_branch>, falling back to the
/// local refs/heads/<default_branch> when there's no origin remote to reach.
/// Setup and refresh must resolve this identically or refresh's merge-base
/// would silently diverge from the one the review was created with.
fn fetchMainline(ctx: *app.Context, git_dir: []const u8, project_dir: []const u8, base_arg: ?[]const u8, default_branch: []const u8) !void {
    const mainline_src = base_arg orelse try std.fmt.allocPrint(ctx.gpa, "refs/remotes/origin/{s}", .{default_branch});
    const owns = base_arg == null;
    defer if (owns) ctx.gpa.free(mainline_src);
    fetchRef(ctx, git_dir, project_dir, mainline_src, mainline_ref) catch {
        const local_ref = try std.fmt.allocPrint(ctx.gpa, "refs/heads/{s}", .{default_branch});
        defer ctx.gpa.free(local_ref);
        try fetchRef(ctx, git_dir, project_dir, local_ref, mainline_ref);
    };
}

/// Set HEAD/refs/heads/review to `base_commit` and reset the index to it.
/// Also records `base_commit` as refs/cb/base, the pin `cb refresh` diffs
/// against to find what mainline has newly absorbed.
fn seedBaseline(ctx: *app.Context, g: git.Git, git_dir: []const u8, base_commit: []const u8) !void {
    const sha = try ctx.git.capture(null, &.{ "--git-dir", git_dir, "rev-parse", base_commit });
    defer ctx.gpa.free(sha);
    try runMust(ctx, ctx.git, null, &.{ "--git-dir", git_dir, "update-ref", review_branch, sha });
    try runMust(ctx, ctx.git, null, &.{ "--git-dir", git_dir, "update-ref", base_ref, sha });
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
    /// Self-contained mode: the checkout becomes an independent `git clone`
    /// instead of a linked worktree, and the review repo's borrowed objects
    /// are repacked in and its `objects/info/alternates` dropped, so the
    /// whole review directory can be mounted alone with nothing else present.
    standalone: bool = false,
    /// The project's real remote URL, used to point a standalone checkout's
    /// `origin` at it instead of the project's local path. Ignored unless
    /// `standalone` is set.
    origin_url: ?[]const u8 = null,
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

    try fetchMainline(ctx, o.git_dir, o.project_dir, o.base_arg, o.default_branch);

    const base_commit = if (o.no_merge_base)
        try ctx.gpa.dupe(u8, mainline_ref)
    else
        try ctx.git.capture(null, &.{ "--git-dir", o.git_dir, "merge-base", target_ref, mainline_ref });
    defer ctx.gpa.free(base_commit);

    if (o.standalone) {
        try addStandaloneReviewCheckout(ctx, o.project_dir, o.branch, origin_target, o.work_tree, o.origin_url);
    } else {
        try addProjectWorktree(ctx, o.project_dir, o.branch, origin_target, o.work_tree);
    }

    const g = isolated(ctx, o.git_dir, o.work_tree);
    try seedBaseline(ctx, g, o.git_dir, base_commit);

    if (o.standalone) try severAlternates(ctx, o.git_dir);
}

/// Check out the target branch as an independent `git clone --local` (hard-
/// linked objects: near-instant, near-zero extra disk on the same
/// filesystem) rather than a linked worktree, so the checkout itself never
/// depends on the project repo's object store.
fn addStandaloneReviewCheckout(ctx: *app.Context, project_dir: []const u8, branch: []const u8, origin_ref: []const u8, dir: []const u8, origin_url: ?[]const u8) !void {
    const target_sha = try ctx.git.capture(project_dir, &.{ "rev-parse", origin_ref });
    defer ctx.gpa.free(target_sha);

    var clone_out = try ctx.git.run(null, &.{ "clone", "--local", "--no-checkout", project_dir, dir });
    defer clone_out.deinit();
    if (!clone_out.ok()) {
        ctx.warn("{s}", .{clone_out.stderr});
        return error.GitFailed;
    }

    var checkout_out = try ctx.git.run(dir, &.{ "checkout", "-b", branch, target_sha });
    defer checkout_out.deinit();
    if (!checkout_out.ok()) {
        ctx.warn("{s}", .{checkout_out.stderr});
        return error.GitFailed;
    }

    if (origin_url) |url| {
        var seturl_out = ctx.git.run(dir, &.{ "remote", "set-url", "origin", url }) catch return;
        seturl_out.deinit();
    }
}

/// Pack the review repo's objects (reachable through the alternates link) in
/// locally, then drop the alternates file, so the review repo no longer
/// depends on the project repo's object database. `git repack -a -d` must run
/// before the alternates file is removed, or it can't resolve the borrowed
/// objects it's packing in.
fn severAlternates(ctx: *app.Context, git_dir: []const u8) !void {
    var out = try ctx.git.run(null, &.{ "--git-dir", git_dir, "repack", "-a", "-d" });
    defer out.deinit();
    if (!out.ok()) {
        ctx.warn("{s}", .{out.stderr});
        return error.GitFailed;
    }

    const alt_path = try std.fs.path.join(ctx.gpa, &.{ git_dir, "objects", "info", "alternates" });
    defer ctx.gpa.free(alt_path);
    std.fs.cwd().deleteFile(alt_path) catch {};
}

/// Check out the target branch as a real linked `git worktree` of the project
/// repo, so plain git/gh work in it outside the review shell. Prefers a
/// tracking branch (so `gh pr view` can infer the PR from the branch name);
/// falls back to a detached checkout when the branch is already checked out
/// elsewhere or otherwise unavailable as a new local branch.
fn addProjectWorktree(ctx: *app.Context, project_dir: []const u8, branch: []const u8, origin_ref: []const u8, dir: []const u8) !void {
    var out = try ctx.git.run(project_dir, &.{ "worktree", "add", "--track", "-b", branch, dir, origin_ref });
    defer out.deinit();
    if (out.ok()) return;

    ctx.warn(
        "cb review: could not create tracking branch '{s}' ({s}); falling back to a detached checkout (gh pr view will need an explicit PR number)\n",
        .{ branch, std.mem.trimRight(u8, out.stderr, "\n") },
    );
    var out2 = try ctx.git.run(project_dir, &.{ "worktree", "add", "--detach", dir, origin_ref });
    defer out2.deinit();
    if (!out2.ok()) {
        ctx.warn("{s}", .{out2.stderr});
        return error.GitFailed;
    }
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

    try fetchMainline(ctx, o.git_dir, o.project_dir, o.base_arg, o.default_branch);

    // Work tree is the live target dir; only the index is seeded (files stay).
    const g = isolated(ctx, o.git_dir, o.target_dir);
    try seedBaseline(ctx, g, o.git_dir, mainline_ref);
}

/// Result of `advanceBase`: whether the baseline moved and, if so, what
/// changed. `conflicts` are paths where mainline's change couldn't be
/// cleanly folded into the reviewed baseline and were left at their old
/// (reviewed) content — so they resurface as unreviewed once the working
/// tree, which does carry mainline's change, is restored.
pub const AdvanceResult = struct {
    advanced: bool = false,
    old_base: []const u8 = "",
    new_base: []const u8 = "",
    absorbed: usize = 0,
    conflicts: std.ArrayList([]u8),

    pub fn none(gpa: std.mem.Allocator) AdvanceResult {
        return .{ .conflicts = std.ArrayList([]u8).init(gpa) };
    }

    pub fn deinit(self: *AdvanceResult, gpa: std.mem.Allocator) void {
        if (self.advanced) {
            gpa.free(self.old_base);
            gpa.free(self.new_base);
        }
        for (self.conflicts.items) |p| gpa.free(p);
        self.conflicts.deinit();
    }
};

/// read-tree -m verifies the merged paths' *actual on-disk content* matches
/// what it expects to write, so it can't safely target the real reviewed
/// worktree (which already holds the target's checked-out content, not the
/// merge inputs) or a review_local review's live user directory. Give it an
/// empty directory of its own instead, inside the review repo it never
/// checks anything into (no -u is ever passed).
fn mergeScratchDir(gpa: std.mem.Allocator, git_dir: []const u8) ![]u8 {
    const scratch = try std.fs.path.join(gpa, &.{ git_dir, "cb-merge-scratch" });
    errdefer gpa.free(scratch);
    try std.fs.cwd().makePath(scratch);
    return scratch;
}

fn resetIndexToHead(g: git.Git) void {
    var out = g.run(null, &.{ "read-tree", "HEAD" }) catch return;
    out.deinit();
}

const Stage2 = struct { mode: []const u8, sha: []const u8 };

/// After a 3-way `read-tree -m`, resolve every conflicted path to its stage-2
/// ("ours" = reviewed baseline) content — or drop it if ours has no stage 2
/// (deleted on our side) — leaving a clean, write-tree-able index. Returns the
/// resolved paths.
fn resolveConflictsToOurs(ctx: *app.Context, g: git.Git, gpa: std.mem.Allocator) !std.ArrayList([]u8) {
    var out = try g.run(null, &.{ "ls-files", "-u" });
    defer out.deinit();
    try must(ctx, &out);

    var conflicts = std.ArrayList([]u8).init(gpa);
    errdefer {
        for (conflicts.items) |p| gpa.free(p);
        conflicts.deinit();
    }

    var lines = std.mem.splitScalar(u8, out.stdout, '\n');
    var cur_path: ?[]const u8 = null;
    var cur_stage2: ?Stage2 = null;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const path = line[tab + 1 ..];
        var it = std.mem.splitScalar(u8, line[0..tab], ' ');
        const mode = it.next() orelse continue;
        const sha = it.next() orelse continue;
        const stage = std.fmt.parseInt(u8, it.next() orelse continue, 10) catch continue;

        if (cur_path == null or !std.mem.eql(u8, cur_path.?, path)) {
            if (cur_path) |p| try flushConflict(ctx, g, gpa, &conflicts, p, cur_stage2);
            cur_path = path;
            cur_stage2 = null;
        }
        if (stage == 2) cur_stage2 = .{ .mode = mode, .sha = sha };
    }
    if (cur_path) |p| try flushConflict(ctx, g, gpa, &conflicts, p, cur_stage2);

    return conflicts;
}

fn flushConflict(ctx: *app.Context, g: git.Git, gpa: std.mem.Allocator, conflicts: *std.ArrayList([]u8), path: []const u8, stage2: ?Stage2) !void {
    if (stage2) |s2| {
        const cacheinfo = try std.fmt.allocPrint(ctx.gpa, "{s},{s},{s}", .{ s2.mode, s2.sha, path });
        defer ctx.gpa.free(cacheinfo);
        try runMust(ctx, g, null, &.{ "update-index", "--cacheinfo", cacheinfo });
    } else {
        try runMust(ctx, g, null, &.{ "update-index", "--force-remove", "--", path });
    }
    try conflicts.append(try gpa.dupe(u8, path));
}

/// Re-derive the base the same way setup did (merge-base of target and
/// mainline, or mainline's tip under --no-merge-base) and, if it moved,
/// 3-way-merge the delta into the reviewed baseline so mainline's own changes
/// read as already-reviewed. refs/cb/target and refs/cb/mainline must already
/// be freshly fetched by the caller.
fn advanceBase(ctx: *app.Context, git_dir: []const u8, no_merge_base: bool, merge_work_tree: []const u8) !AdvanceResult {
    const gpa = ctx.gpa;

    const new_base_sha = (if (no_merge_base)
        ctx.git.capture(null, &.{ "--git-dir", git_dir, "rev-parse", mainline_ref })
    else
        ctx.git.capture(null, &.{ "--git-dir", git_dir, "merge-base", target_ref, mainline_ref })) catch return AdvanceResult.none(gpa);
    errdefer gpa.free(new_base_sha);

    // refs/cb/base is absent for review repos created before it existed;
    // merge-base(review, mainline) recovers the same commit for any history
    // where mainline hasn't been rewritten. If neither resolves, leave the
    // baseline untouched rather than guess.
    const old_base_sha = (ctx.git.capture(null, &.{ "--git-dir", git_dir, "rev-parse", base_ref }) catch
        ctx.git.capture(null, &.{ "--git-dir", git_dir, "merge-base", review_branch, mainline_ref })) catch {
        gpa.free(new_base_sha);
        return AdvanceResult.none(gpa);
    };
    errdefer gpa.free(old_base_sha);

    if (std.mem.eql(u8, old_base_sha, new_base_sha)) {
        gpa.free(old_base_sha);
        gpa.free(new_base_sha);
        return AdvanceResult.none(gpa);
    }

    const old_review_tip = try ctx.git.capture(null, &.{ "--git-dir", git_dir, "rev-parse", review_branch });
    defer gpa.free(old_review_tip);

    const g = isolated(ctx, git_dir, merge_work_tree);
    // Defensive: the index at rest always equals HEAD's tree; resync first in
    // case a previous refresh was interrupted mid-merge.
    try runMust(ctx, g, null, &.{ "read-tree", "HEAD" });
    errdefer resetIndexToHead(g);

    try runMust(ctx, g, null, &.{ "read-tree", "-m", old_base_sha, review_branch, new_base_sha });

    var conflicts = try resolveConflictsToOurs(ctx, g, gpa);
    errdefer {
        for (conflicts.items) |p| gpa.free(p);
        conflicts.deinit();
    }

    const tree = try ctx.git.capture(null, &.{ "--git-dir", git_dir, "write-tree" });
    defer gpa.free(tree);

    const short_len_old = @min(@as(usize, 7), old_base_sha.len);
    const short_len_new = @min(@as(usize, 7), new_base_sha.len);
    const msg = try std.fmt.allocPrint(gpa, "cb: advance review base {s}..{s}", .{ old_base_sha[0..short_len_old], new_base_sha[0..short_len_new] });
    defer gpa.free(msg);

    const commit = try ctx.git.capture(null, &.{
        "--git-dir",   git_dir,
        "-c",          "user.name=cb",
        "-c",          "user.email=cb@localhost",
        "commit-tree", tree,
        "-p",          review_branch,
        "-p",          new_base_sha,
        "-m",          msg,
    });
    defer gpa.free(commit);

    try runMust(ctx, ctx.git, null, &.{ "--git-dir", git_dir, "update-ref", review_branch, commit });
    try runMust(ctx, ctx.git, null, &.{ "--git-dir", git_dir, "update-ref", base_ref, new_base_sha });
    try runMust(ctx, g, null, &.{ "read-tree", "HEAD" });

    const absorbed_out = try ctx.git.capture(null, &.{ "--git-dir", git_dir, "diff", "--name-only", old_review_tip, commit });
    defer gpa.free(absorbed_out);
    var absorbed: usize = 0;
    var lines = std.mem.splitScalar(u8, absorbed_out, '\n');
    while (lines.next()) |l| {
        if (l.len > 0) absorbed += 1;
    }

    return .{ .advanced = true, .old_base = old_base_sha, .new_base = new_base_sha, .absorbed = absorbed, .conflicts = conflicts };
}

pub const RefreshRemoteOpts = struct {
    project_dir: []const u8,
    git_dir: []const u8,
    work_tree: []const u8,
    branch: []const u8,
    default_branch: []const u8,
    base_arg: ?[]const u8,
    no_merge_base: bool,
    advance_base: bool,
};

pub fn refreshRemote(ctx: *app.Context, o: RefreshRemoteOpts) !AdvanceResult {
    const fetch_argv: []const []const u8 = if (o.advance_base)
        &.{ "fetch", "-q", "origin", o.branch, o.default_branch }
    else
        &.{ "fetch", "-q", "origin", o.branch };
    var fo = try ctx.git.run(o.project_dir, fetch_argv);
    fo.deinit();

    const origin_target = try std.fmt.allocPrint(ctx.gpa, "refs/remotes/origin/{s}", .{o.branch});
    defer ctx.gpa.free(origin_target);
    try fetchRef(ctx, o.git_dir, o.project_dir, origin_target, target_ref);

    var result = AdvanceResult.none(ctx.gpa);
    if (o.advance_base) {
        fetchMainline(ctx, o.git_dir, o.project_dir, o.base_arg, o.default_branch) catch {};
        const scratch = try mergeScratchDir(ctx.gpa, o.git_dir);
        defer ctx.gpa.free(scratch);
        result = try advanceBase(ctx, o.git_dir, o.no_merge_base, scratch);
    }
    errdefer result.deinit(ctx.gpa);

    // Advance the project-side worktree (the shared working tree) to the new
    // target with a plain `reset --hard` in its own frame — no --git-dir
    // override, so this uses the linked worktree's own HEAD/index, leaving the
    // review repo's HEAD/index (and therefore what still reads as "to review")
    // untouched. Anything advanceBase didn't already fold in stays reviewed-
    // stale, so amended-but-already-reviewed files resurface as unreviewed
    // without discarding progress.
    const target_sha = try ctx.git.capture(null, &.{ "--git-dir", o.git_dir, "rev-parse", target_ref });
    defer ctx.gpa.free(target_sha);
    var reset_out = try ctx.git.run(o.work_tree, &.{ "reset", "--hard", target_sha });
    defer reset_out.deinit();
    try must(ctx, &reset_out);

    return result;
}

pub const RefreshLocalOpts = struct {
    project_dir: []const u8,
    git_dir: []const u8,
    default_branch: []const u8,
    base_arg: ?[]const u8,
    advance_base: bool,
};

/// review_local has no target ref and no throwaway worktree — the work tree
/// is the user's own live directory, so this never writes to it. Advancing
/// the baseline is the only thing there is left to do here.
pub fn refreshLocal(ctx: *app.Context, o: RefreshLocalOpts) !AdvanceResult {
    if (!o.advance_base) return AdvanceResult.none(ctx.gpa);
    var fo = try ctx.git.run(o.project_dir, &.{ "fetch", "-q", "origin", o.default_branch });
    fo.deinit();
    fetchMainline(ctx, o.git_dir, o.project_dir, o.base_arg, o.default_branch) catch {};

    const scratch = try mergeScratchDir(ctx.gpa, o.git_dir);
    defer ctx.gpa.free(scratch);

    // review_local's baseline is always mainline's tip directly (no target
    // commit to take a merge-base against).
    return advanceBase(ctx, o.git_dir, true, scratch);
}
