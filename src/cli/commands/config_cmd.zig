const std = @import("std");
const app = @import("../app.zig");
const paths = @import("../../util/paths.zig");

// `cb config` reports where config lives and prints it; `cb config path` prints
// just the path (handy for `$EDITOR "$(cb config path)"`).

pub fn config(ctx: *app.Context, rest: []const []const u8) !void {
    const path = try paths.configPath(ctx.gpa);
    defer ctx.gpa.free(path);

    if (rest.len > 0 and std.mem.eql(u8, rest[0], "path")) {
        ctx.print("{s}\n", .{path});
        return;
    }

    ctx.print("# {s}\n", .{path});
    const text = std.fs.cwd().readFileAlloc(ctx.gpa, path, 4 * 1024 * 1024) catch |e| switch (e) {
        error.FileNotFound => {
            ctx.print("(no config file — built-in defaults are in effect)\n", .{});
            return;
        },
        else => return e,
    };
    defer ctx.gpa.free(text);
    ctx.print("{s}\n", .{text});
}
