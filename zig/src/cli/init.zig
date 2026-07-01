//! `envless init` — create .envless/identity.key and seed recipients.

const std = @import("std");
const store = @import("../store.zig");
const root = @import("root.zig");

pub fn run(ctx: *root.Context, args: []const []const u8) !u8 {
    if (root.wantsHelp(args)) {
        try printHelp(ctx);
        return 0;
    }
    if (args.len != 0) {
        try ctx.errWriteAll("envless: init takes no arguments\n");
        try ctx.errWriteAll("Run `envless init -h` for help.\n");
        return 2;
    }

    const s = store.Store.init(ctx.allocator, ctx.io, ctx.cwd);
    s.initStore() catch |err| {
        try ctx.errPrint("envless: init: {s}\n", .{@errorName(err)});
        return 1;
    };

    const pub_key = s.pubKey() catch |err| {
        try ctx.errPrint("envless: pubkey: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer ctx.allocator.free(pub_key);

    const id_path = try s.identityPath(ctx.allocator);
    defer ctx.allocator.free(id_path);

    try ctx.outPrint("INIT  identity={s} pubkey={s}\n", .{ id_path, pub_key });
    return 0;
}

fn printHelp(ctx: *root.Context) !void {
    var w = ctx.stdoutWriter();
    const s = try root.Style.fromFile(ctx.io, ctx.stdout);
    const b = s.bold();
    const d = s.dim();
    const r = s.reset();

    try w.interface.print("envless init {s}— initialize .envless/ in the current directory{s}\n\n", .{ d, r });

    try w.interface.print("{s}Usage:{s}\n", .{ b, r });
    try w.interface.writeAll("  envless init\n\n");

    try w.interface.print("{s}Description:{s}\n", .{ b, r });
    try w.interface.writeAll("  Generates a new age identity at .envless/identity.key (chmod 0600) and\n");
    try w.interface.writeAll("  seeds .envless/recipients with the matching public key. Run this once per\n");
    try w.interface.writeAll("  developer per repo — the identity is the local secret, the recipients\n");
    try w.interface.writeAll("  file is checked in so others can encrypt secrets to you.\n\n");

    try w.interface.print("{s}Flags:{s}\n", .{ b, r });
    try w.interface.writeAll("  -h, --help      show this help\n\n");

    try w.interface.print("{s}Examples:{s}\n", .{ b, r });
    try w.interface.print("  {s}# Fresh repo — create identity and start adding secrets{s}\n", .{ d, r });
    try w.interface.writeAll("  envless init\n");
    try w.interface.writeAll("  echo \"sk-test-xyz\" | envless set OPENAI_API_KEY\n\n");
    try w.interface.print("  {s}# Onboarding a new developer (after they run init){s}\n", .{ d, r });
    try w.interface.print("  {s}# share the pubkey from .envless/recipients with the team{s}\n", .{ d, r });
    try w.interface.writeAll("  cat .envless/recipients\n\n");

    try w.interface.print("{s}Exit codes:{s}\n", .{ b, r });
    try w.interface.writeAll("  0    identity created (or already present, idempotent)\n");
    try w.interface.writeAll("  1    failed to write identity (permissions, disk full)\n");
    try w.interface.writeAll("  2    usage error (init takes no arguments)\n\n");

    try w.interface.print("{s}See also:{s}\n", .{ b, r });
    try w.interface.writeAll("  envless set       store the first secret once init is done\n");
    try w.interface.writeAll("  Docs:             https://biliboss.github.io/envless/cli/#envless-init\n");
    try w.flush();
}
