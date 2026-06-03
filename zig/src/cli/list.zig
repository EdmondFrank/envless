//! `envless list` — print keys (sorted) for the selected env, no values.

const std = @import("std");
const store = @import("../store.zig");
const root = @import("root.zig");

pub fn run(ctx: *root.Context, args: []const []const u8) !u8 {
    var rest = std.ArrayList([]const u8).init(ctx.allocator);
    defer rest.deinit();
    const env_opt = try root.popStringFlag(args, "--env", &rest);
    const env = env_opt orelse "dev";

    if (rest.items.len != 0) {
        try ctx.stderr.writer().writeAll("envless: list takes no positional arguments\n");
        return 1;
    }

    const s = store.Store.init(ctx.allocator, ctx.cwd);
    var r = s.keys(env) catch |err| {
        try ctx.stderr.writer().print("envless: list: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer r.deinit();
    const w = ctx.stdout.writer();
    for (r.keys) |k| try w.print("{s}\n", .{k});
    return 0;
}
