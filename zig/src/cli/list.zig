//! `envless list` — print keys (sorted) for the selected env, no values.

const std = @import("std");
const store = @import("../store.zig");
const root = @import("root.zig");

pub fn run(ctx: *root.Context, args: []const []const u8) !u8 {
    if (root.wantsHelp(args)) {
        try printHelp(ctx);
        return 0;
    }

    var rest = std.ArrayList([]const u8).init(ctx.allocator);
    defer rest.deinit();
    const env_opt = try root.popStringFlag(args, "--env", &rest);
    const env = env_opt orelse "dev";

    if (rest.items.len != 0) {
        try ctx.stderr.writer().writeAll("envless: list takes no positional arguments\n");
        try ctx.stderr.writer().writeAll("Run `envless list -h` for help.\n");
        return 2;
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

fn printHelp(ctx: *root.Context) !void {
    const w = ctx.stdout.writer();
    const s = root.Style.fromFile(ctx.stdout);
    const b = s.bold();
    const d = s.dim();
    const r = s.reset();

    try w.print("envless list {s}— list keys in an env (does not print values){s}\n\n", .{ d, r });

    try w.print("{s}Usage:{s}\n", .{ b, r });
    try w.writeAll("  envless list [--env=NAME]\n\n");

    try w.print("{s}Description:{s}\n", .{ b, r });
    try w.writeAll("  Prints every key defined in secrets/<env>.env.enc, one per line,\n");
    try w.writeAll("  sorted alphabetically. Values are never decrypted or printed, so\n");
    try w.writeAll("  this is the safe command to share over screen-shares and to pipe\n");
    try w.writeAll("  through unaudited tools.\n\n");

    try w.print("{s}Flags:{s}\n", .{ b, r });
    try w.writeAll("  --env=NAME      environment to read from (default: dev)\n");
    try w.writeAll("  -h, --help      show this help\n\n");

    try w.print("{s}Examples:{s}\n", .{ b, r });
    try w.print("  {s}# What's in dev?{s}\n", .{ d, r });
    try w.writeAll("  envless list\n\n");
    try w.print("  {s}# Diff the key set between envs{s}\n", .{ d, r });
    try w.writeAll("  diff <(envless list --env=dev) <(envless list --env=prod)\n\n");

    try w.print("{s}Exit codes:{s}\n", .{ b, r });
    try w.writeAll("  0    listed (output may be empty if no keys)\n");
    try w.writeAll("  1    sops decrypt failure\n");
    try w.writeAll("  2    usage error (unexpected positional args)\n");
    try w.writeAll("  64   no .envless/ found\n");
    try w.writeAll("  66   env file does not exist\n\n");

    try w.print("{s}See also:{s}\n", .{ b, r });
    try w.writeAll("  envless get       reveal one secret value (requires --confirm)\n");
    try w.writeAll("  envless exec      run a child process with secrets in its env\n");
    try w.writeAll("  Docs:             https://biliboss.github.io/envless/cli/#envless-list\n");
}
