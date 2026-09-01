const std = @import("std");
const app = @import("../app.zig");
const args = @import("../args.zig");
const store = @import("../../state/store.zig");
const common = @import("common.zig");
const model = @import("../../state/model.zig");
const engine = @import("../../review/engine.zig");
const Config = @import("../../config/config.zig").Config;

// `cb mk` creates a branch + git worktree for a project; `cb rm` tears one down;
// `cb cd`/`cd-path` resolves the directory the shell wrapper cd's into.

pub fn mk(ctx: *app.Context, rest: []const []const u8) !void {
    var a = try args.parse(ctx.gpa, rest, &.{ "no-fetch", "no-hooks" });
    defer a.deinit();

    const proj_key = a.pos(0) orelse return error.MissingArgument;
    const wt_key = a.pos(1) orelse return error.MissingArgument;

    var state = try common.loadState(ctx);
    defer state.deinit();
    const project = try common.requireProject(&state, proj_key);
    if (project.worktrees.get(wt_key) != null) return error.WorktreeExists;

    const ticket = a.value(&.{ "t", "ticket" });
    const note = a.value(&.{ "n", "note" });

    if (!a.flag(&.{"no-fetch"})) fetch(ctx, project.dir);

    const branch = try resolveBranchName(ctx, &a, wt_key, ticket);
    defer ctx.gpa.free(branch);

    const base = try resolveBase(ctx, &a, project.dir);
    defer ctx.gpa.free(base);

    const container = try common.worktreeContainer(ctx, project);
    defer ctx.gpa.free(container);
    std.fs.cwd().makePath(container) catch {};

    const raw_dir = try common.worktreeDir(ctx, container, branch);
    defer ctx.gpa.free(raw_dir);

    try addWorktree(ctx, project.dir, branch, raw_dir, base);

    // Canonicalize now that the worktree exists, so this dir compares
    // correctly against std.process.getCwdAlloc()'s resolved output in
    // state/locate.zig (e.g. macOS's /tmp -> /private/tmp).
    const dir = std.fs.cwd().realpathAlloc(ctx.gpa, raw_dir) catch try ctx.gpa.dupe(u8, raw_dir);
    defer ctx.gpa.free(dir);

    if (!a.flag(&.{"no-hooks"})) {
        const hook_ctx = Config.HookContext{
            .project_dir = project.dir,
            .worktree_dir = dir,
            .worktree_key = wt_key,
            .branch = branch,
            .base = base,
            .ticket = ticket,
        };
        try runCopyHooks(ctx, proj_key, hook_ctx);
        try runOnCreateHooks(ctx, proj_key, hook_ctx);
    }

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
    var a = try args.parse(ctx.gpa, rest, &.{ "force", "i" });
    defer a.deinit();

    var state = try common.loadState(ctx);
    defer state.deinit();

    var proj_key: []const u8 = undefined;
    var wt_key: []const u8 = undefined;
    if (a.flag(&.{"i"})) {
        proj_key = if (a.pos(0)) |p| p else (try common.pickProjectKey(ctx, &state)) orelse return error.Aborted;
        const pick_project = try common.requireProject(&state, proj_key);
        wt_key = (try common.pickWorktreeKey(ctx, pick_project, null)) orelse return error.Aborted;
    } else {
        const ref = try common.resolveRef(ctx, &state, &a);
        proj_key = ref.project;
        wt_key = ref.key;
    }

    const project = try common.requireProject(&state, proj_key);
    const wt = project.worktrees.get(wt_key) orelse return error.WorktreeNotFound;

    const force = a.flag(&.{"force"});
    if (!force) {
        // .work and .review are real git worktrees; .review_local points at
        // the user's own directory. All three are checked so `cb rm` never
        // silently eats uncommitted or unpushed work.
        try refuseIfDirty(ctx, &wt);
        const ok = try common.confirm(ctx, "remove this worktree?");
        if (!ok) return error.Aborted;
    }

    try removeWorktreeDir(ctx, project, &wt, force);
    if (wt.kind == .review or wt.kind == .review_local) {
        const git_dir = try engine.reviewDir(ctx, proj_key, wt_key);
        defer ctx.gpa.free(git_dir);
        std.fs.cwd().deleteTree(git_dir) catch {};
    }

    try store.appendEvent(ctx.gpa, ctx.state_path, store.WorktreeRemoved{
        .at = ctx.now_unix,
        .project = proj_key,
        .key = wt_key,
    });
    ctx.print("removed worktree '{s}'\n", .{wt_key});
}

/// review_local's dir is the user's own directory (never a git worktree of the
/// project) — never run `git worktree remove` against it. .work and .review
/// are both real linked worktrees of the project repo.
fn removeWorktreeDir(ctx: *app.Context, project: *const model.Project, wt: *const model.Worktree, force: bool) !void {
    if (wt.kind == .review_local) return;

    const remove_args: []const []const u8 = if (force)
        &.{ "worktree", "remove", "--force", wt.dir }
    else
        &.{ "worktree", "remove", wt.dir };
    var out = try ctx.git.run(project.dir, remove_args);
    defer out.deinit();
    // Even if the git worktree is already gone, drop it from our state so the
    // registry doesn't accumulate ghosts.
    if (!out.ok()) ctx.warn("warning: git worktree remove failed: {s}", .{out.stderr});
}

