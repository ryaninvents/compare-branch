const std = @import("std");

// Thin wrapper over the system git binary. We shell out rather than link
// libgit2: it keeps the build dependency-free and mirrors the rapid-review
// approach the spec references. All worktree, merge-base, fetch and clone
// operations route through here.

pub const GitError = error{
    GitFailed,
    GitNotFound,
    OutOfMemory,
    SpawnFailed,
};

pub const Output = struct {
    allocator: std.mem.Allocator,
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,

    pub fn deinit(self: *Output) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }

    pub fn ok(self: Output) bool {
        return switch (self.term) {
            .Exited => |c| c == 0,
            else => false,
        };
    }

    /// stdout with a single trailing newline trimmed — convenient for
    /// single-line results like rev-parse / merge-base.
    pub fn line(self: Output) []const u8 {
        return std.mem.trimRight(u8, self.stdout, "\n");
    }
};

pub const Git = struct {
    allocator: std.mem.Allocator,
    /// Optional --git-dir / --work-tree override for the isolated review index.
    git_dir: ?[]const u8 = null,
    work_tree: ?[]const u8 = null,

    /// Run git in `cwd` (null = inherit) and capture output. Caller owns Output.
    pub fn run(self: Git, cwd: ?[]const u8, argv: []const []const u8) GitError!Output {
        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();
        args.append("git") catch return error.OutOfMemory;
        if (self.git_dir) |d| {
            args.append("--git-dir") catch return error.OutOfMemory;
            args.append(d) catch return error.OutOfMemory;
        }
        if (self.work_tree) |w| {
            args.append("--work-tree") catch return error.OutOfMemory;
            args.append(w) catch return error.OutOfMemory;
        }
        args.appendSlice(argv) catch return error.OutOfMemory;

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = args.items,
            .cwd = cwd,
            .max_output_bytes = 16 * 1024 * 1024,
        }) catch |e| return switch (e) {
            error.FileNotFound => error.GitNotFound,
            error.OutOfMemory => error.OutOfMemory,
            else => error.SpawnFailed,
        };

        return .{
            .allocator = self.allocator,
            .stdout = result.stdout,
            .stderr = result.stderr,
            .term = result.term,
        };
    }

    /// Run git and require success, returning trimmed stdout (caller frees).
    pub fn capture(self: Git, cwd: ?[]const u8, argv: []const []const u8) GitError![]u8 {
        var out = try self.run(cwd, argv);
        defer out.deinit();
        if (!out.ok()) return error.GitFailed;
        return self.allocator.dupe(u8, out.line()) catch error.OutOfMemory;
    }

    pub fn isRepo(self: Git, dir: []const u8) bool {
        var out = self.run(dir, &.{ "rev-parse", "--is-inside-work-tree" }) catch return false;
        defer out.deinit();
        return out.ok();
    }

    pub fn defaultBranch(self: Git, dir: []const u8) GitError![]u8 {
        // Prefer the remote HEAD symref; fall back to the current branch.
        var out = self.run(dir, &.{ "symbolic-ref", "--short", "refs/remotes/origin/HEAD" }) catch
            return self.capture(dir, &.{ "rev-parse", "--abbrev-ref", "HEAD" });
        defer out.deinit();
        if (out.ok()) {
            const full = out.line();
            // Strip the "origin/" prefix to get the bare branch name.
            const slash = std.mem.lastIndexOfScalar(u8, full, '/');
            const name = if (slash) |s| full[s + 1 ..] else full;
            return self.allocator.dupe(u8, name) catch error.OutOfMemory;
        }
        return self.capture(dir, &.{ "rev-parse", "--abbrev-ref", "HEAD" });
    }

    pub fn mergeBase(self: Git, dir: []const u8, a: []const u8, b: []const u8) GitError![]u8 {
        return self.capture(dir, &.{ "merge-base", a, b });
    }
};
