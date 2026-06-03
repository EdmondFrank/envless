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

    var rest = std.ArrayList([]const u8).init(ctx.allocator);
    defer rest.deinit();
    const env_opt = try root.popStringFlag(exec_flags, "--env", &rest);
    const env = env_opt orelse "dev";

    if (rest.items.len != 0) {
        try ctx.stderr.writer().writeAll("envless: exec: unexpected positional args before --\n");
        return 1;
    }
    if (child_argv.len == 0) {
        try ctx.stderr.writer().writeAll("envless: exec: missing command\n");
        return 1;
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
