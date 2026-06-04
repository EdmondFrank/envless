//! `envless get KEY --confirm` — print a secret value (refuses without --confirm).

const std = @import("std");
const store = @import("../store.zig");
const root = @import("root.zig");

pub fn run(ctx: *root.Context, args: []const []const u8) !u8 {
    if (root.wantsHelp(args)) {
        try printHelp(ctx);
        return 0;
    }

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
        try ctx.stderr.writer().writeAll("Run `envless get -h` for help.\n");
        return 2;
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

fn printHelp(ctx: *root.Context) !void {
    const w = ctx.stdout.writer();
    const s = root.Style.fromFile(ctx.stdout);
    const b = s.bold();
    const d = s.dim();
    const r = s.reset();

    try w.print("envless get {s}— print a secret value (requires --confirm){s}\n\n", .{ d, r });

    try w.print("{s}Usage:{s}\n", .{ b, r });
    try w.writeAll("  envless get KEY --confirm [--env=NAME]\n\n");

    try w.print("{s}Description:{s}\n", .{ b, r });
    try w.writeAll("  Decrypts secrets/<env>.env.enc and prints the value of KEY to stdout.\n");
    try w.writeAll("  Refuses to run without --confirm — printing a secret value should be a\n");
    try w.writeAll("  deliberate, audit-trail-worthy action. For piping secrets into other\n");
    try w.writeAll("  programs, prefer `envless exec` so the value never touches a TTY or\n");
    try w.writeAll("  intermediate file.\n\n");

    try w.print("{s}Flags:{s}\n", .{ b, r });
    try w.writeAll("  --env=NAME      environment to read from (default: dev)\n");
    try w.writeAll("  --confirm       acknowledge that a secret will be printed (required)\n");
    try w.writeAll("  -h, --help      show this help\n\n");

    try w.print("{s}Examples:{s}\n", .{ b, r });
    try w.print("  {s}# Reveal a secret on demand{s}\n", .{ d, r });
    try w.writeAll("  envless get OPENAI_API_KEY --confirm\n\n");
    try w.print("  {s}# Inspect a value in a non-default env{s}\n", .{ d, r });
    try w.writeAll("  envless get DATABASE_URL --env=staging --confirm\n\n");
    try w.print("  {s}# Copy into the clipboard without echoing to the terminal{s}\n", .{ d, r });
    try w.writeAll("  envless get GITHUB_TOKEN --confirm | pbcopy\n\n");

    try w.print("{s}Exit codes:{s}\n", .{ b, r });
    try w.writeAll("  0    value printed\n");
    try w.writeAll("  1    sops decrypt failure or --confirm missing\n");
    try w.writeAll("  2    usage error (missing KEY)\n");
    try w.writeAll("  64   no .envless/ found\n");
    try w.writeAll("  66   KEY not present in the selected env\n\n");

    try w.print("{s}See also:{s}\n", .{ b, r });
    try w.writeAll("  envless list      list keys without exposing values\n");
    try w.writeAll("  envless exec      run a child process with secrets in its env\n");
    try w.writeAll("  Docs:             https://biliboss.github.io/envless/cli/#envless-get-key\n");
}
