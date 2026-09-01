const std = @import("std");
const app = @import("../app.zig");
const args = @import("../args.zig");
const common = @import("common.zig");
const store = @import("../../state/store.zig");
const model = @import("../../state/model.zig");
const locate = @import("../../state/locate.zig");
const reconcile_mod = @import("../../state/doctor.zig");

// `cb doctor` cross-references the append-only state log against `git
// worktree list` and the filesystem, since the log is the only source of
// truth and can drift (a manual `git worktree remove`, a deleted directory, a
// worktree created outside cb). Read-only by default; --fix appends
// corrective events (never rewrites history, consistent with the store).

pub fn doctor(ctx: *app.Context, rest: []const []const u8) !void {
    var a = try args.parse(ctx.gpa, rest, &.{"fix"});
    defer a.deinit();
    const fix = a.flag(&.{"fix"});

    var state = try common.loadState(ctx);
    defer state.deinit();

    var total: usize = 0;
    if (a.pos(0)) |key| {
        const project = try common.requireProject(&state, key);
        total += try checkProject(ctx, key, project, fix);
    } else {
        var it = state.projects.iterator();
        while (it.next()) |entry| {
            total += try checkProject(ctx, entry.key_ptr.*, entry.value_ptr, fix);
        }
    }

    if (total == 0) {
        ctx.print("cb doctor: no issues found\n", .{});
    } else if (!fix) {
        ctx.print("cb doctor: {d} issue(s) found (pass --fix to reconcile)\n", .{total});
    } else {
        ctx.print("cb doctor: {d} issue(s) fixed\n", .{total});
    }
}

fn checkProject(ctx: *app.Context, key: []const u8, project: *model.Project, fix: bool) !usize {
    if (!ctx.git.isRepo(project.dir)) {
        ctx.print("project '{s}': directory missing or not a git repo ({s})\n", .{ key, project.dir });
        return 1;
    }

    const git_worktrees = try listGitWorktrees(ctx, project.dir);
    defer ctx.gpa.free(git_worktrees);

    var entries = std.ArrayList(reconcile_mod.Entry).init(ctx.gpa);
    defer entries.deinit();
    var wit = project.worktrees.iterator();
    while (wit.next()) |e| {
        const wt = e.value_ptr;
        try entries.append(.{
            .key = wt.key,
            .dir = wt.dir,
            .is_git_worktree = wt.kind == .work or wt.kind == .review,
            .exists_on_disk = dirExists(wt.dir),
        });
    }

    const findings = try reconcile_mod.reconcile(ctx.gpa, entries.items, git_worktrees);
    defer ctx.gpa.free(findings);

    for (findings) |f| try reportAndFix(ctx, key, project, f, fix);
    return findings.len;
}

fn reportAndFix(ctx: *app.Context, key: []const u8, project: *model.Project, finding: reconcile_mod.Finding, fix: bool) !void {
    switch (finding) {
        .ghost => |g| {
            ctx.print("project '{s}': ghost worktree '{s}' ({s}) — recorded but missing\n", .{ key, g.key, g.dir });
            if (!fix) return;
            try store.appendEvent(ctx.gpa, ctx.state_path, store.WorktreeRemoved{
                .at = ctx.now_unix,
                .project = key,
                .key = g.key,
            });
        },
        .orphan => |o| {
            ctx.print("project '{s}': orphan worktree at {s} (branch: {s}) — not recorded\n", .{ key, o.dir, o.branch orelse "(detached)" });
            if (!fix) return;
            const wt_key = std.fs.path.basename(o.dir);
            if (project.worktrees.get(wt_key) != null) {
                ctx.warn("  warning: adopted key '{s}' collides with an existing worktree; skipped\n", .{wt_key});
                return;
            }
            try store.appendEvent(ctx.gpa, ctx.state_path, store.WorktreeCreated{
                .at = ctx.now_unix,
                .project = key,
                .key = wt_key,
                .branch = o.branch orelse "HEAD",
                .dir = o.dir,
                .kind = "work",
            });
        },
    }
}

fn dirExists(dir: []const u8) bool {
    var d = std.fs.cwd().openDir(dir, .{}) catch return false;
    d.close();
    return true;
}

/// Parse `git worktree list --porcelain`, excluding the first entry (always
/// the project's own main checkout — not a model.Worktree record).
fn listGitWorktrees(ctx: *app.Context, project_dir: []const u8) ![]reconcile_mod.GitWorktreeDir {
    var out = ctx.git.run(project_dir, &.{ "worktree", "list", "--porcelain" }) catch {
        return &.{};
    };
    defer out.deinit();
    if (!out.ok()) return &.{};

    var list = std.ArrayList(reconcile_mod.GitWorktreeDir).init(ctx.gpa);
    errdefer list.deinit();

    var seen_main = false;
    var current_dir: ?[]const u8 = null;
    var current_branch: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, out.stdout, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, "\r");
        if (line.len == 0) {
            try flushEntry(&list, &seen_main, &current_dir, &current_branch);
            continue;
        }
        if (std.mem.startsWith(u8, line, "worktree ")) {
            current_dir = try locate.canonicalize(ctx.gpa, line["worktree ".len..]);
        } else if (std.mem.startsWith(u8, line, "branch ")) {
            const full = line["branch ".len..];
            const short = if (std.mem.lastIndexOfScalar(u8, full, '/')) |s| full[s + 1 ..] else full;
            current_branch = try ctx.gpa.dupe(u8, short);
        }
    }
    try flushEntry(&list, &seen_main, &current_dir, &current_branch);

    return list.toOwnedSlice();
}

fn flushEntry(
    list: *std.ArrayList(reconcile_mod.GitWorktreeDir),
    seen_main: *bool,
    current_dir: *?[]const u8,
    current_branch: *?[]const u8,
) !void {
    defer current_dir.* = null;
    defer current_branch.* = null;
    const dir = current_dir.* orelse return;

    if (!seen_main.*) {
        seen_main.* = true; // first entry is always the main checkout
        return;
    }
    try list.append(.{ .dir = dir, .branch = current_branch.* });
}
