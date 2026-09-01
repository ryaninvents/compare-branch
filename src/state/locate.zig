const std = @import("std");
const model = @import("model.zig");

// Identifies which registered project/worktree, if any, a directory sits
// inside — the foundation for every "infer from $PWD" feature (whereami, and
// optional-positional forms of rm/refresh/cd). Matching is a longest-prefix
// search over every project.dir and worktree.dir in the folded state, with a
// path-boundary check so ".../foo-bar" never matches ".../foo". Ties at the
// same depth are reported as ambiguous rather than guessed at — callers must
// fail loudly, never silently pick one.

pub const Location = union(enum) {
    worktree: struct {
        project: []const u8,
        worktree: []const u8,
    },
    project: struct {
        project: []const u8,
    },
    none,
    ambiguous,
};

/// Resolve a directory to its canonical form for comparison against stored
/// project/worktree dirs, which are themselves absolute. Falls back to the
/// input unchanged if realpath fails (e.g. the directory was deleted out from
/// under the process) — locate() then simply won't match it.
pub fn canonicalize(allocator: std.mem.Allocator, dir: []const u8) ![]u8 {
    return std.fs.cwd().realpathAlloc(allocator, dir) catch allocator.dupe(u8, dir);
}

pub fn locate(state: *model.State, cwd: []const u8) Location {
    var best_len: usize = 0;
    var best: Location = .none;
    var tie = false;

    var it = state.projects.valueIterator();
    while (it.next()) |project| {
        if (isWithin(cwd, project.dir)) {
            noteMatch(&best_len, &best, &tie, project.dir.len, .{ .project = .{ .project = project.key } });
        }
        var wit = project.worktrees.valueIterator();
        while (wit.next()) |wt| {
            if (isWithin(cwd, wt.dir)) {
                noteMatch(&best_len, &best, &tie, wt.dir.len, .{ .worktree = .{ .project = project.key, .worktree = wt.key } });
            }
        }
    }

    if (tie) return .ambiguous;
    return best;
}

fn noteMatch(best_len: *usize, best: *Location, tie: *bool, candidate_len: usize, candidate: Location) void {
    if (candidate_len > best_len.*) {
        best_len.* = candidate_len;
        best.* = candidate;
        tie.* = false;
    } else if (candidate_len == best_len.* and best_len.* > 0) {
        tie.* = true;
    }
}

/// True when `cwd` equals `dir` or is a path descendant of it.
fn isWithin(cwd: []const u8, dir: []const u8) bool {
    if (dir.len == 0) return false;
    if (std.mem.eql(u8, cwd, dir)) return true;
    if (cwd.len <= dir.len) return false;
    if (!std.mem.startsWith(u8, cwd, dir)) return false;
    return cwd[dir.len] == '/';
}

fn testState(a: std.mem.Allocator) !model.State {
    var state = try model.State.init(a);
    try state.projects.put("demo", .{
        .key = "demo",
        .dir = "/work/demo",
        .created_at = 0,
        .worktrees = std.StringHashMap(model.Worktree).init(state.allocator()),
    });
    const project = state.getProject("demo").?;
    try project.worktrees.put("feature", .{
        .key = "feature",
        .branch = "u/feature",
        .dir = "/work/demo-worktrees/feature",
        .kind = .work,
        .created_at = 0,
    });
    return state;
}

test "locate matches exact worktree dir" {
    const a = std.testing.allocator;
    var state = try testState(a);
    defer state.deinit();
    const loc = locate(&state, "/work/demo-worktrees/feature");
    try std.testing.expect(loc == .worktree);
    try std.testing.expectEqualStrings("demo", loc.worktree.project);
    try std.testing.expectEqualStrings("feature", loc.worktree.worktree);
}

test "locate matches a nested subdirectory" {
    const a = std.testing.allocator;
    var state = try testState(a);
    defer state.deinit();
    const loc = locate(&state, "/work/demo-worktrees/feature/src/nested");
    try std.testing.expect(loc == .worktree);
    try std.testing.expectEqualStrings("feature", loc.worktree.worktree);
}

test "locate does not match a sibling with a shared prefix" {
    const a = std.testing.allocator;
    var state = try testState(a);
    defer state.deinit();
    const loc = locate(&state, "/work/demo-worktrees/feature-2");
    try std.testing.expect(loc == .none);
}

test "locate prefers the longer (worktree) match over the project dir" {
    const a = std.testing.allocator;
    var state = try testState(a);
    defer state.deinit();
    const project = state.getProject("demo").?;
    try project.worktrees.put("nested-under-project", .{
        .key = "nested-under-project",
        .branch = "u/x",
        .dir = "/work/demo/sub",
        .kind = .work,
        .created_at = 0,
    });
    const loc = locate(&state, "/work/demo/sub/deep");
    try std.testing.expect(loc == .worktree);
    try std.testing.expectEqualStrings("nested-under-project", loc.worktree.worktree);
}

test "locate reports ambiguous when two dirs tie at the same depth" {
    const a = std.testing.allocator;
    var state = try testState(a);
    defer state.deinit();
    try state.projects.put("demo2", .{
        .key = "demo2",
        .dir = "/work/demo-worktrees/feature",
        .created_at = 0,
        .worktrees = std.StringHashMap(model.Worktree).init(state.allocator()),
    });
    const loc = locate(&state, "/work/demo-worktrees/feature");
    try std.testing.expect(loc == .ambiguous);
}

test "locate returns none outside any registered tree" {
    const a = std.testing.allocator;
    var state = try testState(a);
    defer state.deinit();
    const loc = locate(&state, "/tmp/somewhere-else");
    try std.testing.expect(loc == .none);
}
