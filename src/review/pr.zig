const std = @import("std");

// Pull-request resolution for `cb review <key> <PR>`: detecting whether a
// review target names a PR rather than a branch, and parsing `gh pr view
// --json`'s output. The actual `gh` subprocess spawn lives in
// cli/commands/review.zig (I/O); this stays pure so it's testable without gh
// installed.

/// A bare number ("123") or a GitHub PR URL (".../pull/123", with anything
/// after the number ignored) names a PR; anything else is a branch name.
pub fn detectPrNumber(target: []const u8) ?[]const u8 {
    if (target.len > 0 and allDigits(target)) return target;

    if (std.mem.indexOf(u8, target, "/pull/")) |idx| {
        const after = target[idx + "/pull/".len ..];
        var end: usize = 0;
        while (end < after.len and std.ascii.isDigit(after[end])) : (end += 1) {}
        if (end > 0) return after[0..end];
    }
    return null;
}

fn allDigits(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

pub const PrInfo = struct {
    head_ref: []u8,
    title: ?[]u8,
    author: ?[]u8,
    url: ?[]u8,
    is_cross_repository: bool,

    pub fn deinit(self: *PrInfo, gpa: std.mem.Allocator) void {
        gpa.free(self.head_ref);
        if (self.title) |t| gpa.free(t);
        if (self.author) |a| gpa.free(a);
        if (self.url) |u| gpa.free(u);
    }
};

/// Parses the output of
/// `gh pr view <n> --json headRefName,title,author,url,isCrossRepository`.
pub fn parsePrJson(gpa: std.mem.Allocator, json_bytes: []const u8) !PrInfo {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, json_bytes, .{});
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidPrJson,
    };

    const head_ref_val = obj.get("headRefName") orelse return error.InvalidPrJson;
    const head_ref = switch (head_ref_val) {
        .string => |s| try gpa.dupe(u8, s),
        else => return error.InvalidPrJson,
    };
    errdefer gpa.free(head_ref);

    const title = try optString(gpa, obj.get("title"));
    const url = try optString(gpa, obj.get("url"));

    const author = blk: {
        const author_val = obj.get("author") orelse break :blk null;
        const author_obj = switch (author_val) {
            .object => |o| o,
            else => break :blk null,
        };
        break :blk try optString(gpa, author_obj.get("login"));
    };

    const is_cross_repository = switch (obj.get("isCrossRepository") orelse std.json.Value{ .bool = false }) {
        .bool => |b| b,
        else => false,
    };

    return .{
        .head_ref = head_ref,
        .title = title,
        .author = author,
        .url = url,
        .is_cross_repository = is_cross_repository,
    };
}

fn optString(gpa: std.mem.Allocator, v: ?std.json.Value) !?[]u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| try gpa.dupe(u8, s),
        else => null,
    };
}

test "detectPrNumber: bare number" {
    try std.testing.expectEqualStrings("123", detectPrNumber("123").?);
}

test "detectPrNumber: PR URL" {
    try std.testing.expectEqualStrings("456", detectPrNumber("https://github.com/o/r/pull/456").?);
    try std.testing.expectEqualStrings("456", detectPrNumber("https://github.com/o/r/pull/456/files").?);
}

test "detectPrNumber: a branch name is not a PR" {
    try std.testing.expect(detectPrNumber("feature/login") == null);
    try std.testing.expect(detectPrNumber("") == null);
}

test "parsePrJson: extracts fields from a gh pr view fixture" {
    const gpa = std.testing.allocator;
    const fixture =
        \\{"headRefName":"feature/login","title":"Add login","author":{"login":"octocat"},"url":"https://github.com/o/r/pull/1","isCrossRepository":false}
    ;
    var info = try parsePrJson(gpa, fixture);
    defer info.deinit(gpa);
    try std.testing.expectEqualStrings("feature/login", info.head_ref);
    try std.testing.expectEqualStrings("Add login", info.title.?);
    try std.testing.expectEqualStrings("octocat", info.author.?);
    try std.testing.expectEqualStrings("https://github.com/o/r/pull/1", info.url.?);
    try std.testing.expect(!info.is_cross_repository);
}

test "parsePrJson: flags a fork PR via isCrossRepository" {
    const gpa = std.testing.allocator;
    const fixture =
        \\{"headRefName":"feature","title":"x","author":{"login":"y"},"url":"z","isCrossRepository":true}
    ;
    var info = try parsePrJson(gpa, fixture);
    defer info.deinit(gpa);
    try std.testing.expect(info.is_cross_repository);
}

test "parsePrJson: missing headRefName is an error" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidPrJson, parsePrJson(gpa, "{}"));
}
