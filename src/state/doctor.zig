const std = @import("std");

// Pure reconciliation logic for `cb doctor`: cross-references what the
// append-only state log claims exists against what `git worktree list` and
// the filesystem actually report. No I/O here — callers gather the inputs
// (disk existence, `git worktree list --porcelain` output) so this stays
// testable without a repo.

pub const Entry = struct {
    key: []const u8,
    dir: []const u8,
    /// True for kind == .work or .review: both are real linked `git worktree`
    /// checkouts of the project repo, reconciled against `git worktree list`.
    /// False for review_local, which points at the user's own directory —
    /// only checked for existence on disk.
    is_git_worktree: bool,
    exists_on_disk: bool,
};

pub const GitWorktreeDir = struct {
    dir: []const u8,
    branch: ?[]const u8,
};

pub const Finding = union(enum) {
    /// A state entry whose worktree is gone (from git's list, or from disk
    /// for review kinds).
    ghost: struct { key: []const u8, dir: []const u8 },
    /// A real git worktree under the project that state doesn't know about.
    orphan: struct { dir: []const u8, branch: ?[]const u8 },
};

/// `entries` should exclude the project's own main checkout — only worktrees
/// tracked as model.Worktree records. `git_worktrees` should exclude the main
/// checkout's own entry (git worktree list always lists it first).
pub fn reconcile(
    gpa: std.mem.Allocator,
    entries: []const Entry,
    git_worktrees: []const GitWorktreeDir,
) ![]Finding {
    var findings = std.ArrayList(Finding).init(gpa);
    errdefer findings.deinit();

    var claimed = try gpa.alloc(bool, git_worktrees.len);
    defer gpa.free(claimed);
    @memset(claimed, false);

    for (entries) |e| {
        if (e.is_git_worktree) {
            var found = false;
            for (git_worktrees, 0..) |gw, i| {
                if (std.mem.eql(u8, gw.dir, e.dir)) {
                    claimed[i] = true;
                    found = true;
                    break;
                }
            }
            if (!found) try findings.append(.{ .ghost = .{ .key = e.key, .dir = e.dir } });
        } else if (!e.exists_on_disk) {
            try findings.append(.{ .ghost = .{ .key = e.key, .dir = e.dir } });
        }
    }

    for (git_worktrees, 0..) |gw, i| {
        if (!claimed[i]) try findings.append(.{ .orphan = .{ .dir = gw.dir, .branch = gw.branch } });
    }

    return findings.toOwnedSlice();
}

test "reconcile: matched work entry produces no finding" {
    const a = std.testing.allocator;
    const entries = [_]Entry{.{ .key = "w", .dir = "/wt/a", .is_git_worktree = true, .exists_on_disk = true }};
    const git = [_]GitWorktreeDir{.{ .dir = "/wt/a", .branch = "feature" }};
    const findings = try reconcile(a, &entries, &git);
    defer a.free(findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "reconcile: work entry missing from git worktree list is a ghost" {
    const a = std.testing.allocator;
    const entries = [_]Entry{.{ .key = "w", .dir = "/wt/a", .is_git_worktree = true, .exists_on_disk = false }};
    const findings = try reconcile(a, &entries, &.{});
    defer a.free(findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(findings[0] == .ghost);
    try std.testing.expectEqualStrings("w", findings[0].ghost.key);
}

test "reconcile: git worktree with no matching state entry is an orphan" {
    const a = std.testing.allocator;
    const git = [_]GitWorktreeDir{.{ .dir = "/wt/b", .branch = "other" }};
    const findings = try reconcile(a, &.{}, &git);
    defer a.free(findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(findings[0] == .orphan);
    try std.testing.expectEqualStrings("/wt/b", findings[0].orphan.dir);
}

test "reconcile: review_local entry missing on disk is a ghost, never compared to git" {
    const a = std.testing.allocator;
    const entries = [_]Entry{.{ .key = "r", .dir = "/wt/r", .is_git_worktree = false, .exists_on_disk = false }};
    const findings = try reconcile(a, &entries, &.{});
    defer a.free(findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(findings[0] == .ghost);
}

test "reconcile: review_local entry present on disk produces no finding" {
    const a = std.testing.allocator;
    const entries = [_]Entry{.{ .key = "r", .dir = "/wt/r", .is_git_worktree = false, .exists_on_disk = true }};
    const findings = try reconcile(a, &entries, &.{});
    defer a.free(findings);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}
