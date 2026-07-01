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
    var after_env: std.ArrayList([]const u8) = .empty;
    defer after_env.deinit(ctx.allocator);
    const env_opt = try root.popStringFlag(ctx.allocator, args, "--env", &after_env);
    const env = env_opt orelse "dev";

    // Pop --keep.
    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(ctx.allocator);
    const keep = try root.popBoolFlag(ctx.allocator, after_env.items, "--keep", &rest);

    if (rest.items.len != 1) {
        try ctx.errWriteAll("envless: migrate requires exactly one FILE argument\n");
        try ctx.errWriteAll("Run `envless migrate -h` for help.\n");
        return 2;
    }
    const src = rest.items[0];

    const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, src, ctx.allocator, .limited(16 * 1024 * 1024)) catch |err| {
        try ctx.errPrint("envless: read {s}: {s}\n", .{ src, @errorName(err) });
        return 1;
    };
    defer ctx.allocator.free(data);

    const entries = envparse.parse(ctx.allocator, data) catch |err| {
        try ctx.errPrint("envless: parse {s}: {s}\n", .{ src, @errorName(err) });
        return 1;
    };
    defer envparse.freeEntries(ctx.allocator, entries);

    const s = store.Store.init(ctx.allocator, ctx.io, ctx.cwd);

    // Read existing (preserves keys for the target env).
    var existing = s.read(env) catch |err| {
        try ctx.errPrint("envless: read {s}: {s}\n", .{ env, @errorName(err) });
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
        try ctx.errPrint("envless: write: {s}\n", .{@errorName(err)});
        return 1;
    };

    const pattern = std.fs.path.basename(src);
    const gi_path = try std.fs.path.join(ctx.allocator, &.{ ctx.cwd, ".gitignore" });
    defer ctx.allocator.free(gi_path);
    appendGitignore(ctx.io, ctx.allocator, gi_path, pattern) catch |err| {
        try ctx.errPrint("envless: .gitignore: {s}\n", .{@errorName(err)});
        return 1;
    };

    try ctx.outPrint("MIGRATE  src={s} env={s} keys={d}\n", .{ src, env, entries.len });

    if (!keep) {
        std.Io.Dir.cwd().deleteFile(ctx.io, src) catch |err| {
            try ctx.errPrint("envless: remove {s}: {s}\n", .{ src, @errorName(err) });
            return 1;
        };
        try ctx.outPrint("REMOVE   {s}\n", .{src});
    }
    return 0;
}

fn printHelp(ctx: *root.Context) !void {
    var w = ctx.stdoutWriter();
    const s = try root.Style.fromFile(ctx.io, ctx.stdout);
    const b = s.bold();
    const d = s.dim();
    const r = s.reset();

    try w.interface.print("envless migrate {s}— encrypt a .env file into envless{s}\n\n", .{ d, r });

    try w.interface.print("{s}Usage:{s}\n", .{ b, r });
    try w.interface.writeAll("  envless migrate FILE [--env=NAME] [--keep]\n\n");

    try w.interface.print("{s}Description:{s}\n", .{ b, r });
    try w.interface.writeAll("  Parses FILE as dotenv syntax, merges every KEY=VALUE into\n");
    try w.interface.writeAll("  secrets/<env>.env.enc (existing keys are overwritten), adds the\n");
    try w.interface.writeAll("  file's basename to .gitignore, and then deletes the plaintext\n");
    try w.interface.writeAll("  source. Pass --keep to retain the original file for verification.\n\n");

    try w.interface.print("{s}Flags:{s}\n", .{ b, r });
    try w.interface.writeAll("  --env=NAME      environment to write into (default: dev)\n");
    try w.interface.writeAll("  --keep          do not delete the plaintext source after import\n");
    try w.interface.writeAll("  -h, --help      show this help\n\n");

    try w.interface.print("{s}Examples:{s}\n", .{ b, r });
    try w.interface.print("  {s}# One-shot migration: import .env into dev and delete the source{s}\n", .{ d, r });
    try w.interface.writeAll("  envless migrate .env\n\n");
    try w.interface.print("  {s}# Migrate a staging-specific dotenv but keep the plaintext to verify{s}\n", .{ d, r });
    try w.interface.writeAll("  envless migrate .env.staging --env=staging --keep\n\n");

    try w.interface.print("{s}Exit codes:{s}\n", .{ b, r });
    try w.interface.writeAll("  0    keys imported, .gitignore updated, plaintext removed (unless --keep)\n");
    try w.interface.writeAll("  1    parse error, sops failure, or filesystem error\n");
    try w.interface.writeAll("  2    usage error (missing FILE, bad flag)\n");
    try w.interface.writeAll("  64   no .envless/ found\n");
    try w.interface.writeAll("  74   could not delete the plaintext source\n\n");

    try w.interface.print("{s}See also:{s}\n", .{ b, r });
    try w.interface.writeAll("  envless set       set individual keys without bulk-importing\n");
    try w.interface.writeAll("  envless list      verify the imported key set\n");
    try w.interface.writeAll("  Docs:             https://biliboss.github.io/envless/cli/#envless-migrate-file\n");
    try w.flush();
}

