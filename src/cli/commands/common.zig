const std = @import("std");
const app = @import("../app.zig");
const store = @import("../../state/store.zig");
const model = @import("../../state/model.zig");
const sanitize = @import("../../util/sanitize.zig");
const locate = @import("../../state/locate.zig");
const args = @import("../args.zig");
const picker = @import("../picker.zig");

// Helpers shared across command handlers: state access, worktree path
// computation, and an interactive confirmation prompt.

pub fn loadState(ctx: *app.Context) !model.State {
    return store.load(ctx.gpa, ctx.state_path);
}

pub fn requireProject(state: *model.State, key: []const u8) !*model.Project {
    return state.getProject(key) orelse error.ProjectNotFound;
}

/// Resolve --standalone/--no-standalone/worktrees.standalone precedence,
/// shared by `cb mk` and `cb review`: an explicit flag always wins over
/// config, in either direction; `--no-standalone` wins if both are somehow
/// given; with neither, `worktrees.standalone` decides (default false).
pub fn resolveStandalone(ctx: *app.Context, a: *const args.Args, proj_key: []const u8) bool {
    if (a.flag(&.{"no-standalone"})) return false;
    if (a.flag(&.{"standalone"})) return true;
    return ctx.config.worktreesStandalone(proj_key);
}

/// The project's real remote URL, for pointing a standalone clone's `origin`
/// at it instead of the project's local path (which is meaningless once the
/// clone is moved or mounted elsewhere). Prefers the recorded project remote;
/// falls back to querying the project checkout's own `origin` directly.
pub fn projectOriginUrl(ctx: *app.Context, project: *const model.Project) !?[]u8 {
    if (project.remote) |r| return try ctx.gpa.dupe(u8, r);
    var out = ctx.git.run(project.dir, &.{ "remote", "get-url", "origin" }) catch return null;
    defer out.deinit();
    if (!out.ok()) return null;
    return try ctx.gpa.dupe(u8, out.line());
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

/// Interactively choose a registered project key, sorted alphabetically.
pub fn pickProjectKey(ctx: *app.Context, state: *model.State) !?[]const u8 {
    var keys = std.ArrayList([]const u8).init(ctx.gpa);
    defer keys.deinit();
    var it = state.projects.keyIterator();
    while (it.next()) |k| try keys.append(k.*);
    std.mem.sort([]const u8, keys.items, {}, lessThanStr);

    const idx = try picker.pick(ctx, keys.items, "project") orelse return null;
    return keys.items[idx];
}

/// Interactively choose a worktree key within `project`, freshest first.
/// `filter`, when given, restricts candidates to worktrees whose kind it
/// accepts (e.g. review-only pickers for `cb review-shell -i`).
pub fn pickWorktreeKey(
    ctx: *app.Context,
    project: *const model.Project,
    filter: ?*const fn (model.Kind) bool,
) !?[]const u8 {
    const Entry = struct { key: []const u8, created_at: i64 };
    var entries = std.ArrayList(Entry).init(ctx.gpa);
    defer entries.deinit();
    var it = project.worktrees.valueIterator();
    while (it.next()) |wt| {
        if (filter) |f| {
            if (!f(wt.kind)) continue;
        }
        try entries.append(.{ .key = wt.key, .created_at = wt.created_at });
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lessThan(_: void, a_: Entry, b_: Entry) bool {
            return a_.created_at > b_.created_at;
        }
    }.lessThan);

    var keys = std.ArrayList([]const u8).init(ctx.gpa);
    defer keys.deinit();
    for (entries.items) |e| try keys.append(e.key);

    const idx = try picker.pick(ctx, keys.items, "worktree") orelse return null;
    return keys.items[idx];
}

fn lessThanStr(_: void, a_: []const u8, b_: []const u8) bool {
    return std.mem.lessThan(u8, a_, b_);
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
