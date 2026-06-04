//! `envless migrate FILE` — read a .env, encrypt into envless, gitignore plaintext.

const std = @import("std");
const store = @import("../store.zig");
const envparse = @import("../envparse.zig");
const root = @import("root.zig");

pub fn run(ctx: *root.Context, args: []const []const u8) !u8 {
    if (root.wantsHelp(args)) {
        try printHelp(ctx);
        return 0;
    }

    // Pop --env first.
    var after_env = std.ArrayList([]const u8).init(ctx.allocator);
    defer after_env.deinit();
    const env_opt = try root.popStringFlag(args, "--env", &after_env);
    const env = env_opt orelse "dev";

    // Pop --keep.
    var rest = std.ArrayList([]const u8).init(ctx.allocator);
    defer rest.deinit();
    const keep = try root.popBoolFlag(after_env.items, "--keep", &rest);

    if (rest.items.len != 1) {
        try ctx.stderr.writer().writeAll("envless: migrate requires exactly one FILE argument\n");
        try ctx.stderr.writer().writeAll("Run `envless migrate -h` for help.\n");
        return 2;
    }
    const src = rest.items[0];

    const data = std.fs.cwd().readFileAlloc(ctx.allocator, src, 16 * 1024 * 1024) catch |err| {
        try ctx.stderr.writer().print("envless: read {s}: {s}\n", .{ src, @errorName(err) });
        return 1;
    };
    defer ctx.allocator.free(data);

    const entries = envparse.parse(ctx.allocator, data) catch |err| {
        try ctx.stderr.writer().print("envless: parse {s}: {s}\n", .{ src, @errorName(err) });
        return 1;
    };
    defer envparse.freeEntries(ctx.allocator, entries);

    const s = store.Store.init(ctx.allocator, ctx.cwd);

    // Read existing (preserves keys for the target env).
    var existing = s.read(env) catch |err| {
        try ctx.stderr.writer().print("envless: read {s}: {s}\n", .{ env, @errorName(err) });
        return 1;
    };
    defer existing.deinit();

    // Merge entries into existing (existing took ownership of its strings;
    // overwriting an entry frees the old strings).
    for (entries) |e| {
        const k_dup = try ctx.allocator.dupe(u8, e.key);
        const v_dup = try ctx.allocator.dupe(u8, e.value);
        if (existing.inner.fetchRemove(e.key)) |old| {
            ctx.allocator.free(old.key);
            ctx.allocator.free(old.value);
        }
        try existing.inner.put(k_dup, v_dup);
    }

    s.write(env, existing.inner) catch |err| {
        try ctx.stderr.writer().print("envless: write: {s}\n", .{@errorName(err)});
        return 1;
    };

    const pattern = std.fs.path.basename(src);
    const gi_path = try std.fs.path.join(ctx.allocator, &.{ ctx.cwd, ".gitignore" });
    defer ctx.allocator.free(gi_path);
    appendGitignore(ctx.allocator, gi_path, pattern) catch |err| {
        try ctx.stderr.writer().print("envless: .gitignore: {s}\n", .{@errorName(err)});
        return 1;
    };

    try ctx.stdout.writer().print("MIGRATE  src={s} env={s} keys={d}\n", .{ src, env, entries.len });

    if (!keep) {
        std.fs.cwd().deleteFile(src) catch |err| {
            try ctx.stderr.writer().print("envless: remove {s}: {s}\n", .{ src, @errorName(err) });
            return 1;
        };
        try ctx.stdout.writer().print("REMOVE   {s}\n", .{src});
    }
    return 0;
}