/// appendGitignore: idempotent — only appends `pattern\n` if it's not already
/// a standalone line in the file. Adds a leading newline if needed.
fn appendGitignore(io: std.Io, allocator: std.mem.Allocator, path: []const u8, pattern: []const u8) !void {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
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
    var out_buf: std.ArrayList(u8) = .empty;
    defer out_buf.deinit(allocator);
    try out_buf.appendSlice(allocator, data);
    if (data.len > 0 and data[data.len - 1] != '\n') try out_buf.append(allocator, '\n');
    try out_buf.appendSlice(allocator, pattern);
    try out_buf.append(allocator, '\n');

    var f = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    var write_buf: [4096]u8 = undefined;
    var fw = f.writer(io, &write_buf);
    try fw.interface.writeAll(out_buf.items);
    try fw.flush();
}

// ----------------------------- tests -----------------------------------------

const testing = std.testing;

test "appendGitignore creates file and writes pattern" {
    const a = testing.allocator;
    const io = std.testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var _path_buf: [4096]u8 = undefined;
    const _path_len = try tmp.dir.realPath(io, &_path_buf);
    const tmp_path = try a.dupe(u8, _path_buf[0.._path_len]);
    defer a.free(tmp_path);
    const gi = try std.fs.path.join(a, &.{ tmp_path, ".gitignore" });
    defer a.free(gi);
    try appendGitignore(io, a, gi, ".env");
    const out = try tmp.dir.readFileAlloc(io, ".gitignore", a, .limited(1024));
    defer a.free(out);
    try testing.expectEqualStrings(".env\n", out);
}

test "appendGitignore is idempotent" {
    const a = testing.allocator;
    const io = std.testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var _path_buf: [4096]u8 = undefined;
    const _path_len = try tmp.dir.realPath(io, &_path_buf);
    const tmp_path = try a.dupe(u8, _path_buf[0.._path_len]);
    defer a.free(tmp_path);
    const gi = try std.fs.path.join(a, &.{ tmp_path, ".gitignore" });
    defer a.free(gi);
    try appendGitignore(io, a, gi, ".env");
    try appendGitignore(io, a, gi, ".env");
    const out = try tmp.dir.readFileAlloc(io, ".gitignore", a, .limited(1024));
    defer a.free(out);
    try testing.expectEqualStrings(".env\n", out);
}

test "appendGitignore adds newline if file lacks trailing newline" {
    const a = testing.allocator;
    const io = std.testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var _path_buf: [4096]u8 = undefined;
    const _path_len = try tmp.dir.realPath(io, &_path_buf);
    const tmp_path = try a.dupe(u8, _path_buf[0.._path_len]);
    defer a.free(tmp_path);
    const gi = try std.fs.path.join(a, &.{ tmp_path, ".gitignore" });
    defer a.free(gi);
    {
        var f = try tmp.dir.createFile(io, ".gitignore", .{ .truncate = true });
        defer f.close(io);
        var w_buf: [256]u8 = undefined;
        var fw = f.writer(io, &w_buf);
        try fw.interface.writeAll("node_modules");
        try fw.flush();
    }
    try appendGitignore(io, a, gi, ".env");
    const out = try tmp.dir.readFileAlloc(io, ".gitignore", a, .limited(1024));
    defer a.free(out);
    try testing.expectEqualStrings("node_modules\n.env\n", out);
}
