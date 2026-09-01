const std = @import("std");
const app = @import("../app.zig");
const common = @import("common.zig");
const locate = @import("../../state/locate.zig");

// `cb whereami` identifies which registered project/worktree (if any) the
// current directory sits inside, using the longest-prefix search in
// state/locate.zig. It never mutates state.

pub fn whereami(ctx: *app.Context, rest: []const []const u8) !void {
    _ = rest;

    var state = try common.loadState(ctx);
    defer state.deinit();

    const raw_cwd = std.process.getCwdAlloc(ctx.gpa) catch return error.NoHome;
    defer ctx.gpa.free(raw_cwd);
    const cwd = try locate.canonicalize(ctx.gpa, raw_cwd);
    defer ctx.gpa.free(cwd);

    const loc = locate.locate(&state, cwd);
    switch (loc) {
        .worktree => |w| {
            const project = state.getProject(w.project).?;
            const wt = project.worktrees.get(w.worktree).?;
            const branch = ctx.git.capture(wt.dir, &.{ "symbolic-ref", "--short", "HEAD" }) catch
                (ctx.git.capture(wt.dir, &.{ "rev-parse", "--short", "HEAD" }) catch null);
            defer if (branch) |b| ctx.gpa.free(b);

            ctx.print("project:  {s}\n", .{w.project});
            ctx.print("worktree: {s}\n", .{w.worktree});
            ctx.print("kind:     {s}\n", .{wt.kind.toString()});
            ctx.print("branch:   {s}\n", .{branch orelse "(unknown)"});
            ctx.print("path:     {s}\n", .{wt.dir});
            ctx.print("base:     {s}\n", .{wt.base orelse "(unknown)"});
            if (wt.ticket) |t| ctx.print("ticket:   {s}\n", .{t});
            if (wt.note) |n| ctx.print("note:     {s}\n", .{n});
        },
        .project => |p| {
            const project = state.getProject(p.project).?;
            ctx.print("project:  {s}\n", .{p.project});
            ctx.print("path:     {s}\n", .{project.dir});
            ctx.print("(main checkout — not a worktree)\n", .{});
        },
        .none => return error.NotInWorktree,
        .ambiguous => return error.AmbiguousContext,
    }
}
