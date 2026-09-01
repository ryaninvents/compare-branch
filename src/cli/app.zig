const std = @import("std");
const Config = @import("../config/config.zig").Config;
const git = @import("../git/git.zig");
const build_options = @import("build_options");

const projects = @import("commands/projects.zig");
const worktree = @import("commands/worktree.zig");
const review = @import("commands/review.zig");
const shell = @import("commands/shell.zig");
const config_cmd = @import("commands/config_cmd.zig");
const complete_cmd = @import("commands/complete.zig");
const context_cmd = @import("commands/context.zig");
const doctor_cmd = @import("commands/doctor.zig");
const permalink_cmd = @import("commands/permalink.zig");

// Wiring point: holds the resolved dependencies every command needs and routes
// argv[1] to a handler. Composition (constructing Config/Git/paths) happens in
// main.zig; this layer is pure dispatch.

pub const Context = struct {
    gpa: std.mem.Allocator,
    config: *Config,
    git: git.Git,
    state_path: []const u8,
    now_unix: i64,
    stdout: std.fs.File.Writer,
    stderr: std.fs.File.Writer,

    pub fn print(self: Context, comptime fmt: []const u8, args: anytype) void {
        self.stdout.print(fmt, args) catch {};
    }

    pub fn warn(self: Context, comptime fmt: []const u8, args: anytype) void {
        self.stderr.print(fmt, args) catch {};
    }
};

pub const usage =
    \\cb — disposable git worktree manager
    \\
    \\Usage:
    \\  cb --version | -v
    \\  cb --help | -h
    \\  cb mkproject <key> [<dir>] [--remote <url>] [--category <cat>] [--worktrees <path>]
    \\  cb mk <key> <worktree-key> [-t <ticket>] [--base <branch>] [--branch-name <name>] [-n <note>] [--no-cd] [--no-fetch] [--no-hooks]
    \\  cb cd [<key> [<worktree-key>]] [-i] [--no-fetch] [--no-pull]
    \\  cb ls [<key>] [--json] [--no-status]
    \\  cb rmproject <key> [--delete-dir]
    \\  cb rm [<key> <worktree-key>] [-i] [--force]
    \\  cb review <key> <remote-branch | PR number | PR URL> [-t <ticket>] [-n <note>] [--base <branch>] [--no-merge-base] [--shell]
    \\  cb review-local <key> <dir>
    \\  cb refresh [<key> <worktree-key>]
    \\  cb review-shell [<key> <worktree-key>] [-i]
    \\  cb whereami
    \\  cb get-permalink <path>[:<line>[-<line>]] [--json]
    \\  cb doctor [<key>] [--fix]
    \\  cb init <zsh|bash>
    \\  cb config [path]
    \\
;

pub fn run(ctx: *Context, argv: []const []const u8) !u8 {
    if (argv.len < 1 or isHelp(argv[0])) {
        ctx.print("{s}", .{usage});
        return 0;
    }
    if (isVersion(argv[0])) {
        ctx.print("cb {s}\n", .{build_options.version});
        return 0;
    }
    const cmd = argv[0];
    const rest = argv[1..];

    dispatch(ctx, cmd, rest) catch |err| {
        ctx.warn("cb: {s}\n", .{errorMessage(err)});
        return 1;
    };
    return 0;
}

fn dispatch(ctx: *Context, cmd: []const u8, rest: []const []const u8) !void {
    if (eq(cmd, "mkproject")) return projects.mkproject(ctx, rest);
    if (eq(cmd, "rmproject")) return projects.rmproject(ctx, rest);
    if (eq(cmd, "ls")) return projects.ls(ctx, rest);
    if (eq(cmd, "mk")) return worktree.mk(ctx, rest);
    if (eq(cmd, "rm")) return worktree.rm(ctx, rest);
    if (eq(cmd, "cd") or eq(cmd, "cd-path")) return worktree.cdPath(ctx, rest);
    if (eq(cmd, "review")) return review.review(ctx, rest);
    if (eq(cmd, "review-local")) return review.reviewLocal(ctx, rest);
    if (eq(cmd, "refresh")) return review.refresh(ctx, rest);
    if (eq(cmd, "review-shell")) return review.reviewShell(ctx, rest);
    if (eq(cmd, "review-done")) return review.reviewDone(ctx, rest);
    if (eq(cmd, "review-confirm-exit")) return review.confirmExit(ctx, rest);
    if (eq(cmd, "whereami")) return context_cmd.whereami(ctx, rest);
    if (eq(cmd, "get-permalink")) return permalink_cmd.getPermalink(ctx, rest);
    if (eq(cmd, "doctor")) return doctor_cmd.doctor(ctx, rest);
    if (eq(cmd, "init")) return shell.init(ctx, rest);
    if (eq(cmd, "__complete")) return complete_cmd.complete(ctx, rest);
    if (eq(cmd, "config")) return config_cmd.config(ctx, rest);
    ctx.warn("{s}", .{usage});
    return error.UnknownCommand;
}

fn isHelp(s: []const u8) bool {
    return eq(s, "-h") or eq(s, "--help") or eq(s, "help");
}

fn isVersion(s: []const u8) bool {
    return eq(s, "-v") or eq(s, "--version");
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownCommand => "unknown command (try `cb --help`)",
        error.MissingArgument => "missing required argument",
        error.ProjectNotFound => "no such project",
        error.WorktreeNotFound => "no such worktree",
        error.ProjectExists => "a project with that key already exists",
        error.ProjectHasWorktrees => "project has active worktrees",
        error.WorktreeExists => "a worktree with that key already exists",
        error.NotAGitRepo => "target directory is not a git repository",
        error.GitFailed => "a git command failed",
        error.GitNotFound => "git was not found on PATH",
        error.NoHome => "could not determine HOME",
        error.Aborted => "aborted",
        error.NotInWorktree => "current directory is not inside any registered project or worktree",
        error.AmbiguousContext => "current directory matches more than one registered project/worktree — pass <key> <worktree-key> explicitly",
        error.NotInteractive => "interactive picker requires a terminal (stdin/stderr must be a tty)",
        error.WorktreeDirty => "worktree has uncommitted or unpushed work — pass --force to remove anyway",
        error.GhNotFound => "gh (GitHub CLI) was not found on PATH",
        error.GhFailed => "a gh command failed (see above) — are you authenticated with `gh auth login`, and does this repo have a GitHub remote?",
        error.InvalidLineSpec => "invalid line spec — expected <path>, <path>:<line>, or <path>:<start>-<end>",
        error.PathOutsideRepo => "path is outside the current git repository",
        error.FileNotAtCommit => "file does not exist at HEAD — commit it, or the link will 404",
        error.ForkPrNotSupported => "PR is from a fork (see above for a workaround)",
        else => @errorName(err),
    };
}
