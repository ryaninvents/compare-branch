const std = @import("std");

// Thin wrapper over the gh binary, mirroring git/git.zig. gh is used for one
// job only: resolving "this local checkout" to a GitHub host and owner/repo.
// It reads the git remote, honours GH_REPO / `gh repo set-default` / the
// upstream-github-origin fallback, and works against GitHub Enterprise the
// same way — all of which we would otherwise have to reimplement by parsing
// `git remote get-url`. So no --repo or --hostname is ever passed: callers run
// gh in the right cwd and let it infer both.

pub const GhError = error{
    GhNotFound,
    GhFailed,
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

    pub fn line(self: Output) []const u8 {
        return std.mem.trimRight(u8, self.stdout, "\n");
    }
};

/// Run gh in `cwd` (null = inherit) and capture output. Caller owns Output.
pub fn run(gpa: std.mem.Allocator, cwd: ?[]const u8, argv: []const []const u8) GhError!Output {
    var args = std.ArrayList([]const u8).init(gpa);
    defer args.deinit();
    args.append("gh") catch return error.OutOfMemory;
    args.appendSlice(argv) catch return error.OutOfMemory;

    const result = std.process.Child.run(.{
        .allocator = gpa,
        .argv = args.items,
        .cwd = cwd,
        .max_output_bytes = 1 * 1024 * 1024,
    }) catch |err| return switch (err) {
        error.FileNotFound => error.GhNotFound,
        error.OutOfMemory => error.OutOfMemory,
        else => error.SpawnFailed,
    };

    return .{
        .allocator = gpa,
        .stdout = result.stdout,
        .stderr = result.stderr,
        .term = result.term,
    };
}
