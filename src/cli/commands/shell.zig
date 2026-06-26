const std = @import("std");
const app = @import("../app.zig");

// `cb init <shell>` emits the shell integration that fronts the binary. A binary
// can't change its parent shell's cwd or exit it, so `cd`, and the review-only
// `exit`/`done`, are handled in the shell wrapper; everything else forwards to
// `cb-bin`. The wrapper files under shell/ are the single source of truth:
// Homebrew installs them for `source`, and they are embedded here (registered as
// named imports in build.zig) so the manual `eval "$(cb-bin init zsh)"` path
// stays byte-for-byte identical with zero drift.

const wrapper_zsh = @embedFile("cb_zsh");
const wrapper_bash = @embedFile("cb_bash");

pub fn init(ctx: *app.Context, rest: []const []const u8) !void {
    const sh = if (rest.len > 0) rest[0] else "";
    if (std.mem.eql(u8, sh, "zsh")) {
        ctx.print("{s}", .{wrapper_zsh});
        return;
    }
    if (std.mem.eql(u8, sh, "bash")) {
        ctx.print("{s}", .{wrapper_bash});
        return;
    }
    ctx.warn("usage: cb init <zsh|bash>\n", .{});
    return error.MissingArgument;
}
