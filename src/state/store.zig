const std = @import("std");
const model = @import("model.zig");
const paths = @import("../util/paths.zig");

// Append-only ndjson event log. Every mutation is one JSON object per line with
// a "type" discriminator and an "at" timestamp. Current state is derived by
// folding the log in order — last writer wins, removals delete. We never
// rewrite earlier lines; compaction (if ever needed) would be a separate pass.

pub const StoreError = error{ WriteFailed, OutOfMemory } || std.fs.File.OpenError;

const stringify_opts = std.json.StringifyOptions{ .emit_null_optional_fields = false };

pub fn appendEvent(allocator: std.mem.Allocator, path: []const u8, event: anytype) !void {
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    try std.json.stringify(event, stringify_opts, buf.writer());
    try buf.append('\n');

    try paths.ensureParentDir(path);
    const file = std.fs.cwd().createFile(path, .{ .truncate = false }) catch |e| return e;
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(buf.items);
}

// --- Event payloads (also define the on-disk field names) ---

pub const ProjectCreated = struct {
    @"type": []const u8 = "project_created",
    at: i64,
    key: []const u8,
    dir: []const u8,
    category: ?[]const u8 = null,
    worktreesPath: ?[]const u8 = null,
    remote: ?[]const u8 = null,
};

pub const ProjectRemoved = struct {
    @"type": []const u8 = "project_removed",
    at: i64,
    key: []const u8,
};

pub const WorktreeCreated = struct {
    @"type": []const u8 = "worktree_created",
    at: i64,
    project: []const u8,
    key: []const u8,
    branch: []const u8,
    dir: []const u8,
    kind: []const u8,
    ticket: ?[]const u8 = null,
    note: ?[]const u8 = null,
    base: ?[]const u8 = null,
    reviewBranch: ?[]const u8 = null,
    targetDir: ?[]const u8 = null,
};

pub const WorktreeRemoved = struct {
    @"type": []const u8 = "worktree_removed",
    at: i64,
    project: []const u8,
    key: []const u8,
};

pub const ReviewRefreshed = struct {
    @"type": []const u8 = "review_refreshed",
    at: i64,
    project: []const u8,
    key: []const u8,
};

// --- Loading / folding ---

pub fn load(backing: std.mem.Allocator, path: []const u8) !model.State {
    var state = try model.State.init(backing);
    errdefer state.deinit();

    const data = std.fs.cwd().readFileAlloc(backing, path, 64 * 1024 * 1024) catch |e| switch (e) {
        error.FileNotFound => return state,
        else => return e,
    };
    defer backing.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, backing, line, .{}) catch continue;
        defer parsed.deinit();
        applyEvent(&state, parsed.value) catch continue;
    }
    return state;
}

fn applyEvent(state: *model.State, value: std.json.Value) !void {
    const obj = switch (value) {
        .object => |o| o,
        else => return,
    };
    const kind = strField(obj, "type") orelse return;
    const at = intField(obj, "at") orelse 0;
    const a = state.allocator();

    if (std.mem.eql(u8, kind, "project_created")) {
        const key = strField(obj, "key") orelse return;
        const dir = strField(obj, "dir") orelse return;
        const project = model.Project{
            .key = try a.dupe(u8, key),
            .dir = try a.dupe(u8, dir),
            .created_at = at,
            .category = try dupOpt(a, strField(obj, "category")),
            .worktrees_path = try dupOpt(a, strField(obj, "worktreesPath")),
            .remote = try dupOpt(a, strField(obj, "remote")),
            .worktrees = std.StringHashMap(model.Worktree).init(a),
        };
        try state.projects.put(try a.dupe(u8, key), project);
        return;
    }
    if (std.mem.eql(u8, kind, "project_removed")) {
        const key = strField(obj, "key") orelse return;
        _ = state.projects.remove(key);
        return;
    }
    if (std.mem.eql(u8, kind, "worktree_created")) {
        const proj_key = strField(obj, "project") orelse return;
        const project = state.getProject(proj_key) orelse return;
        const key = strField(obj, "key") orelse return;
        const wt = model.Worktree{
            .key = try a.dupe(u8, key),
            .branch = try a.dupe(u8, strField(obj, "branch") orelse ""),
            .dir = try a.dupe(u8, strField(obj, "dir") orelse ""),
            .kind = model.Kind.fromString(strField(obj, "kind") orelse "work") orelse .work,
            .created_at = at,
            .ticket = try dupOpt(a, strField(obj, "ticket")),
            .note = try dupOpt(a, strField(obj, "note")),
            .base = try dupOpt(a, strField(obj, "base")),
            .review_branch = try dupOpt(a, strField(obj, "reviewBranch")),
            .target_dir = try dupOpt(a, strField(obj, "targetDir")),
        };
        try project.worktrees.put(try a.dupe(u8, key), wt);
        return;
    }
    if (std.mem.eql(u8, kind, "worktree_removed")) {
        const proj_key = strField(obj, "project") orelse return;
        const project = state.getProject(proj_key) orelse return;
        const key = strField(obj, "key") orelse return;
        _ = project.worktrees.remove(key);
        return;
    }
    if (std.mem.eql(u8, kind, "review_refreshed")) {
        const proj_key = strField(obj, "project") orelse return;
        const project = state.getProject(proj_key) orelse return;
        const key = strField(obj, "key") orelse return;
        if (project.worktrees.getPtr(key)) |wt| wt.last_refreshed = at;
        return;
    }
}

fn strField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn intField(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |n| n,
        else => null,
    };
}

fn dupOpt(a: std.mem.Allocator, s: ?[]const u8) !?[]const u8 {
    return if (s) |v| try a.dupe(u8, v) else null;
}

test "fold create then remove" {
    const a = std.testing.allocator;
    const tmp = "test-state.ndjson";
    defer std.fs.cwd().deleteFile(tmp) catch {};
    std.fs.cwd().deleteFile(tmp) catch {};

    try appendEvent(a, tmp, ProjectCreated{ .at = 1, .key = "p", .dir = "/d" });
    try appendEvent(a, tmp, WorktreeCreated{
        .at = 2,
        .project = "p",
        .key = "w",
        .branch = "feature/x",
        .dir = "/d/w",
        .kind = "work",
        .ticket = "T-1",
    });

    var s1 = try load(a, tmp);
    defer s1.deinit();
    const p = s1.getProject("p").?;
    try std.testing.expectEqual(@as(usize, 1), p.worktrees.count());
    try std.testing.expectEqualStrings("T-1", p.worktrees.get("w").?.ticket.?);

    try appendEvent(a, tmp, WorktreeRemoved{ .at = 3, .project = "p", .key = "w" });
    var s2 = try load(a, tmp);
    defer s2.deinit();
    try std.testing.expectEqual(@as(usize, 0), s2.getProject("p").?.worktrees.count());
}
