const std = @import("std");
const template = @import("template.zig");

// Loads ~/.config/cb/config.json and exposes the three templates cb needs
// (workDir, projects.baseDir, branches.name), each backed by a built-in default
// when the user hasn't overridden it. The config is user-authored and never
// rewritten by cb — mutable state lives in the event log instead.

const default_doc =
    \\{
    \\  "workDir": [{"var": "HOME"}, "/work"],
    \\  "projects": { "baseDir": [{"var": "workDir"}, "/.base"] },
    \\  "branches": {
    \\    "name": [{"var": "USER"}, "/", {"date": "YYYYMMDD.HHmmss"}, "/", {"join": {"delimiter": "--", "elements": [{"var": "ticket"}, {"var": "worktree-key"}]}}]
    \\  }
    \\}
;

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    user: std.json.Parsed(std.json.Value),
    defaults: std.json.Parsed(std.json.Value),
    /// Named global templates available to `{"var": ...}` (currently workDir).
    vars: std.json.ObjectMap,

    pub fn deinit(self: *Config) void {
        self.vars.deinit();
        self.user.deinit();
        self.defaults.deinit();
        self.arena.deinit();
    }

    pub fn workDirTemplate(self: *Config) std.json.Value {
        return self.lookup(&.{"workDir"});
    }

    pub fn baseDirTemplate(self: *Config) std.json.Value {
        return self.lookup(&.{ "projects", "baseDir" });
    }

    pub fn branchNameTemplate(self: *Config) std.json.Value {
        return self.lookup(&.{ "branches", "name" });
    }

    /// Walk a key path in the user doc, falling back to the defaults doc.
    fn lookup(self: *Config, path: []const []const u8) std.json.Value {
        return navigate(self.user.value, path) orelse
            (navigate(self.defaults.value, path) orelse .null);
    }

    fn buildScope(
        self: *Config,
        ctx: *const std.StringHashMap([]const u8),
        resolving: *std.ArrayList([]const u8),
        now_unix: i64,
    ) template.Scope {
        return .{
            .allocator = self.arena.allocator(),
            .vars = &self.vars,
            .context = ctx,
            .now_unix = now_unix,
            .resolving = resolving,
        };
    }

    pub fn renderWorkDir(self: *Config, allocator: std.mem.Allocator, now_unix: i64) ![]u8 {
        return self.renderWith(allocator, self.workDirTemplate(), null, null, now_unix);
    }

    pub fn renderBaseDir(self: *Config, allocator: std.mem.Allocator, now_unix: i64) ![]u8 {
        return self.renderWith(allocator, self.baseDirTemplate(), null, null, now_unix);
    }

    pub fn renderBranchName(
        self: *Config,
        allocator: std.mem.Allocator,
        worktree_key: []const u8,
        ticket: ?[]const u8,
        now_unix: i64,
    ) ![]u8 {
        return self.renderWith(allocator, self.branchNameTemplate(), worktree_key, ticket, now_unix);
    }

    fn renderWith(
        self: *Config,
        allocator: std.mem.Allocator,
        tmpl: std.json.Value,
        worktree_key: ?[]const u8,
        ticket: ?[]const u8,
        now_unix: i64,
    ) ![]u8 {
        var ctx = std.StringHashMap([]const u8).init(allocator);
        defer ctx.deinit();
        if (worktree_key) |k| try ctx.put("worktree-key", k);
        if (ticket) |t| try ctx.put("ticket", t);

        var resolving = std.ArrayList([]const u8).init(allocator);
        defer resolving.deinit();

        const scope = self.buildScope(&ctx, &resolving, now_unix);
        const rendered = try template.render(scope, tmpl);
        // Re-own the result on the caller's allocator; scope used the arena.
        defer self.arena.allocator().free(rendered);
        return allocator.dupe(u8, rendered);
    }

    pub const HookContext = struct {
        project_dir: []const u8,
        worktree_dir: []const u8,
        worktree_key: []const u8,
        branch: []const u8,
        base: []const u8,
        ticket: ?[]const u8 = null,
    };

    /// Render one `worktrees.copy`/`worktrees.onCreate` template-DSL entry
    /// with the post-creation hook context (projectDir, worktreeDir, and the
    /// usual ticket/worktree-key) in scope.
    pub fn renderHookEntry(
        self: *Config,
        allocator: std.mem.Allocator,
        tmpl: std.json.Value,
        hook_ctx: HookContext,
        now_unix: i64,
    ) ![]u8 {
        var ctx = std.StringHashMap([]const u8).init(allocator);
        defer ctx.deinit();
        try ctx.put("projectDir", hook_ctx.project_dir);
        try ctx.put("worktreeDir", hook_ctx.worktree_dir);
        try ctx.put("worktree-key", hook_ctx.worktree_key);
        try ctx.put("branch", hook_ctx.branch);
        try ctx.put("base", hook_ctx.base);
        if (hook_ctx.ticket) |t| try ctx.put("ticket", t);

        var resolving = std.ArrayList([]const u8).init(allocator);
        defer resolving.deinit();

        const scope = self.buildScope(&ctx, &resolving, now_unix);
        const rendered = try template.render(scope, tmpl);
        defer self.arena.allocator().free(rendered);
        return allocator.dupe(u8, rendered);
    }

    /// `worktrees.copy` entries: project override (`projects.overrides.<key>.
    /// worktrees.copy`) wins over the global `worktrees.copy`; no built-in
    /// default (an empty list — copying nothing is the safe default).
    pub fn worktreesCopy(self: *Config, project_key: []const u8) []std.json.Value {
        return asList(self.worktreesField(project_key, "copy"));
    }

    /// `worktrees.onCreate` entries, same lookup order as worktreesCopy.
    pub fn worktreesOnCreate(self: *Config, project_key: []const u8) []std.json.Value {
        return asList(self.worktreesField(project_key, "onCreate"));
    }

    fn worktreesField(self: *Config, project_key: []const u8, field: []const u8) std.json.Value {
        if (navigate(self.user.value, &.{ "projects", "overrides", project_key, "worktrees", field })) |v| return v;
        if (navigate(self.user.value, &.{ "worktrees", field })) |v| return v;
        return .null;
    }
};

fn asList(v: std.json.Value) []std.json.Value {
    return switch (v) {
        .array => |a| a.items,
        else => &.{},
    };
}

fn navigate(root: std.json.Value, path: []const []const u8) ?std.json.Value {
    var cur = root;
    for (path) |seg| {
        switch (cur) {
            .object => |o| cur = o.get(seg) orelse return null,
            else => return null,
        }
    }
    return cur;
}

pub fn load(backing: std.mem.Allocator, path: []const u8) !Config {
    var arena = std.heap.ArenaAllocator.init(backing);
    const a = arena.allocator();

    const user_text = std.fs.cwd().readFileAlloc(a, path, 4 * 1024 * 1024) catch |e| switch (e) {
        error.FileNotFound => try a.dupe(u8, "{}"),
        else => return e,
    };

    const user = try std.json.parseFromSlice(std.json.Value, backing, user_text, .{});
    errdefer user.deinit();
    const defaults = try std.json.parseFromSlice(std.json.Value, backing, default_doc, .{});
    errdefer defaults.deinit();

    var vars = std.json.ObjectMap.init(backing);
    errdefer vars.deinit();

    var cfg = Config{
        .arena = arena,
        .user = user,
        .defaults = defaults,
        .vars = vars,
    };
    // workDir is the one config-defined template other templates reference.
    try cfg.vars.put("workDir", cfg.workDirTemplate());
    return cfg;
}
