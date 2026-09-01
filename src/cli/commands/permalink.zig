const std = @import("std");
const app = @import("../app.zig");
const args = @import("../args.zig");
const gh = @import("../../github/gh.zig");
const permalink = @import("../../github/permalink.zig");

// `cb get-permalink <path>[:<line>[-<line>]]` prints a GitHub permalink for a
// file (optionally a line or range) pinned to the current HEAD.
//
// Output discipline: stdout carries the URL and nothing else, so the command
// composes — `cb get-permalink src/main.zig:10-20 | pbcopy`. Every diagnostic
// goes to stderr, including the warning that HEAD is unpushed and the error
// that the file isn't at HEAD. The URL is printed even in the error case: the
// caller asked for a link, and knowing what it *would* be is what makes the
// diagnostic actionable.
//
// Unlike most commands this reads no state and infers no project — a permalink
// is meaningful in any git checkout, registered with cb or not.

pub fn getPermalink(ctx: *app.Context, rest: []const []const u8) !void {
    var a = try args.parse(ctx.gpa, rest, &.{"json"});
    defer a.deinit();

    const target = try permalink.parseTarget(a.pos(0) orelse return error.MissingArgument);

    const root = ctx.git.capture(null, &.{ "rev-parse", "--show-toplevel" }) catch
        return error.NotAGitRepo;
    defer ctx.gpa.free(root);

    const rel = try repoRelative(ctx, root, target.path);
    defer ctx.gpa.free(rel);

    const sha = try ctx.git.capture(root, &.{ "rev-parse", "HEAD" });
    defer ctx.gpa.free(sha);

    const url = try resolveUrl(ctx, root, sha, rel, target.lines);
    defer ctx.gpa.free(url);

    const pushed = isPushed(ctx, root);
    const exists = existsAtCommit(ctx, root, sha, rel);

    if (a.flag(&.{"json"})) {
        try printJson(ctx, url, sha, rel, target.lines, pushed, exists);
    } else {
        ctx.print("{s}\n", .{url});
    }

    if (!pushed) ctx.warn(
        "cb: warning: {s} is not pushed to any remote — this link will 404 until you push\n",
        .{sha},
    );
    // Printed the URL first, then fail: the diagnostic is worth an exit code
    // (a caller piping this can tell the link is dead) but not the output.
    if (!exists) return error.FileNotAtCommit;
}

/// Rewrites a cwd-relative (or absolute) path into a repo-root-relative one.
///
/// This is the reason we do not hand the path straight to `gh browse`: gh
/// resolves paths against the process cwd, so from src/ the argument
/// `src/main.zig` silently yields .../blob/<ref>/src/src/main.zig with a zero
/// exit status. Resolving against the root ourselves makes both spellings mean
/// the same file.
fn repoRelative(ctx: *app.Context, root: []const u8, path: []const u8) ![]u8 {
    const raw_cwd = std.process.getCwdAlloc(ctx.gpa) catch return error.NoHome;
    defer ctx.gpa.free(raw_cwd);
    // Both sides need realpath before comparison: getCwdAlloc resolves
    // symlinks (macOS /tmp -> /private/tmp) but rev-parse --show-toplevel need
    // not, and the prefix check below is a plain string compare.
    const cwd = std.fs.cwd().realpathAlloc(ctx.gpa, raw_cwd) catch try ctx.gpa.dupe(u8, raw_cwd);
    defer ctx.gpa.free(cwd);
    const real_root = std.fs.cwd().realpathAlloc(ctx.gpa, root) catch try ctx.gpa.dupe(u8, root);
    defer ctx.gpa.free(real_root);

    // realpath fails on a file that does not exist yet, and we still owe the
    // caller a URL in that case — fall back to lexical resolution.
    const abs = std.fs.cwd().realpathAlloc(ctx.gpa, path) catch
        try std.fs.path.resolve(ctx.gpa, &.{ cwd, path });
    defer ctx.gpa.free(abs);

    if (!isWithin(abs, real_root)) return error.PathOutsideRepo;
    if (abs.len == real_root.len) return error.PathOutsideRepo; // the root itself is not a file
    return ctx.gpa.dupe(u8, abs[real_root.len + 1 ..]);
}

