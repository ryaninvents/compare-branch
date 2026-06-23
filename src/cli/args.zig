const std = @import("std");

// Minimal positional + flag parser. Flags named in `bool_flags` never consume a
// following token; any other `--name`/`-x` consumes the next token as its value
// (or `--name=value`). Short and long forms are stored under their literal name
// (without dashes), so callers check whichever aliases they accept.

pub const Args = struct {
    positionals: std.ArrayList([]const u8),
    values: std.StringHashMap([]const u8),
    present: std.StringHashMap(void),

    pub fn deinit(self: *Args) void {
        self.positionals.deinit();
        self.values.deinit();
        self.present.deinit();
    }

    pub fn pos(self: Args, i: usize) ?[]const u8 {
        return if (i < self.positionals.items.len) self.positionals.items[i] else null;
    }

    pub fn has(self: Args, name: []const u8) bool {
        return self.present.contains(name);
    }

    /// First matching value among the given aliases.
    pub fn value(self: Args, names: []const []const u8) ?[]const u8 {
        for (names) |n| {
            if (self.values.get(n)) |v| return v;
        }
        return null;
    }

    pub fn flag(self: Args, names: []const []const u8) bool {
        for (names) |n| {
            if (self.present.contains(n)) return true;
        }
        return false;
    }
};

pub fn parse(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    bool_flags: []const []const u8,
) !Args {
    var out = Args{
        .positionals = std.ArrayList([]const u8).init(allocator),
        .values = std.StringHashMap([]const u8).init(allocator),
        .present = std.StringHashMap(void).init(allocator),
    };
    errdefer out.deinit();

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const tok = argv[i];
        if (!isFlag(tok)) {
            try out.positionals.append(tok);
            continue;
        }
        const name = stripDashes(tok);
        if (std.mem.indexOfScalar(u8, name, '=')) |eq| {
            try out.values.put(name[0..eq], name[eq + 1 ..]);
            try out.present.put(name[0..eq], {});
            continue;
        }
        try out.present.put(name, {});
        if (isBool(name, bool_flags)) continue;
        if (i + 1 < argv.len and !isFlag(argv[i + 1])) {
            try out.values.put(name, argv[i + 1]);
            i += 1;
        }
    }
    return out;
}

fn isFlag(tok: []const u8) bool {
    return tok.len >= 2 and tok[0] == '-' and !(tok.len > 1 and std.ascii.isDigit(tok[1]));
}

fn stripDashes(tok: []const u8) []const u8 {
    var s = tok;
    while (s.len > 0 and s[0] == '-') s = s[1..];
    return s;
}

fn isBool(name: []const u8, bool_flags: []const []const u8) bool {
    for (bool_flags) |b| {
        if (std.mem.eql(u8, b, name)) return true;
    }
    return false;
}

test "parses positionals, values and bools" {
    const a = std.testing.allocator;
    const argv = [_][]const u8{ "proj", "key", "-t", "T-1", "--shell", "--base", "main" };
    var parsed = try parse(a, &argv, &.{"shell"});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("proj", parsed.pos(0).?);
    try std.testing.expectEqualStrings("key", parsed.pos(1).?);
    try std.testing.expectEqualStrings("T-1", parsed.value(&.{ "t", "ticket" }).?);
    try std.testing.expect(parsed.flag(&.{"shell"}));
    try std.testing.expectEqualStrings("main", parsed.value(&.{"base"}).?);
}
