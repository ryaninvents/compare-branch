const std = @import("std");

// The config string-interpolation DSL. A template is a JSON array whose
// elements are concatenated. Each element is either a literal string or a
// one-key object: {"var": name}, {"date": format}, or
// {"join": {"delimiter": d, "elements": [...]}}. Variables may resolve to other
// templates (e.g. workDir references HOME), so resolution is recursive with a
// cycle guard. Time is injected rather than read from the clock so renders are
// deterministic and testable; formatting is UTC.

pub const RenderError = error{
    InvalidTemplate,
    UnknownTemplateOp,
    CyclicVariable,
    OutOfMemory,
};

pub const Scope = struct {
    allocator: std.mem.Allocator,
    /// Config-level named templates (workDir, baseDir, branches.name inputs…).
    /// Values may be plain strings or nested template arrays.
    vars: *const std.json.ObjectMap,
    /// Per-invocation values such as `ticket` and `worktree-key`.
    context: *const std.StringHashMap([]const u8),
    now_unix: i64,
    /// Names currently being resolved, to detect reference cycles.
    resolving: *std.ArrayList([]const u8),

    fn getEnv(self: Scope, name: []const u8) ?[]u8 {
        return std.process.getEnvVarOwned(self.allocator, name) catch null;
    }
};

pub fn render(scope: Scope, template: std.json.Value) RenderError![]u8 {
    var out = std.ArrayList(u8).init(scope.allocator);
    errdefer out.deinit();
    try renderInto(&out, scope, template);
    return out.toOwnedSlice();
}

fn renderInto(out: *std.ArrayList(u8), scope: Scope, value: std.json.Value) RenderError!void {
    switch (value) {
        .string => |s| try out.appendSlice(s),
        .array => |arr| {
            for (arr.items) |el| try renderInto(out, scope, el);
        },
        .object => |obj| try renderOp(out, scope, obj),
        else => return error.InvalidTemplate,
    }
}

fn renderOp(out: *std.ArrayList(u8), scope: Scope, obj: std.json.ObjectMap) RenderError!void {
    if (obj.count() != 1) return error.InvalidTemplate;
    var it = obj.iterator();
    const entry = it.next().?;
    const op = entry.key_ptr.*;
    const arg = entry.value_ptr.*;

    if (std.mem.eql(u8, op, "var")) {
        const name = switch (arg) {
            .string => |s| s,
            else => return error.InvalidTemplate,
        };
        const resolved = try resolveVar(scope, name);
        defer scope.allocator.free(resolved);
        try out.appendSlice(resolved);
        return;
    }
    if (std.mem.eql(u8, op, "date")) {
        const fmt = switch (arg) {
            .string => |s| s,
            else => return error.InvalidTemplate,
        };
        try formatDate(out, fmt, scope.now_unix);
        return;
    }
    if (std.mem.eql(u8, op, "join")) {
        try renderJoin(out, scope, arg);
        return;
    }
    return error.UnknownTemplateOp;
}

fn renderJoin(out: *std.ArrayList(u8), scope: Scope, arg: std.json.Value) RenderError!void {
    const spec = switch (arg) {
        .object => |o| o,
        else => return error.InvalidTemplate,
    };
    const delimiter = blk: {
        const d = spec.get("delimiter") orelse break :blk "";
        break :blk switch (d) {
            .string => |s| s,
            else => return error.InvalidTemplate,
        };
    };
    const elements = switch (spec.get("elements") orelse return error.InvalidTemplate) {
        .array => |a| a,
        else => return error.InvalidTemplate,
    };

    var first = true;
    for (elements.items) |el| {
        const rendered = try render(scope, el);
        defer scope.allocator.free(rendered);
        // Empty pieces are dropped so an absent ticket doesn't leave a dangling
        // delimiter in the branch name.
        if (rendered.len == 0) continue;
        if (!first) try out.appendSlice(delimiter);
        try out.appendSlice(rendered);
        first = false;
    }
}

fn resolveVar(scope: Scope, name: []const u8) RenderError![]u8 {
    if (scope.context.get(name)) |v| return scope.allocator.dupe(u8, v);

    if (scope.vars.get(name)) |tmpl| {
        for (scope.resolving.items) |active| {
            if (std.mem.eql(u8, active, name)) return error.CyclicVariable;
        }
        try scope.resolving.append(name);
        defer _ = scope.resolving.pop();
        return render(scope, tmpl);
    }

    if (scope.getEnv(name)) |env_val| return env_val; // already owned
    return scope.allocator.dupe(u8, "");
}

