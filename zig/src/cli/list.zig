//! `envless list` — print keys (sorted) for the selected env, no values.

const std = @import("std");
const store = @import("../store.zig");
const root = @import("root.zig");

pub fn run(ctx: *root.Context, args: []const []const u8) !u8 {
    if (root.wantsHelp(args)) {
        try printHelp(ctx);
        return 0;
    }

    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(ctx.allocator);
    const env_opt = try root.popStringFlag(ctx.allocator, args, "--env", &rest);
    const env = env_opt orelse "dev";

    if (rest.items.len != 0) {
        try ctx.errWriteAll("envless: list takes no positional arguments\n");
        try ctx.errWriteAll("Run `envless list -h` for help.\n");
        return 2;
    }

    const s = store.Store.init(ctx.allocator, ctx.io, ctx.cwd);
    var r = s.keys(env) catch |err| {
        try ctx.errPrint("envless: list: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer r.deinit();
    var w = ctx.stdoutWriter();
    for (r.keys) |k| try w.interface.print("{s}\n", .{k});
    try w.flush();
    return 0;
}

fn printHelp(ctx: *root.Context) !void {
    var w = ctx.stdoutWriter();
    const s = try root.Style.fromFile(ctx.io, ctx.stdout);
    const b = s.bold();
    const d = s.dim();
    const r = s.reset();

    try w.interface.print("envless list {s}— list keys in an env (does not print values){s}\n\n", .{ d, r });

    try w.interface.print("{s}Usage:{s}\n", .{ b, r });
    try w.interface.writeAll("  envless list [--env=NAME]\n\n");

    try w.interface.print("{s}Description:{s}\n", .{ b, r });
    try w.interface.writeAll("  Prints every key defined in secrets/<env>.env.enc, one per line,\n");
    try w.interface.writeAll("  sorted alphabetically. Values are never decrypted or printed, so\n");
    try w.interface.writeAll("  this is the safe command to share over screen-shares and to pipe\n");
    try w.interface.writeAll("  through unaudited tools.\n\n");

    try w.interface.print("{s}Flags:{s}\n", .{ b, r });
    try w.interface.writeAll("  --env=NAME      environment to read from (default: dev)\n");
    try w.interface.writeAll("  -h, --help      show this help\n\n");

    try w.interface.print("{s}Examples:{s}\n", .{ b, r });
    try w.interface.print("  {s}# What's in dev?{s}\n", .{ d, r });
    try w.interface.writeAll("  envless list\n\n");
    try w.interface.print("  {s}# Diff the key set between envs{s}\n", .{ d, r });
    try w.interface.writeAll("  diff <(envless list --env=dev) <(envless list --env=prod)\n\n");

    try w.interface.print("{s}Exit codes:{s}\n", .{ b, r });
    try w.interface.writeAll("  0    listed (output may be empty if no keys)\n");
    try w.interface.writeAll("  1    sops decrypt failure\n");
    try w.interface.writeAll("  2    usage error (unexpected positional args)\n");
    try w.interface.writeAll("  64   no .envless/ found\n");
    try w.interface.writeAll("  66   env file does not exist\n\n");

    try w.interface.print("{s}See also:{s}\n", .{ b, r });
    try w.interface.writeAll("  envless get       reveal one secret value (requires --confirm)\n");
    try w.interface.writeAll("  envless exec      run a child process with secrets in its env\n");
    try w.interface.writeAll("  Docs:             https://biliboss.github.io/envless/cli/#envless-list\n");
    try w.flush();
}
