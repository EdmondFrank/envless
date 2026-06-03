//! `envless get KEY --confirm` — print a secret value (refuses without --confirm).

const std = @import("std");
const store = @import("../store.zig");
const root = @import("root.zig");

pub fn run(ctx: *root.Context, args: []const []const u8) !u8 {
    var rest_after_env = std.ArrayList([]const u8).init(ctx.allocator);
    defer rest_after_env.deinit();
    const env_opt = try root.popStringFlag(args, "--env", &rest_after_env);
    const env = env_opt orelse "dev";

    var rest = std.ArrayList([]const u8).init(ctx.allocator);
    defer rest.deinit();
    const confirm = try root.popBoolFlag(rest_after_env.items, "--confirm", &rest);

    if (!confirm) {
        try ctx.stderr.writer().writeAll("envless: printing a secret requires --confirm\n");
        return 1;
    }
    if (rest.items.len != 1) {
        try ctx.stderr.writer().writeAll("envless: get requires exactly one KEY argument\n");
        return 1;
    }
    const key = rest.items[0];

    const s = store.Store.init(ctx.allocator, ctx.cwd);
    var r = s.get(env, key) catch |err| {
        try ctx.stderr.writer().print("envless: get: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer r.deinit();

    if (!r.found) {
        try ctx.stderr.writer().print("envless: key \"{s}\" not found in env \"{s}\"\n", .{ key, env });
        return 1;
    }
    try ctx.stdout.writer().print("{s}\n", .{r.value});
    return 0;
}