pub fn cdPath(ctx: *app.Context, rest: []const []const u8) !void {
    var a = try args.parse(ctx.gpa, rest, &.{ "no-fetch", "no-pull", "i" });
    defer a.deinit();

    var state = try common.loadState(ctx);
    defer state.deinit();

    const interactive = a.flag(&.{"i"});
    const no_fetch = a.flag(&.{"no-fetch"});

    const proj_key = if (interactive and a.pos(0) == null)
        (try common.pickProjectKey(ctx, &state)) orelse return error.Aborted
    else
        try common.resolveProjectKey(ctx, &state, &a);
    const project = try common.requireProject(&state, proj_key);

    if (interactive) {
        const wt_key = (try common.pickWorktreeKey(ctx, project, null)) orelse return error.Aborted;
        const wt = project.worktrees.get(wt_key) orelse return error.WorktreeNotFound;
        if (!no_fetch) {
            fetch(ctx, project.dir);
            reportDivergence(ctx, wt.dir);
        }
        ctx.print("{s}\n", .{wt.dir});
        return;
    }

    if (a.pos(1)) |wt_key| {
        const wt = project.worktrees.get(wt_key) orelse return error.WorktreeNotFound;
        if (!no_fetch) {
            fetch(ctx, project.dir);
            reportDivergence(ctx, wt.dir);
        }
        ctx.print("{s}\n", .{wt.dir});
        return;
    }
    if (!no_fetch) {
        fetch(ctx, project.dir);
        if (!a.flag(&.{"no-pull"})) pull(ctx, project.dir);
    }
    ctx.print("{s}\n", .{project.dir});
}

fn fetch(ctx: *app.Context, project_dir: []const u8) void {
    var out = ctx.git.run(project_dir, &.{"fetch"}) catch {
        ctx.warn("warning: git fetch failed\n", .{});
        return;
    };
    defer out.deinit();
    if (!out.ok()) ctx.warn("warning: git fetch: {s}", .{out.stderr});
}

fn pull(ctx: *app.Context, project_dir: []const u8) void {
    var out = ctx.git.run(project_dir, &.{"pull"}) catch {
        ctx.warn("warning: git pull failed\n", .{});
        return;
    };
    defer out.deinit();
    if (!out.ok()) ctx.warn("warning: git pull: {s}", .{out.stderr});
}

fn reportDivergence(ctx: *app.Context, wt_dir: []const u8) void {
    const info = (ctx.git.aheadBehind(ctx.gpa, wt_dir) catch return) orelse return;
    defer ctx.gpa.free(info.upstream);
    if (info.ahead == 0 and info.behind == 0) return;

    if (info.ahead > 0 and info.behind > 0) {
        ctx.warn("note: {d} ahead, {d} behind {s} (diverged)\n", .{ info.ahead, info.behind, info.upstream });
    } else if (info.behind > 0) {
        ctx.warn("note: {d} behind {s}\n", .{ info.behind, info.upstream });
    } else {
        ctx.warn("note: {d} ahead of {s}\n", .{ info.ahead, info.upstream });
    }
}

/// Refuse `cb rm` when the worktree has uncommitted/untracked changes or
/// commits not yet pushed upstream — printing an itemized summary of what's
/// at risk. --force bypasses this entirely (see rm()); this only runs
/// otherwise, so it's the only thing standing between a disposable worktree
/// and losing real work.
fn refuseIfDirty(ctx: *app.Context, wt: *const model.Worktree) !void {
    var status_out = ctx.git.run(wt.dir, &.{ "status", "--porcelain" }) catch return;
    defer status_out.deinit();

    var dirty_count: usize = 0;
    var shown: usize = 0;
    if (status_out.ok()) {
        var lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, status_out.stdout, "\n"), '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (dirty_count == 0) ctx.warn("cb rm: worktree has uncommitted changes:\n", .{});
            if (shown < 10) {
                ctx.warn("  {s}\n", .{line});
                shown += 1;
            }
            dirty_count += 1;
        }
    }
    if (dirty_count > shown) ctx.warn("  (+{d} more)\n", .{dirty_count - shown});

    const unpushed = unpushedCount(ctx, wt);
    if (unpushed > 0) {
        ctx.warn("cb rm: worktree has {d} commit(s) not pushed upstream\n", .{unpushed});
    }

    if (dirty_count > 0 or unpushed > 0) {
        ctx.warn("cb rm: pass --force to remove anyway\n", .{});
        return error.WorktreeDirty;
    }
}

