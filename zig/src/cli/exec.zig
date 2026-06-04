//! `envless exec [--env=ENV] -- CMD [ARGS...]` — run CMD with secrets injected.

const std = @import("std");
const store = @import("../store.zig");
const execenv = @import("../execenv.zig");
const root = @import("root.zig");

pub fn run(ctx: *root.Context, args: []const []const u8) !u8 {
    // Split args at the first bare "--": everything before is exec's own
    // flags, everything after is the child argv. This matches cobra's
    // behavior (cobra strips the "--" separator and forwards the tail).
    var sep_idx: ?usize = null;
    for (args, 0..) |a, i| {
        if (std.mem.eql(u8, a, "--")) {
            sep_idx = i;
            break;
        }
    }

    const empty_args: []const []const u8 = &.{};
    const exec_flags = if (sep_idx) |i| args[0..i] else args[0..];
    const child_argv: []const []const u8 = if (sep_idx) |i| args[i + 1 ..] else empty_args;

    // -h/--help on exec only counts if it appears before `--` (after which
    // it's part of the child argv and should pass through untouched).
    if (root.wantsHelp(exec_flags)) {
        try printHelp(ctx);
        return 0;
    }

    var rest = std.ArrayList([]const u8).init(ctx.allocator);
    defer rest.deinit();
    const env_opt = try root.popStringFlag(exec_flags, "--env", &rest);
    const env = env_opt orelse "dev";

    if (rest.items.len != 0) {
        try ctx.stderr.writer().writeAll("envless: exec: unexpected positional args before --\n");
        try ctx.stderr.writer().writeAll("Run `envless exec -h` for help.\n");
        return 2;
    }
    if (child_argv.len == 0) {
        try ctx.stderr.writer().writeAll("envless: exec: missing command\n");
        try ctx.stderr.writer().writeAll("Run `envless exec -h` for help.\n");
        return 2;
    }

    const s = store.Store.init(ctx.allocator, ctx.cwd);
    var kv_result = s.read(env) catch |err| {
        try ctx.stderr.writer().print("envless: exec: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer kv_result.deinit();

    // Build child env: merge parent env + secrets.
    // Materialize parent env into a []const []const u8 slice.
    var env_map = std.process.getEnvMap(ctx.allocator) catch return 1;
    defer env_map.deinit();

    var parent_entries = std.ArrayList([]u8).init(ctx.allocator);
    defer {
        for (parent_entries.items) |s2| ctx.allocator.free(s2);
        parent_entries.deinit();
    }
    {
        var it = env_map.iterator();
        while (it.next()) |e| {
            const k = e.key_ptr.*;
            const v = e.value_ptr.*;
            const buf = try ctx.allocator.alloc(u8, k.len + 1 + v.len);
            @memcpy(buf[0..k.len], k);
            buf[k.len] = '=';
            @memcpy(buf[k.len + 1 ..], v);
            try parent_entries.append(buf);
        }
    }
    var parent_view = try ctx.allocator.alloc([]const u8, parent_entries.items.len);
    defer ctx.allocator.free(parent_view);
    for (parent_entries.items, 0..) |p, i| parent_view[i] = p;

    const child_env = try execenv.buildEnv(ctx.allocator, parent_view, kv_result.inner);
    defer execenv.freeEnv(ctx.allocator, child_env);

    // Run child, inheriting stdin/stdout/stderr (so the child can read user
    // input, write output, etc).
    const res = execenv.run(
        ctx.allocator,
        child_argv,
        child_env,
        ctx.stdin,
        ctx.stdout,
        ctx.stderr,
    ) catch |err| {
        try ctx.stderr.writer().print("envless: exec: {s}\n", .{@errorName(err)});
        return 1;
    };
    return switch (res) {
        .success => 0,
        .non_zero => |code| code,
    };
}

fn printHelp(ctx: *root.Context) !void {
    const w = ctx.stdout.writer();
    const s = root.Style.fromFile(ctx.stdout);
    const b = s.bold();
    const d = s.dim();
    const r = s.reset();

    try w.print("envless exec {s}— run a command with secrets injected{s}\n\n", .{ d, r });

    try w.print("{s}Usage:{s}\n", .{ b, r });
    try w.writeAll("  envless exec [--env=NAME] -- CMD [ARGS...]\n\n");

    try w.print("{s}Description:{s}\n", .{ b, r });
    try w.writeAll("  Decrypts secrets/<env>.env.enc, merges into the parent's environment\n");
    try w.writeAll("  (overriding any matching parent keys), then execs CMD with that env.\n");
    try w.writeAll("  Secrets are passed to the child via the env array — never via argv,\n");
    try w.writeAll("  never via stdout. The child inherits stdin/stdout/stderr; its exit\n");
    try w.writeAll("  code is propagated as envless's exit code.\n\n");

    try w.print("{s}Flags:{s}\n", .{ b, r });
    try w.writeAll("  --env=NAME      environment to load (default: dev)\n");
    try w.writeAll("  -h, --help      show this help (only if it appears before `--`)\n\n");

    try w.print("{s}Examples:{s}\n", .{ b, r });
    try w.print("  {s}# Run a Node app with secrets injected{s}\n", .{ d, r });
    try w.writeAll("  envless exec --env=dev -- node server.js\n\n");
    try w.print("  {s}# One-off curl with secrets in the env{s}\n", .{ d, r });
    try w.writeAll("  envless exec --env=prod -- sh -c 'curl -H \"Authorization: Bearer $TOKEN\" https://api'\n\n");
    try w.print("  {s}# Pass extra env to the child by setting it before the call{s}\n", .{ d, r });
    try w.writeAll("  CUSTOM_FLAG=1 envless exec --env=dev -- ./script.sh\n\n");

    try w.print("{s}Exit codes:{s}\n", .{ b, r });
    try w.writeAll("  0    child process exited 0\n");
    try w.writeAll("  N    child process exited N (propagated)\n");
    try w.writeAll("  2    usage error (missing `--`, no command)\n");
    try w.writeAll("  64   no .envless/ found\n");
    try w.writeAll("  65   corrupt sops file\n");
    try w.writeAll("  66   env not found\n");
    try w.writeAll("  74   exec failure (binary not on PATH, permission denied)\n\n");

    try w.print("{s}See also:{s}\n", .{ b, r });
    try w.writeAll("  envless list      list keys without exposing values\n");
    try w.writeAll("  envless get       print one secret value\n");
    try w.writeAll("  Docs:             https://biliboss.github.io/envless/cli/#envless-exec-env-env-cmd-args\n");
}
