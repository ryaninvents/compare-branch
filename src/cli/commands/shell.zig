const std = @import("std");
const app = @import("../app.zig");

// `cb init <shell>` emits the shell function that fronts the binary. A binary
// can't change its parent shell's cwd or exit it, so `cd`, and the review-only
// `exit`/`done`, are handled here; everything else forwards to `cb-bin`. The
// body is POSIX-ish and works under both bash and zsh.

const wrapper =
    \\cb() {
    \\  case "$1" in
    \\    cd)
    \\      local __cb_dir
    \\      __cb_dir="$(command cb-bin cd-path "${@:2}")" || return $?
    \\      builtin cd "$__cb_dir"
    \\      ;;
    \\    exit)
    \\      if [ -n "$CB_REVIEW" ]; then
    \\        command cb-bin review-confirm-exit && builtin exit
    \\        return $?
    \\      fi
    \\      command cb-bin "$@"
    \\      ;;
    \\    done)
    \\      if [ -n "$CB_REVIEW" ]; then
    \\        command cb-bin review-done $CB_REVIEW && builtin exit
    \\        return $?
    \\      fi
    \\      command cb-bin "$@"
    \\      ;;
    \\    *)
    \\      command cb-bin "$@"
    \\      ;;
    \\  esac
    \\}
    \\
;

pub fn init(ctx: *app.Context, rest: []const []const u8) !void {
    const sh = if (rest.len > 0) rest[0] else "";
    if (!std.mem.eql(u8, sh, "zsh") and !std.mem.eql(u8, sh, "bash")) {
        ctx.warn("usage: cb init <zsh|bash>\n", .{});
        return error.MissingArgument;
    }
    ctx.print("{s}", .{wrapper});
}
