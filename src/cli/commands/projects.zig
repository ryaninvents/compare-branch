const std = @import("std");
const app = @import("../app.zig");
const args = @import("../args.zig");
const store = @import("../../state/store.zig");
const common = @import("common.zig");
const model = @import("../../state/model.zig");

// `cb mkproject` registers a project: it either adopts an existing checkout at
// <dir> or, given --remote, clones into <dir> (defaulting to baseDir/<key>).
// `cb ls` lists projects, or the worktrees of one project.

pub fn mkproject(ctx: *app.Context, rest: []const []const u8) !void {
    var a = try args.parse(ctx.gpa, rest, &.{});
    defer a.deinit();

    const key = a.pos(0) orelse return error.MissingArgument;
    const remote = a.value(&.{"remote"});

    var state = try common.loadState(ctx);
    defer state.deinit();
    if (state.getProject(key) != null) return error.ProjectExists;

    const raw_dir = try resolveDir(ctx, &a, key);
    defer ctx.gpa.free(raw_dir);

    try ensureCheckout(ctx, raw_dir, remote);

    // Canonicalize once the checkout exists so this dir compares correctly
    // against std.process.getCwdAlloc()'s output (which resolves symlinked
    // path components, e.g. macOS's /tmp -> /private/tmp) in state/locate.zig.
    const dir = std.fs.cwd().realpathAlloc(ctx.gpa, raw_dir) catch try ctx.gpa.dupe(u8, raw_dir);
    defer ctx.gpa.free(dir);

    try store.appendEvent(ctx.gpa, ctx.state_path, store.ProjectCreated{
        .at = ctx.now_unix,
        .key = key,
        .dir = dir,
        .category = a.value(&.{"category"}),
        .worktreesPath = a.value(&.{"worktrees"}),
        .remote = remote,
    });
    ctx.print("created project '{s}' -> {s}\n", .{ key, dir });
}

fn resolveDir(ctx: *app.Context, a: *const args.Args, key: []const u8) ![]u8 {
    if (a.pos(1)) |d| return absoluteDir(ctx.gpa, d);
    const base = try ctx.config.renderBaseDir(ctx.gpa, ctx.now_unix);
    defer ctx.gpa.free(base);
    return std.fs.path.join(ctx.gpa, &.{ base, key });
}

// Resolve d to an absolute path. Uses realpath when the path already exists so
// symlinks and ".." components are canonicalized; falls back to a cwd-join when
// it doesn't (e.g. a clone target that hasn't been created yet).
fn absoluteDir(gpa: std.mem.Allocator, d: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(d)) return gpa.dupe(u8, d);
    return std.fs.cwd().realpathAlloc(gpa, d) catch |err| switch (err) {
        error.FileNotFound => blk: {
            const cwd = try std.process.getCwdAlloc(gpa);
            defer gpa.free(cwd);
            break :blk try std.fs.path.join(gpa, &.{ cwd, d });
        },
        else => return err,
    };
}

fn ensureCheckout(ctx: *app.Context, dir: []const u8, remote: ?[]const u8) !void {
    if (ctx.git.isRepo(dir)) return; // adopt existing checkout
    const url = remote orelse return error.NotAGitRepo;

    // Clone into dir. git creates intermediate dirs for the leaf itself.
    if (std.fs.path.dirname(dir)) |parent| std.fs.cwd().makePath(parent) catch {};
    var out = try ctx.git.run(null, &.{ "clone", url, dir });
    defer out.deinit();
    if (!out.ok()) {
        ctx.warn("{s}", .{out.stderr});
        return error.GitFailed;
    }
}

pub fn rmproject(ctx: *app.Context, rest: []const []const u8) !void {
    var a = try args.parse(ctx.gpa, rest, &.{"delete-dir"});
    defer a.deinit();

    const key = a.pos(0) orelse return error.MissingArgument;
    const delete_dir = a.flag(&.{"delete-dir"});

    var state = try common.loadState(ctx);
    defer state.deinit();
    const project = try common.requireProject(&state, key);

    if (project.worktrees.count() > 0) {
        ctx.warn("project '{s}' has active worktrees; remove them first\n", .{key});
        return error.ProjectHasWorktrees;
    }

    const prompt = try std.fmt.allocPrint(ctx.gpa, "remove project '{s}'?", .{key});
    defer ctx.gpa.free(prompt);
    const confirmed = try common.confirm(ctx, prompt);
    if (!confirmed) return error.Aborted;

    const dir = try ctx.gpa.dupe(u8, project.dir);
    defer ctx.gpa.free(dir);

    try store.appendEvent(ctx.gpa, ctx.state_path, store.ProjectRemoved{
        .at = ctx.now_unix,
        .key = key,
    });

    if (delete_dir) {
        std.fs.deleteTreeAbsolute(dir) catch |err| {
            ctx.warn("warning: could not delete '{s}': {s}\n", .{ dir, @errorName(err) });
        };
        ctx.print("removed project '{s}' and deleted {s}\n", .{ key, dir });
    } else {
        ctx.print("removed project '{s}'\n", .{key});
    }
}

pub fn ls(ctx: *app.Context, rest: []const []const u8) !void {
    var a = try args.parse(ctx.gpa, rest, &.{ "json", "no-status" });
    defer a.deinit();

    var state = try common.loadState(ctx);
    defer state.deinit();

    const json = a.flag(&.{"json"});

    if (a.pos(0)) |key| {
        const project = try common.requireProject(&state, key);
        if (json) return lsWorktreesJson(ctx, key, project);
        return lsWorktrees(ctx, key, project, !a.flag(&.{"no-status"}));
    }

    if (json) return lsProjectsJson(ctx, &state);
    return lsProjects(ctx, &state);
}

