const std = @import("std");

// Resolve the locations cb reads and writes. Config is user-authored and lives
// under XDG_CONFIG_HOME (~/.config/cb); the mutable event log lives under
// ~/.local/cb per the project's chosen layout (note: deliberately not
// ~/.local/state). Both honour an explicit override for tests.

pub fn configPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "CB_CONFIG_FILE")) |p| {
        return p;
    } else |_| {}
    const base = try xdgDir(allocator, "XDG_CONFIG_HOME", ".config");
    defer allocator.free(base);
    return std.fs.path.join(allocator, &.{ base, "cb", "config.json" });
}

pub fn statePath(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "CB_STATE_FILE")) |p| {
        return p;
    } else |_| {}
    const home = try homeDir(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".local", "cb", "state.json" });
}

fn xdgDir(allocator: std.mem.Allocator, env: []const u8, fallback: []const u8) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, env)) |p| {
        return p;
    } else |_| {}
    const home = try homeDir(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, fallback });
}

fn homeDir(allocator: std.mem.Allocator) ![]u8 {
    return std.process.getEnvVarOwned(allocator, "HOME") catch error.NoHome;
}

pub fn ensureParentDir(path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse return;
    try std.fs.cwd().makePath(dir);
}