fn formatDate(out: *std.ArrayList(u8), fmt: []const u8, now_unix: i64) RenderError!void {
    const secs: u64 = if (now_unix < 0) 0 else @intCast(now_unix);
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = es.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const ds = es.getDaySeconds();

    const year: u16 = year_day.year;
    const month: u8 = month_day.month.numeric();
    const dom: u8 = month_day.day_index + 1;
    const hour: u8 = ds.getHoursIntoDay();
    const minute: u8 = ds.getMinutesIntoHour();
    const second: u8 = ds.getSecondsIntoMinute();

    var i: usize = 0;
    while (i < fmt.len) {
        if (matchToken(fmt[i..], "YYYY")) {
            try out.writer().print("{d:0>4}", .{year});
            i += 4;
        } else if (matchToken(fmt[i..], "MM")) {
            try out.writer().print("{d:0>2}", .{month});
            i += 2;
        } else if (matchToken(fmt[i..], "DD")) {
            try out.writer().print("{d:0>2}", .{dom});
            i += 2;
        } else if (matchToken(fmt[i..], "HH")) {
            try out.writer().print("{d:0>2}", .{hour});
            i += 2;
        } else if (matchToken(fmt[i..], "mm")) {
            try out.writer().print("{d:0>2}", .{minute});
            i += 2;
        } else if (matchToken(fmt[i..], "ss")) {
            try out.writer().print("{d:0>2}", .{second});
            i += 2;
        } else {
            try out.append(fmt[i]);
            i += 1;
        }
    }
}

fn matchToken(haystack: []const u8, token: []const u8) bool {
    return haystack.len >= token.len and std.mem.eql(u8, haystack[0..token.len], token);
}

const testing = std.testing;

fn parse(s: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, testing.allocator, s, .{});
}

test "concatenates literals and env vars" {
    var vars = std.json.ObjectMap.init(testing.allocator);
    defer vars.deinit();
    var ctx = std.StringHashMap([]const u8).init(testing.allocator);
    defer ctx.deinit();
    var resolving = std.ArrayList([]const u8).init(testing.allocator);
    defer resolving.deinit();
    try ctx.put("USER", "ryan");

    const tmpl = try parse("[{\"var\":\"USER\"},\"/work\"]");
    defer tmpl.deinit();

    const scope = Scope{
        .allocator = testing.allocator,
        .vars = &vars,
        .context = &ctx,
        .now_unix = 0,
        .resolving = &resolving,
    };
    const got = try render(scope, tmpl.value);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("ryan/work", got);
}

test "date formatting is UTC and zero-padded" {
    var vars = std.json.ObjectMap.init(testing.allocator);
    defer vars.deinit();
    var ctx = std.StringHashMap([]const u8).init(testing.allocator);
    defer ctx.deinit();
    var resolving = std.ArrayList([]const u8).init(testing.allocator);
    defer resolving.deinit();

    // 2021-01-02 03:04:05 UTC
    const tmpl = try parse("[{\"date\":\"YYYYMMDD.HHmmss\"}]");
    defer tmpl.deinit();
    const scope = Scope{
        .allocator = testing.allocator,
        .vars = &vars,
        .context = &ctx,
        .now_unix = 1609556645,
        .resolving = &resolving,
    };
    const got = try render(scope, tmpl.value);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("20210102.030405", got);
}

test "join drops empty elements" {
    var vars = std.json.ObjectMap.init(testing.allocator);
    defer vars.deinit();
    var ctx = std.StringHashMap([]const u8).init(testing.allocator);
    defer ctx.deinit();
    var resolving = std.ArrayList([]const u8).init(testing.allocator);
    defer resolving.deinit();
    try ctx.put("worktree-key", "login");

    const tmpl = try parse(
        \\[{"join":{"delimiter":"--","elements":[{"var":"ticket"},{"var":"worktree-key"}]}}]
    );
    defer tmpl.deinit();
    const scope = Scope{
        .allocator = testing.allocator,
        .vars = &vars,
        .context = &ctx,
        .now_unix = 0,
        .resolving = &resolving,
    };
    const got = try render(scope, tmpl.value);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("login", got);
}

test "cyclic variable is rejected" {
    const src =
        \\{"a":[{"var":"b"}],"b":[{"var":"a"}]}
    ;
    const parsed = try parse(src);
    defer parsed.deinit();
    var ctx = std.StringHashMap([]const u8).init(testing.allocator);
    defer ctx.deinit();
    var resolving = std.ArrayList([]const u8).init(testing.allocator);
    defer resolving.deinit();
    const scope = Scope{
        .allocator = testing.allocator,
        .vars = &parsed.value.object,
        .context = &ctx,
        .now_unix = 0,
        .resolving = &resolving,
    };
    const tmpl = try parse("[{\"var\":\"a\"}]");
    defer tmpl.deinit();
    try testing.expectError(error.CyclicVariable, render(scope, tmpl.value));
}
