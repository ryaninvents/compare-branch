const std = @import("std");
const app = @import("app.zig");

// Interactive selection shared by every `-i` flag. Uses `fzf` when it's on
// PATH (it draws its own UI on the terminal regardless of stdin/stdout
// redirection, so piping candidates in and capturing the choice out is safe);
// otherwise falls back to a numbered prompt using the same stderr-prompt /
// stdin-answer channel discipline as common.confirm, so a caller like cd-path
// that captures stdout never sees picker UI mixed into its result. Refuses
// outright — never guesses — when the terminal isn't interactive.

pub fn pick(ctx: *app.Context, items: []const []const u8, prompt: []const u8) !?usize {
    if (items.len == 0) {
        ctx.warn("{s}: (nothing to pick from)\n", .{prompt});
        return null;
    }
    if (!std.io.getStdIn().isTty() or !std.io.getStdErr().isTty()) {
        return error.NotInteractive;
    }
    return pickWithFzf(ctx, items, prompt) catch |err| switch (err) {
        error.FileNotFound => pickNumbered(ctx, items, prompt),
        else => err,
    };
}

fn pickWithFzf(ctx: *app.Context, items: []const []const u8, prompt: []const u8) !?usize {
    const prompt_flag = try std.fmt.allocPrint(ctx.gpa, "--prompt={s}> ", .{prompt});
    defer ctx.gpa.free(prompt_flag);

    var child = std.process.Child.init(&.{ "fzf", prompt_flag, "--height=40%" }, ctx.gpa);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();

    {
        const stdin = child.stdin orelse return error.SpawnFailed;
        child.stdin = null;
        defer stdin.close();
        for (items) |item| {
            stdin.writeAll(item) catch {};
            stdin.writeAll("\n") catch {};
        }
    }

    const stdout = child.stdout orelse return error.SpawnFailed;
    const raw = stdout.readToEndAlloc(ctx.gpa, 64 * 1024) catch "";
    defer ctx.gpa.free(raw);
    const chosen = std.mem.trim(u8, raw, " \t\r\n");

    const term = child.wait() catch return error.SpawnFailed;
    const exited_ok = switch (term) {
        .Exited => |c| c == 0,
        else => false,
    };
    if (!exited_ok or chosen.len == 0) return null;

    for (items, 0..) |item, i| {
        if (std.mem.eql(u8, item, chosen)) return i;
    }
    return null;
}

fn pickNumbered(ctx: *app.Context, items: []const []const u8, prompt: []const u8) !?usize {
    ctx.warn("{s}:\n", .{prompt});
    for (items, 0..) |item, i| {
        ctx.warn("  {d}) {s}\n", .{ i + 1, item });
    }
    ctx.warn("choice [1-{d}, empty to cancel]: ", .{items.len});

    var buf: [32]u8 = undefined;
    const stdin = std.io.getStdIn().reader();
    const line = stdin.readUntilDelimiterOrEof(&buf, '\n') catch return null;
    const answer = std.mem.trim(u8, line orelse return null, " \t\r");
    if (answer.len == 0) return null;

    const n = std.fmt.parseInt(usize, answer, 10) catch return null;
    if (n < 1 or n > items.len) return null;
    return n - 1;
}
