//! `envless get KEY --confirm` — print a secret value (refuses without --confirm).

const std = @import("std");
const store = @import("../store.zig");
const root = @import("root.zig");

pub fn run(ctx: *root.Context, args: []const []const u8) !u8 {
    if (root.wantsHelp(args)) {
        try printHelp(ctx);
        return 0;
    }

    var rest_after_env: std.ArrayList([]const u8) = .empty;
    defer rest_after_env.deinit(ctx.allocator);
    const env_opt = try root.popStringFlag(ctx.allocator, args, "--env", &rest_after_env);
    const env = env_opt orelse "dev";

    var rest_after_pass: std.ArrayList([]const u8) = .empty;
    defer rest_after_pass.deinit(ctx.allocator);
    const pass_opt = try root.popStringFlag(ctx.allocator, rest_after_env.items, "--pass", &rest_after_pass);

    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(ctx.allocator);
    const confirm = try root.popBoolFlag(ctx.allocator, rest_after_pass.items, "--confirm", &rest);

    if (!confirm) {
        try ctx.errWriteAll("envless: printing a secret requires --confirm\n");
        return 1;
    }
    if (rest.items.len != 1) {
        try ctx.errWriteAll("envless: get requires exactly one KEY argument\n");
        try ctx.errWriteAll("Run `envless get -h` for help.\n");
        return 2;
    }
    const key = rest.items[0];

    const s = store.Store.init(ctx.allocator, ctx.io, ctx.cwd);
    var r = s.get(env, key) catch |err| {
        try ctx.errPrint("envless: get: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer r.deinit();

    if (!r.found) {
        try ctx.errPrint("envless: key \"{s}\" not found in env \"{s}\"\n", .{ key, env });
        return 1;
    }

    // Safety gate: if ENVLESS_PASS_TOKEN is set in this env's secrets,
    // the caller must provide --pass=<token> matching it.
    if (r.map.inner.get("ENVLESS_PASS_TOKEN")) |pass_token| {
        if (pass_opt) |provided| {
            if (!std.mem.eql(u8, provided, pass_token)) {
                try ctx.errWriteAll("envless: pass token mismatch\n");
                return 1;
            }
        } else {
            try ctx.errWriteAll("envless: this env requires a pass token (ENVLESS_PASS_TOKEN is set); use --pass=<token>\n");
            return 1;
        }
    }

    try ctx.outPrint("{s}\n", .{r.value});
    return 0;
}

fn printHelp(ctx: *root.Context) !void {
    var w = ctx.stdoutWriter();
    const s = try root.Style.fromFile(ctx.io, ctx.stdout);
    const b = s.bold();
    const d = s.dim();
    const r = s.reset();

    try w.interface.print("envless get {s}— print a secret value (requires --confirm){s}\n\n", .{ d, r });

    try w.interface.print("{s}Usage:{s}\n", .{ b, r });
    try w.interface.writeAll("  envless get KEY --confirm [--env=NAME] [--pass=TOKEN]\n\n");

    try w.interface.print("{s}Description:{s}\n", .{ b, r });
    try w.interface.writeAll("  Decrypts secrets/<env>.env.enc and prints the value of KEY to stdout.\n");
    try w.interface.writeAll("  Refuses to run without --confirm — printing a secret value should be a\n");
    try w.interface.writeAll("  deliberate, audit-trail-worthy action. For piping secrets into other\n");
    try w.interface.writeAll("  programs, prefer `envless exec` so the value never touches a TTY or\n");
    try w.interface.writeAll("  intermediate file.\n\n");

    try w.interface.print("{s}Flags:{s}\n", .{ b, r });
    try w.interface.writeAll("  --env=NAME      environment to read from (default: dev)\n");
    try w.interface.writeAll("  --confirm       acknowledge that a secret will be printed (required)\n");
    try w.interface.writeAll("  --pass=TOKEN    pass token (required when ENVLESS_PASS_TOKEN is set in the env)\n");
    try w.interface.writeAll("  -h, --help      show this help\n\n");

    try w.interface.print("{s}Examples:{s}\n", .{ b, r });
    try w.interface.print("  {s}# Reveal a secret on demand{s}\n", .{ d, r });
    try w.interface.writeAll("  envless get OPENAI_API_KEY --confirm\n\n");
    try w.interface.print("  {s}# Inspect a value in a non-default env{s}\n", .{ d, r });
    try w.interface.writeAll("  envless get DATABASE_URL --env=staging --confirm\n\n");
    try w.interface.print("  {s}# Copy into the clipboard without echoing to the terminal{s}\n", .{ d, r });
    try w.interface.writeAll("  envless get GITHUB_TOKEN --confirm | pbcopy\n\n");
    try w.interface.print("  {s}# Reveal a secret when ENVLESS_PASS_TOKEN is set{s}\n", .{ d, r });
    try w.interface.writeAll("  envless get DATABASE_URL --confirm --pass=my-secret-token\n\n");

    try w.interface.print("{s}Exit codes:{s}\n", .{ b, r });
    try w.interface.writeAll("  0    value printed\n");
    try w.interface.writeAll("  1    sops decrypt failure, --confirm missing, or pass token mismatch\n");
    try w.interface.writeAll("  2    usage error (missing KEY)\n");
    try w.interface.writeAll("  64   no .envless/ found\n");
    try w.interface.writeAll("  66   KEY not present in the selected env\n\n");

    try w.interface.print("{s}See also:{s}\n", .{ b, r });
    try w.interface.writeAll("  envless list      list keys without exposing values\n");
    try w.interface.writeAll("  envless exec      run a child process with secrets in its env\n");
    try w.interface.writeAll("  Docs:             https://biliboss.github.io/envless/cli/#envless-get-key\n");
    try w.flush();
}
