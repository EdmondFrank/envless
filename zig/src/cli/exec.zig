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

    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(ctx.allocator);
    const env_opt = try root.popStringFlag(ctx.allocator, exec_flags, "--env", &rest);
    const env = env_opt orelse "dev";

    if (rest.items.len != 0) {
        try ctx.errWriteAll("envless: exec: unexpected positional args before --\n");
        try ctx.errWriteAll("Run `envless exec -h` for help.\n");
        return 2;
    }
    if (child_argv.len == 0) {
        try ctx.errWriteAll("envless: exec: missing command\n");
        try ctx.errWriteAll("Run `envless exec -h` for help.\n");
        return 2;
    }

    const s = store.Store.init(ctx.allocator, ctx.io, ctx.cwd);
    var kv_result = s.read(env) catch |err| {
        try ctx.errPrint("envless: exec: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer kv_result.deinit();

    // Build child env: merge parent env + secrets.
    // Materialize parent env into a []const []const u8 slice.
    // std.process.getEnvMap was removed in 0.16; iterate std.c.environ directly.
    var parent_entries: std.ArrayList([]u8) = .empty;
    defer {
        for (parent_entries.items) |s2| ctx.allocator.free(s2);
        parent_entries.deinit(ctx.allocator);
    }
    {
        var i: usize = 0;
        while (std.c.environ[i]) |entry_ptr| : (i += 1) {
            const entry = std.mem.span(entry_ptr);
            const buf = try ctx.allocator.alloc(u8, entry.len);
            @memcpy(buf, entry);
            try parent_entries.append(ctx.allocator, buf);
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
        ctx.io,
        child_argv,
        child_env,
        ctx.stdin,
        ctx.stdout,
        ctx.stderr,
    ) catch |err| {
        try ctx.errPrint("envless: exec: {s}\n", .{@errorName(err)});
        return 1;
    };
    return switch (res) {
        .success => 0,
        .non_zero => |code| code,
    };
}

fn printHelp(ctx: *root.Context) !void {
    var w = ctx.stdoutWriter();
    const s = try root.Style.fromFile(ctx.io, ctx.stdout);
    const b = s.bold();
    const d = s.dim();
    const r = s.reset();

    try w.interface.print("envless exec {s}— run a command with secrets injected{s}\n\n", .{ d, r });

    try w.interface.print("{s}Usage:{s}\n", .{ b, r });
    try w.interface.writeAll("  envless exec [--env=NAME] -- CMD [ARGS...]\n\n");

    try w.interface.print("{s}Description:{s}\n", .{ b, r });
    try w.interface.writeAll("  Decrypts secrets/<env>.env.enc, merges into the parent's environment\n");
    try w.interface.writeAll("  (overriding any matching parent keys), then execs CMD with that env.\n");
    try w.interface.writeAll("  Secrets are passed to the child via the env array — never via argv,\n");
    try w.interface.writeAll("  never via stdout. The child inherits stdin/stdout/stderr; its exit\n");
    try w.interface.writeAll("  code is propagated as envless's exit code.\n\n");

    try w.interface.print("{s}Flags:{s}\n", .{ b, r });
    try w.interface.writeAll("  --env=NAME      environment to load (default: dev)\n");
    try w.interface.writeAll("  -h, --help      show this help (only if it appears before `--`)\n\n");

    try w.interface.print("{s}Examples:{s}\n", .{ b, r });
    try w.interface.print("  {s}# Run a Node app with secrets injected{s}\n", .{ d, r });
    try w.interface.writeAll("  envless exec --env=dev -- node server.js\n\n");
    try w.interface.print("  {s}# One-off curl with secrets in the env{s}\n", .{ d, r });
    try w.interface.writeAll("  envless exec --env=prod -- sh -c 'curl -H \"Authorization: Bearer $TOKEN\" https://api'\n\n");
    try w.interface.print("  {s}# Pass extra env to the child by setting it before the call{s}\n", .{ d, r });
    try w.interface.writeAll("  CUSTOM_FLAG=1 envless exec --env=dev -- ./script.sh\n\n");

    try w.interface.print("{s}Exit codes:{s}\n", .{ b, r });
    try w.interface.writeAll("  0    child process exited 0\n");
    try w.interface.writeAll("  N    child process exited N (propagated)\n");
    try w.interface.writeAll("  2    usage error (missing `--`, no command)\n");
    try w.interface.writeAll("  64   no .envless/ found\n");
    try w.interface.writeAll("  65   corrupt sops file\n");
    try w.interface.writeAll("  66   env not found\n");
    try w.interface.writeAll("  74   exec failure (binary not on PATH, permission denied)\n\n");

    try w.interface.print("{s}See also:{s}\n", .{ b, r });
    try w.interface.writeAll("  envless list      list keys without exposing values\n");
    try w.interface.writeAll("  envless get       print one secret value\n");
    try w.interface.writeAll("  Docs:             https://biliboss.github.io/envless/cli/#envless-exec-env-env-cmd-args\n");
    try w.flush();
}
