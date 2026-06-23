const std = @import("std");
const app = @import("../app.zig");
const args = @import("../args.zig");
const store = @import("../../state/store.zig");
const common = @import("common.zig");

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

    const dir = try resolveDir(ctx, &a, key);
    defer ctx.gpa.free(dir);

    try ensureCheckout(ctx, dir, remote);

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
    var a = try args.parse(ctx.gpa, rest, &.{});
    defer a.deinit();

    var state = try common.loadState(ctx);
    defer state.deinit();

    if (a.pos(0)) |key| {
        const project = try common.requireProject(&state, key);
        if (project.worktrees.count() == 0) {
            ctx.print("(no worktrees for '{s}')\n", .{key});
            return;
        }
        var it = project.worktrees.valueIterator();
        while (it.next()) |wt| {
            ctx.print("{s:<20} {s:<14} {s}\n", .{ wt.key, wt.kind.toString(), wt.dir });
            if (wt.ticket) |t| ctx.print("  ticket: {s}\n", .{t});
            if (wt.note) |n| ctx.print("  note:   {s}\n", .{n});
        }
        return;
    }

    if (state.projects.count() == 0) {
        ctx.print("(no projects — create one with `cb mkproject`)\n", .{});
        return;
    }
    var it = state.projects.valueIterator();
    while (it.next()) |p| {
        ctx.print("{s:<16} {s}\n", .{ p.key, p.dir });
    }
}
