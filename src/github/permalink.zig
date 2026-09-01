const std = @import("std");

// URL assembly for `cb get-permalink`. Kept free of subprocesses so it is
// testable without gh installed — the spawn lives in cli/commands/permalink.zig,
// mirroring the split review/pr.zig makes for the same reason.
//
// `gh browse` produces everything up to and including the file path: it knows
// the host, resolves the owner/repo, and escapes path segments. We rebuild the
// query and fragment ourselves because gh appends `?plain=1` to every ranged
// link even where it does nothing, and because its own `<path>:<line>` parsing
// is relative to the process cwd rather than the repo root.

pub const LineSpec = union(enum) {
    none,
    single: u32,
    range: struct { start: u32, end: u32 },
};

pub const Target = struct {
    path: []const u8,
    lines: LineSpec,
};

/// Parses `path`, `path:42`, or `path:10-20` — the same argument form
/// `gh browse` accepts, so the two are copy-pasteable between each other.
pub fn parseTarget(arg: []const u8) !Target {
    if (arg.len == 0) return error.MissingArgument;

    // Split on the last colon so a path that itself contains one still works.
    const colon = std.mem.lastIndexOfScalar(u8, arg, ':') orelse
        return .{ .path = arg, .lines = .none };

    const suffix = arg[colon + 1 ..];
    // A suffix that was never meant as a line spec belongs to the path:
    // `cb get-permalink notes:draft.md` should resolve, not error.
    if (!isSpecShaped(suffix)) return .{ .path = arg, .lines = .none };

    const path = arg[0..colon];
    if (path.len == 0) return error.InvalidLineSpec;
    return .{ .path = path, .lines = try parseLineSpec(suffix) };
}

/// Digits, optionally with an interior `-`. Anything else is part of the path.
fn isSpecShaped(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isDigit(s[0])) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c) and c != '-') return false;
    }
    return true;
}

fn parseLineSpec(s: []const u8) !LineSpec {
    var it = std.mem.splitScalar(u8, s, '-');
    const first = it.next() orelse return error.InvalidLineSpec;
    const start = try parseLine(first);

    const second = it.next() orelse return .{ .single = start };
    if (it.next() != null) return error.InvalidLineSpec;

    const end = try parseLine(second);
    // A reversed range is always a mistake, and GitHub renders it as an empty
    // selection rather than complaining — so catch it here.
    if (end < start) return error.InvalidLineSpec;
    return .{ .range = .{ .start = start, .end = end } };
}

fn parseLine(s: []const u8) !u32 {
    const n = std.fmt.parseInt(u32, s, 10) catch return error.InvalidLineSpec;
    // GitHub line anchors are 1-based; #L0 selects nothing.
    if (n == 0) return error.InvalidLineSpec;
    return n;
}

/// Rebuilds `gh_url` with our own query and fragment. Everything before the
/// first `?` or `#` is gh's — host, owner/repo, commit and escaped path — and
/// is passed through untouched.
pub fn buildUrl(gpa: std.mem.Allocator, gh_url: []const u8, path: []const u8, lines: LineSpec) ![]u8 {
    const base = gh_url[0..cutIndex(gh_url)];

    var out = std.ArrayList(u8).init(gpa);
    errdefer out.deinit();
    try out.appendSlice(base);

    // Markdown renders by default, which swallows line anchors; ?plain=1 is
    // GitHub's documented way to make them resolve. It is a no-op noise
    // elsewhere, so only Markdown gets it.
    if (lines != .none and isMarkdown(path)) try out.appendSlice("?plain=1");

    switch (lines) {
        .none => {},
        .single => |n| try out.writer().print("#L{d}", .{n}),
        .range => |r| try out.writer().print("#L{d}-L{d}", .{ r.start, r.end }),
    }
    return out.toOwnedSlice();
}

fn cutIndex(url: []const u8) usize {
    const q = std.mem.indexOfScalar(u8, url, '?') orelse url.len;
    const h = std.mem.indexOfScalar(u8, url, '#') orelse url.len;
    return @min(q, h);
}

fn isMarkdown(path: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(path, ".md") or
        std.ascii.endsWithIgnoreCase(path, ".markdown");
}

test "parseTarget: bare path has no line spec" {
    const t = try parseTarget("src/main.zig");
    try std.testing.expectEqualStrings("src/main.zig", t.path);
    try std.testing.expect(t.lines == .none);
}

test "parseTarget: single line" {
    const t = try parseTarget("src/main.zig:42");
    try std.testing.expectEqualStrings("src/main.zig", t.path);
    try std.testing.expectEqual(@as(u32, 42), t.lines.single);
}

test "parseTarget: line range" {
    const t = try parseTarget("src/main.zig:10-20");
    try std.testing.expectEqualStrings("src/main.zig", t.path);
    try std.testing.expectEqual(@as(u32, 10), t.lines.range.start);
    try std.testing.expectEqual(@as(u32, 20), t.lines.range.end);
}

test "parseTarget: a colon that isn't a line spec stays in the path" {
    const t = try parseTarget("notes:draft.md");
    try std.testing.expectEqualStrings("notes:draft.md", t.path);
    try std.testing.expect(t.lines == .none);
}

test "parseTarget: rejects malformed specs" {
    try std.testing.expectError(error.InvalidLineSpec, parseTarget("a.zig:0"));
    try std.testing.expectError(error.InvalidLineSpec, parseTarget("a.zig:20-10"));
    try std.testing.expectError(error.InvalidLineSpec, parseTarget("a.zig:1-2-3"));
    try std.testing.expectError(error.InvalidLineSpec, parseTarget(":10"));
    try std.testing.expectError(error.MissingArgument, parseTarget(""));
}

test "parseTarget: an equal-bound range is a valid one-line range" {
    const t = try parseTarget("a.zig:7-7");
    try std.testing.expectEqual(@as(u32, 7), t.lines.range.end);
}

test "buildUrl: non-markdown drops the ?plain=1 gh adds" {
    const gpa = std.testing.allocator;
    const url = try buildUrl(
        gpa,
        "https://github.com/o/r/blob/abc123/src/main.zig?plain=1#L1",
        "src/main.zig",
        .{ .range = .{ .start = 10, .end = 20 } },
    );
    defer gpa.free(url);
    try std.testing.expectEqualStrings("https://github.com/o/r/blob/abc123/src/main.zig#L10-L20", url);
}

test "buildUrl: markdown keeps ?plain=1" {
    const gpa = std.testing.allocator;
    const url = try buildUrl(
        gpa,
        "https://github.com/o/r/blob/abc123/README.md?plain=1#L1",
        "README.md",
        .{ .single = 14 },
    );
    defer gpa.free(url);
    try std.testing.expectEqualStrings("https://github.com/o/r/blob/abc123/README.md?plain=1#L14", url);
}

test "buildUrl: no line spec yields a bare blob URL" {
    const gpa = std.testing.allocator;
    const url = try buildUrl(
        gpa,
        "https://github.com/o/r/blob/abc123/README.md?plain=1#L1",
        "README.md",
        .none,
    );
    defer gpa.free(url);
    try std.testing.expectEqualStrings("https://github.com/o/r/blob/abc123/README.md", url);
}

test "buildUrl: a gh URL with no query or fragment passes through" {
    const gpa = std.testing.allocator;
    const url = try buildUrl(gpa, "https://ghe.example.com/o/r/blob/abc/a.zig", "a.zig", .{ .single = 3 });
    defer gpa.free(url);
    try std.testing.expectEqualStrings("https://ghe.example.com/o/r/blob/abc/a.zig#L3", url);
}