fn lsWorktrees(ctx: *app.Context, key: []const u8, project: *const model.Project, with_status: bool) !void {
    if (project.worktrees.count() == 0) {
        ctx.print("(no worktrees for '{s}')\n", .{key});
        return;
    }
    var it = project.worktrees.valueIterator();
    while (it.next()) |wt| {
        const age = try formatAge(ctx.gpa, ctx.now_unix, wt.created_at);
        defer ctx.gpa.free(age);

        var status: []u8 = "";
        defer if (status.len > 0) ctx.gpa.free(status);
        if (with_status) status = try formatStatus(ctx, wt.dir);

        ctx.print("{s:<16} {s:<12} {s:<28} {s:<10} {s}\n", .{ wt.key, wt.kind.toString(), wt.branch, age, status });
        if (wt.ticket) |t| ctx.print("  ticket: {s}\n", .{t});
        if (wt.note) |n| ctx.print("  note:   {s}\n", .{n});
        if (wt.pr_title) |t| ctx.print("  PR:     {s}\n", .{t});
        if (wt.pr_author) |au| ctx.print("  author: {s}\n", .{au});
        ctx.print("  path:   {s}\n", .{wt.dir});
    }
}

fn lsProjects(ctx: *app.Context, state: *model.State) !void {
    if (state.projects.count() == 0) {
        ctx.print("(no projects — create one with `cb mkproject`)\n", .{});
        return;
    }
    var it = state.projects.valueIterator();
    while (it.next()) |p| {
        ctx.print("{s:<16} {d:<4} {s}\n", .{ p.key, p.worktrees.count(), p.dir });
    }
}

/// Dirty marker (`*`) plus ahead/behind counts (`+N`/`-N`) relative to
/// upstream. Costs one or two `git` calls per worktree, so callers gate this
/// behind `--no-status` for large listings.
fn formatStatus(ctx: *app.Context, wt_dir: []const u8) ![]u8 {
    var parts = std.ArrayList(u8).init(ctx.gpa);
    errdefer parts.deinit();

    if (ctx.git.isDirty(wt_dir)) try parts.append('*');

    if (try ctx.git.aheadBehind(ctx.gpa, wt_dir)) |info| {
        defer ctx.gpa.free(info.upstream);
        if (info.ahead > 0 or info.behind > 0) {
            if (parts.items.len > 0) try parts.append(' ');
            if (info.ahead > 0) try parts.writer().print("+{d}", .{info.ahead});
            if (info.behind > 0) {
                if (info.ahead > 0) try parts.append(' ');
                try parts.writer().print("-{d}", .{info.behind});
            }
        }
    }
    return parts.toOwnedSlice();
}

fn formatAge(gpa: std.mem.Allocator, now: i64, created_at: i64) ![]u8 {
    const delta: i64 = @max(now - created_at, 0);
    if (delta < 60) return gpa.dupe(u8, "just now");
    if (delta < 3600) return std.fmt.allocPrint(gpa, "{d}m ago", .{@divTrunc(delta, 60)});
    if (delta < 86400) return std.fmt.allocPrint(gpa, "{d}h ago", .{@divTrunc(delta, 3600)});
    return std.fmt.allocPrint(gpa, "{d}d ago", .{@divTrunc(delta, 86400)});
}

const stringify_opts = std.json.StringifyOptions{ .emit_null_optional_fields = false, .whitespace = .indent_2 };

fn lsProjectsJson(ctx: *app.Context, state: *model.State) !void {
    var out = std.ArrayList(u8).init(ctx.gpa);
    defer out.deinit();
    try out.append('[');
    var it = state.projects.valueIterator();
    var first = true;
    while (it.next()) |p| {
        if (!first) try out.append(',');
        first = false;
        try std.json.stringify(.{
            .key = p.key,
            .dir = p.dir,
            .createdAt = p.created_at,
            .category = p.category,
            .worktreesPath = p.worktrees_path,
            .remote = p.remote,
            .worktreeCount = p.worktrees.count(),
        }, stringify_opts, out.writer());
    }
    try out.append(']');
    ctx.print("{s}\n", .{out.items});
}

fn lsWorktreesJson(ctx: *app.Context, key: []const u8, project: *const model.Project) !void {
    _ = key;
    var out = std.ArrayList(u8).init(ctx.gpa);
    defer out.deinit();
    try out.append('[');
    var it = project.worktrees.valueIterator();
    var first = true;
    while (it.next()) |wt| {
        if (!first) try out.append(',');
        first = false;
        try std.json.stringify(.{
            .key = wt.key,
            .branch = wt.branch,
            .dir = wt.dir,
            .kind = wt.kind.toString(),
            .createdAt = wt.created_at,
            .ticket = wt.ticket,
            .note = wt.note,
            .base = wt.base,
            .reviewBranch = wt.review_branch,
            .targetDir = wt.target_dir,
            .lastRefreshed = wt.last_refreshed,
            .prTitle = wt.pr_title,
            .prAuthor = wt.pr_author,
            .prUrl = wt.pr_url,
        }, stringify_opts, out.writer());
    }
    try out.append(']');
    ctx.print("{s}\n", .{out.items});
}
