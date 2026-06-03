//! `envless init` — create .envless/identity.key and seed recipients.

const std = @import("std");
const store = @import("../store.zig");
const root = @import("root.zig");

pub fn run(ctx: *root.Context, args: []const []const u8) !u8 {
    if (args.len != 0) {
        try ctx.stderr.writer().writeAll("envless: init takes no arguments\n");
        return 1;
    }

    const s = store.Store.init(ctx.allocator, ctx.cwd);
    s.initStore() catch |err| {
        try ctx.stderr.writer().print("envless: init: {s}\n", .{@errorName(err)});
        return 1;
    };

    const pub_key = s.pubKey() catch |err| {
        try ctx.stderr.writer().print("envless: pubkey: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer ctx.allocator.free(pub_key);

    const id_path = try s.identityPath(ctx.allocator);
    defer ctx.allocator.free(id_path);

    try ctx.stdout.writer().print("INIT  identity={s} pubkey={s}\n", .{ id_path, pub_key });
    return 0;
}
