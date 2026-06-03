//! `envless set KEY` — read value from stdin and store under env.

const std = @import("std");
const store = @import("../store.zig");
const root = @import("root.zig");

pub fn run(ctx: *root.Context, args: []const []const u8) !u8 {
    var rest = std.ArrayList([]const u8).init(ctx.allocator);
    defer rest.deinit();
    const env_opt = try root.popStringFlag(args, "--env", &rest);
    const env = env_opt orelse "dev";

    if (rest.items.len != 1) {
        try ctx.stderr.writer().writeAll("envless: set requires exactly one KEY argument\n");
        return 1;
    }
    const key = rest.items[0];

    // Read entire stdin.
    const data = ctx.stdin.readToEndAlloc(ctx.allocator, 16 * 1024 * 1024) catch |err| {
        try ctx.stderr.writer().print("envless: read stdin: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer ctx.allocator.free(data);

    // Trim only trailing newlines (matches Go: strings.TrimRight(..., "\n")).
    var end: usize = data.len;
    while (end > 0 and data[end - 1] == '\n') end -= 1;
    const value = data[0..end];

    const s = store.Store.init(ctx.allocator, ctx.cwd);
    s.set(env, key, value) catch |err| {
        try ctx.stderr.writer().print("envless: set: {s}\n", .{@errorName(err)});
        return 1;
    };

    try ctx.stdout.writer().print("SET   env={s} key={s}\n", .{ env, key });
    return 0;
}
