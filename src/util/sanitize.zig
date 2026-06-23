const std = @import("std");

// Branch names map to directory names by a fixed rule: "/" becomes "--" so the
// hierarchy is preserved legibly, and any other character that is awkward in a
// path segment collapses to a single "-". This is intentionally lossy and
// one-way; we never reconstruct a branch name from a directory name.
pub fn branchToDir(allocator: std.mem.Allocator, branch: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < branch.len) {
        const c = branch[i];
        if (c == '/') {
            try out.appendSlice("--");
            i += 1;
            continue;
        }
        if (isPathFriendly(c)) {
            try out.append(c);
        } else {
            // Collapse runs of unfriendly characters into one dash.
            if (out.items.len == 0 or out.items[out.items.len - 1] != '-') {
                try out.append('-');
            }
        }
        i += 1;
    }
    return out.toOwnedSlice();
}

fn isPathFriendly(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '.' or c == '_' or c == '-';
}

test "slash becomes double dash" {
    const a = std.testing.allocator;
    const got = try branchToDir(a, "feature/login");
    defer a.free(got);
    try std.testing.expectEqualStrings("feature--login", got);
}

test "unfriendly chars collapse to single dash" {
    const a = std.testing.allocator;
    const got = try branchToDir(a, "ryan/2026:01@thing");
    defer a.free(got);
    try std.testing.expectEqualStrings("ryan--2026-01-thing", got);
}