fn unpushedCount(ctx: *app.Context, wt: *const model.Worktree) usize {
    var upstream_check = ctx.git.run(wt.dir, &.{ "rev-parse", "--verify", "--quiet", "@{u}" }) catch return 0;
    defer upstream_check.deinit();

    var out = if (upstream_check.ok())
        ctx.git.run(wt.dir, &.{ "rev-list", "--count", "@{u}..HEAD" }) catch return 0
    else blk: {
        const base = wt.base orelse return 0;
        const range = std.fmt.allocPrint(ctx.gpa, "{s}..HEAD", .{base}) catch return 0;
        defer ctx.gpa.free(range);
        break :blk ctx.git.run(wt.dir, &.{ "rev-list", "--count", range }) catch return 0;
    };
    defer out.deinit();
    if (!out.ok()) return 0;
    return std.fmt.parseInt(usize, out.line(), 10) catch 0;
}

/// Copy each `worktrees.copy` entry (e.g. `.env`) from the project checkout
/// into the freshly created worktree. A missing source is a warning, not a
/// failure — plenty of repos don't have a `.env` in every branch. Rejects any
/// rendered entry that resolves outside the worktree (`..` or an absolute
/// path) since these strings come from config, however unlikely a malicious
/// one is.
fn runCopyHooks(ctx: *app.Context, proj_key: []const u8, hook_ctx: Config.HookContext) !void {
    const entries = ctx.config.worktreesCopy(proj_key);
    for (entries) |entry_tmpl| {
        const rel = try ctx.config.renderHookEntry(ctx.gpa, entry_tmpl, hook_ctx, ctx.now_unix);
        defer ctx.gpa.free(rel);
        if (rel.len == 0) continue;

        if (std.fs.path.isAbsolute(rel) or isOutsideWorktree(rel)) {
            ctx.warn("cb mk: skipping worktrees.copy entry '{s}': must be a relative path inside the worktree\n", .{rel});
            continue;
        }

        const src = try std.fs.path.join(ctx.gpa, &.{ hook_ctx.project_dir, rel });
        defer ctx.gpa.free(src);
        const dest = try std.fs.path.join(ctx.gpa, &.{ hook_ctx.worktree_dir, rel });
        defer ctx.gpa.free(dest);

        if (std.fs.path.dirname(dest)) |parent| std.fs.cwd().makePath(parent) catch {};

        std.fs.cwd().copyFile(src, std.fs.cwd(), dest, .{}) catch |err| switch (err) {
            error.FileNotFound => ctx.warn("cb mk: worktrees.copy: '{s}' not found in the project checkout, skipped\n", .{rel}),
            else => ctx.warn("cb mk: worktrees.copy: could not copy '{s}': {s}\n", .{ rel, @errorName(err) }),
        };
    }
}

fn isOutsideWorktree(rel: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, rel, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return true;
    }
    return false;
}

/// Run each `worktrees.onCreate` command in the new worktree via `$SHELL -c`,
/// inheriting stdout/stderr so setup progress (e.g. `pnpm install`) is
/// visible. A failing command stops the remaining hooks but leaves the
/// worktree in place — it's recoverable; silently pressing on after a failed
/// install would be worse.
fn runOnCreateHooks(ctx: *app.Context, proj_key: []const u8, hook_ctx: Config.HookContext) !void {
    const entries = ctx.config.worktreesOnCreate(proj_key);
    if (entries.len == 0) return;

    const shell_path = std.process.getEnvVarOwned(ctx.gpa, "SHELL") catch try ctx.gpa.dupe(u8, "/bin/sh");
    defer ctx.gpa.free(shell_path);

    var env = try std.process.getEnvMap(ctx.gpa);
    defer env.deinit();
    try env.put("CB_PROJECT_DIR", hook_ctx.project_dir);
    try env.put("CB_PROJECT_KEY", proj_key);
    try env.put("CB_WORKTREE_DIR", hook_ctx.worktree_dir);
    try env.put("CB_WORKTREE_KEY", hook_ctx.worktree_key);
    try env.put("CB_BRANCH", hook_ctx.branch);
    try env.put("CB_BASE", hook_ctx.base);
    if (hook_ctx.ticket) |t| try env.put("CB_TICKET", t);

    for (entries) |entry_tmpl| {
        const cmd = try ctx.config.renderHookEntry(ctx.gpa, entry_tmpl, hook_ctx, ctx.now_unix);
        defer ctx.gpa.free(cmd);
        if (cmd.len == 0) continue;

        ctx.print("cb mk: running onCreate hook: {s}\n", .{cmd});
        var child = std.process.Child.init(&.{ shell_path, "-c", cmd }, ctx.gpa);
        child.cwd = hook_ctx.worktree_dir;
        child.env_map = &env;
        const term = child.spawnAndWait() catch |err| {
            ctx.warn("cb mk: onCreate hook failed to run: {s}\n", .{@errorName(err)});
            return;
        };
        const ok = switch (term) {
            .Exited => |c| c == 0,
            else => false,
        };
        if (!ok) {
            ctx.warn("cb mk: onCreate hook failed: '{s}' (worktree left in place; remaining hooks skipped)\n", .{cmd});
            return;
        }
    }
}