fn printHelp(ctx: *root.Context) !void {
    const w = ctx.stdout.writer();
    const s = root.Style.fromFile(ctx.stdout);
    const b = s.bold();
    const d = s.dim();
    const r = s.reset();

    try w.print("envless migrate {s}— encrypt a .env file into envless{s}\n\n", .{ d, r });

    try w.print("{s}Usage:{s}\n", .{ b, r });
    try w.writeAll("  envless migrate FILE [--env=NAME] [--keep]\n\n");

    try w.print("{s}Description:{s}\n", .{ b, r });
    try w.writeAll("  Parses FILE as dotenv syntax, merges every KEY=VALUE into\n");
    try w.writeAll("  secrets/<env>.env.enc (existing keys are overwritten), adds the\n");
    try w.writeAll("  file's basename to .gitignore, and then deletes the plaintext\n");
    try w.writeAll("  source. Pass --keep to retain the original file for verification.\n\n");

    try w.print("{s}Flags:{s}\n", .{ b, r });
    try w.writeAll("  --env=NAME      environment to write into (default: dev)\n");
    try w.writeAll("  --keep          do not delete the plaintext source after import\n");
    try w.writeAll("  -h, --help      show this help\n\n");

    try w.print("{s}Examples:{s}\n", .{ b, r });
    try w.print("  {s}# One-shot migration: import .env into dev and delete the source{s}\n", .{ d, r });
    try w.writeAll("  envless migrate .env\n\n");
    try w.print("  {s}# Migrate a staging-specific dotenv but keep the plaintext to verify{s}\n", .{ d, r });
    try w.writeAll("  envless migrate .env.staging --env=staging --keep\n\n");

    try w.print("{s}Exit codes:{s}\n", .{ b, r });
    try w.writeAll("  0    keys imported, .gitignore updated, plaintext removed (unless --keep)\n");
    try w.writeAll("  1    parse error, sops failure, or filesystem error\n");
    try w.writeAll("  2    usage error (missing FILE, bad flag)\n");
    try w.writeAll("  64   no .envless/ found\n");
    try w.writeAll("  74   could not delete the plaintext source\n\n");

    try w.print("{s}See also:{s}\n", .{ b, r });
    try w.writeAll("  envless set       set individual keys without bulk-importing\n");
    try w.writeAll("  envless list      verify the imported key set\n");
    try w.writeAll("  Docs:             https://biliboss.github.io/envless/cli/#envless-migrate-file\n");
}

/// appendGitignore: idempotent — only appends `pattern\n` if it's not already
/// a standalone line in the file. Adds a leading newline if needed.
fn appendGitignore(allocator: std.mem.Allocator, path: []const u8, pattern: []const u8) !void {
    const data = std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => &[_]u8{},
        else => return err,
    };
    // We need to detect whether `data` was a successful read or the empty
    // fallback so we know whether to free it.
    const was_read = data.len > 0;
    defer if (was_read) allocator.free(data);

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.eql(u8, line, pattern)) return; // already present
    }

    // Append (with a leading newline if the file is non-empty and lacks one).
    var out_buf = std.ArrayList(u8).init(allocator);
    defer out_buf.deinit();
    try out_buf.appendSlice(data);
    if (data.len > 0 and data[data.len - 1] != '\n') try out_buf.append('\n');
    try out_buf.appendSlice(pattern);
    try out_buf.append('\n');

    var f = try std.fs.cwd().createFile(path, .{ .truncate = true, .mode = 0o644 });
    defer f.close();
    try f.writeAll(out_buf.items);
}

// ----------------------------- tests -----------------------------------------

const testing = std.testing;

test "appendGitignore creates file and writes pattern" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(tmp_path);
    const gi = try std.fs.path.join(a, &.{ tmp_path, ".gitignore" });
    defer a.free(gi);
    try appendGitignore(a, gi, ".env");
    const out = try tmp.dir.readFileAlloc(a, ".gitignore", 1024);
    defer a.free(out);
    try testing.expectEqualStrings(".env\n", out);
}

test "appendGitignore is idempotent" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(tmp_path);
    const gi = try std.fs.path.join(a, &.{ tmp_path, ".gitignore" });
    defer a.free(gi);
    try appendGitignore(a, gi, ".env");
    try appendGitignore(a, gi, ".env");
    const out = try tmp.dir.readFileAlloc(a, ".gitignore", 1024);
    defer a.free(out);
    try testing.expectEqualStrings(".env\n", out);
}

test "appendGitignore adds newline if file lacks trailing newline" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(tmp_path);
    const gi = try std.fs.path.join(a, &.{ tmp_path, ".gitignore" });
    defer a.free(gi);
    {
        var f = try tmp.dir.createFile(".gitignore", .{ .truncate = true });
        defer f.close();
        try f.writeAll("node_modules");
    }
    try appendGitignore(a, gi, ".env");
    const out = try tmp.dir.readFileAlloc(a, ".gitignore", 1024);
    defer a.free(out);
    try testing.expectEqualStrings("node_modules\n.env\n", out);
}
