//! `envless set KEY` — read value from stdin and store under env.

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

    if (rest.items.len != 1) {
        try ctx.errWriteAll("envless: set requires exactly one KEY argument\n");
        try ctx.errWriteAll("Run `envless set -h` for help.\n");
        return 2;
    }
    const key = rest.items[0];

    // Read entire stdin via the reader interface.
    var reader_buf: [8192]u8 = undefined;
    var stdin_reader = ctx.stdin.reader(ctx.io, &reader_buf);
    const data = stdin_reader.interface.allocRemaining(ctx.allocator, .limited(16 * 1024 * 1024)) catch |err| {
        try ctx.errPrint("envless: read stdin: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer ctx.allocator.free(data);

    // Trim only trailing newlines (matches Go: strings.TrimRight(..., "\n")).
    var end: usize = data.len;
    while (end > 0 and data[end - 1] == '\n') end -= 1;
    const value = data[0..end];

    const s = store.Store.init(ctx.allocator, ctx.io, ctx.cwd);
    s.set(env, key, value) catch |err| {
        try ctx.errPrint("envless: set: {s}\n", .{@errorName(err)});
        return 1;
    };

    try ctx.outPrint("SET   env={s} key={s}\n", .{ env, key });
    return 0;
}

fn printHelp(ctx: *root.Context) !void {
    var w = ctx.stdoutWriter();
    const s = try root.Style.fromFile(ctx.io, ctx.stdout);
    const b = s.bold();
    const d = s.dim();
    const r = s.reset();

    try w.interface.print("envless set {s}— store a secret value from stdin{s}\n\n", .{ d, r });

    try w.interface.print("{s}Usage:{s}\n", .{ b, r });
    try w.interface.writeAll("  envless set KEY [--env=NAME]\n\n");

    try w.interface.print("{s}Description:{s}\n", .{ b, r });
    try w.interface.writeAll("  Reads the secret value from stdin (trailing newlines stripped) and\n");
    try w.interface.writeAll("  stores it under KEY in secrets/<env>.env.enc, re-encrypted with sops\n");
    try w.interface.writeAll("  to every public key in .envless/recipients. The value never appears\n");
    try w.interface.writeAll("  in argv, so it stays out of shell history and ps listings.\n\n");

    try w.interface.print("{s}Flags:{s}\n", .{ b, r });
    try w.interface.writeAll("  --env=NAME      environment to write into (default: dev)\n");
    try w.interface.writeAll("  -h, --help      show this help\n\n");

    try w.interface.print("{s}Examples:{s}\n", .{ b, r });
    try w.interface.print("  {s}# Pipe a value from stdin (preferred — no shell history){s}\n", .{ d, r });
    try w.interface.writeAll("  echo \"sk-test-xyz\" | envless set OPENAI_API_KEY\n\n");
    try w.interface.print("  {s}# Write into a non-default env{s}\n", .{ d, r });
    try w.interface.writeAll("  echo \"sk-prod-real\" | envless set OPENAI_API_KEY --env=prod\n\n");
    try w.interface.print("  {s}# Multi-line value via a heredoc{s}\n", .{ d, r });
    try w.interface.writeAll("  envless set PRIVATE_KEY --env=prod <<'EOF'\n");
    try w.interface.writeAll("  -----BEGIN RSA PRIVATE KEY-----\n");
    try w.interface.writeAll("  ...\n");
    try w.interface.writeAll("  -----END RSA PRIVATE KEY-----\n");
    try w.interface.writeAll("  EOF\n\n");

    try w.interface.print("{s}Exit codes:{s}\n", .{ b, r });
    try w.interface.writeAll("  0    secret stored\n");
    try w.interface.writeAll("  1    sops failure, disk error, or unreadable stdin\n");
    try w.interface.writeAll("  2    usage error (missing KEY, bad flag)\n");
    try w.interface.writeAll("  64   no .envless/ found in the current directory tree\n\n");

    try w.interface.print("{s}See also:{s}\n", .{ b, r });
    try w.interface.writeAll("  envless get       print one secret value back (requires --confirm)\n");
    try w.interface.writeAll("  envless list      list keys without exposing values\n");
    try w.interface.writeAll("  envless migrate   bulk-import an existing .env file\n");
    try w.interface.writeAll("  Docs:             https://biliboss.github.io/envless/cli/#envless-set-key\n");
    try w.flush();
}
