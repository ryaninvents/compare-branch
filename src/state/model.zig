const std = @import("std");

// The folded, in-memory view of the world. Persistence is an append-only
// ndjson event log (see store.zig); this module defines the entities that log
// folds down to. All strings are owned by the arena so the whole State frees in
// one shot.

pub const Kind = enum {
    work,
    review,
    review_local,

    pub fn fromString(s: []const u8) ?Kind {
        if (std.mem.eql(u8, s, "work")) return .work;
        if (std.mem.eql(u8, s, "review")) return .review;
        if (std.mem.eql(u8, s, "review_local")) return .review_local;
        return null;
    }

    pub fn toString(self: Kind) []const u8 {
        return switch (self) {
            .work => "work",
            .review => "review",
            .review_local => "review_local",
        };
    }
};

pub const Worktree = struct {
    key: []const u8,
    branch: []const u8,
    dir: []const u8,
    kind: Kind,
    created_at: i64,
    ticket: ?[]const u8 = null,
    note: ?[]const u8 = null,
    base: ?[]const u8 = null,
    /// For review worktrees: the remote branch under review.
    review_branch: ?[]const u8 = null,
    /// For review_local worktrees: the working directory being snapshotted.
    target_dir: ?[]const u8 = null,
    last_refreshed: ?i64 = null,
};

pub const Project = struct {
    key: []const u8,
    dir: []const u8,
    created_at: i64,
    category: ?[]const u8 = null,
    worktrees_path: ?[]const u8 = null,
    remote: ?[]const u8 = null,
    worktrees: std.StringHashMap(Worktree),
};

pub const State = struct {
    backing: std.mem.Allocator,
    // Heap-allocated so its address is stable: the projects map stores an
    // Allocator pointing at it, and State is returned by value from init/load.
    arena: *std.heap.ArenaAllocator,
    projects: std.StringHashMap(Project),

    pub fn init(backing: std.mem.Allocator) !State {
        const arena = try backing.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(backing);
        return .{
            .backing = backing,
            .arena = arena,
            .projects = std.StringHashMap(Project).init(arena.allocator()),
        };
    }

    pub fn deinit(self: *State) void {
        self.arena.deinit();
        self.backing.destroy(self.arena);
    }

    pub fn allocator(self: *State) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn getProject(self: *State, key: []const u8) ?*Project {
        return self.projects.getPtr(key);
    }
};