/// True when `child` is a path descendant of `dir`. The trailing separator
/// check keeps /work/foo-bar from matching /work/foo, as in state/locate.zig.
fn isWithin(child: []const u8, dir: []const u8) bool {
    if (dir.len == 0) return false;
    if (std.mem.eql(u8, child, dir)) return true;
    if (child.len <= dir.len) return false;
    if (!std.mem.startsWith(u8, child, dir)) return false;
    return child[dir.len] == '/';
}

/// Asks gh for the URL, then rebuilds its tail. The `:1` is deliberate — with
/// no line spec gh emits a /tree/ URL, and we always want /blob/; buildUrl
/// discards the `?plain=1#L1` that comes back with it.
///
/// --commit must be spelled with `=`: it is declared as an optional-value flag
/// (string[="last"]), so `--commit <sha>` consumes the sha as the positional
/// argument and errors out.
fn resolveUrl(ctx: *app.Context, root: []const u8, sha: []const u8, rel: []const u8, lines: permalink.LineSpec) ![]u8 {
    const commit_arg = try std.fmt.allocPrint(ctx.gpa, "--commit={s}", .{sha});
    defer ctx.gpa.free(commit_arg);
    const path_arg = try std.fmt.allocPrint(ctx.gpa, "{s}:1", .{rel});
    defer ctx.gpa.free(path_arg);

    var out = try gh.run(ctx.gpa, root, &.{ "browse", "--no-browser", commit_arg, path_arg });
    defer out.deinit();
    if (!out.ok()) {
        ctx.warn("{s}", .{out.stderr});
        return error.GhFailed;
    }

    return permalink.buildUrl(ctx.gpa, out.line(), rel, lines);
}

/// Whether HEAD is reachable from any remote-tracking ref. `rev-list HEAD
/// --not --remotes` stops at the first commit that isn't, which is cheaper
/// than scanning every remote ref with `branch -r --contains`, and needs no
/// network. A failure here is reported as "pushed" — this is a diagnostic and
/// must never be the reason the command fails.
fn isPushed(ctx: *app.Context, root: []const u8) bool {
    var out = ctx.git.run(root, &.{ "rev-list", "HEAD", "--not", "--remotes", "--max-count=1" }) catch return true;
    defer out.deinit();
    if (!out.ok()) return true;
    return std.mem.trim(u8, out.stdout, " \n\r\t").len == 0;
}

fn existsAtCommit(ctx: *app.Context, root: []const u8, sha: []const u8, rel: []const u8) bool {
    const spec = std.fmt.allocPrint(ctx.gpa, "{s}:{s}", .{ sha, rel }) catch return true;
    defer ctx.gpa.free(spec);
    var out = ctx.git.run(root, &.{ "cat-file", "-e", spec }) catch return true;
    defer out.deinit();
    return out.ok();
}

const stringify_opts = std.json.StringifyOptions{ .emit_null_optional_fields = false, .whitespace = .indent_2 };

fn printJson(
    ctx: *app.Context,
    url: []const u8,
    sha: []const u8,
    rel: []const u8,
    lines: permalink.LineSpec,
    pushed: bool,
    exists: bool,
) !void {
    const start: ?u32 = switch (lines) {
        .none => null,
        .single => |n| n,
        .range => |r| r.start,
    };
    const end: ?u32 = switch (lines) {
        .none, .single => null,
        .range => |r| r.end,
    };

    var out = std.ArrayList(u8).init(ctx.gpa);
    defer out.deinit();
    try std.json.stringify(.{
        .url = url,
        .commit = sha,
        .path = rel,
        .startLine = start,
        .endLine = end,
        .pushed = pushed,
        .existsAtCommit = exists,
    }, stringify_opts, out.writer());
    ctx.print("{s}\n", .{out.items});
}
