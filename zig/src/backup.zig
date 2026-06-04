//! backup: assemble a tar.gz of envless state (recipients + encrypted secrets,
//! optionally the identity key) plus a MANIFEST.json describing the archive.
//!
//! Design notes:
//!   - We shell out to system `tar` for the actual archive. The Zig 0.13 stdlib
//!     has neither a tar writer nor a gzip writer that's nice to use; system
//!     tar is portable across macOS/Linux, supports --format=ustar + gzip in
//!     one call, and matches the pattern already used by `zig build release`.
//!   - The manifest is a small JSON document we render by hand to keep tight
//!     control over field order (so the on-disk shape is stable for diffs).
//!   - Repo-root resolution walks up from `start_dir` looking for
//!     `.envless/identity.key`. We don't accept the `.envless/` dir alone as
//!     proof — the identity file is the canonical marker (matches the rest of
//!     the codebase, which always reads the identity in lock-step with the
//!     recipients file).

const std = @import("std");
const store_mod = @import("store.zig");

pub const Error = error{
    NoEnvlessRoot,
    StageFailed,
    TarFailed,
    ManifestFailed,
    IoError,
    OutOfMemory,
};

pub const Options = struct {
    /// Absolute path to the resolved repo root (the dir holding `.envless/`).
    repo_root: []const u8,
    /// envless version string, e.g. "v0.1.0".
    version: []const u8,
    /// Where to write the output. If null or "-", written to stdout via a
    /// system pipe. If a path, written to that file.
    output_path: ?[]const u8,
    /// Whether to include `.envless/identity.key` in the archive.
    include_identity: bool,
};

/// Walk up from `start_dir` until we find a directory containing
/// `.envless/identity.key`. Returns an owned absolute path on success.
pub fn findRepoRoot(allocator: std.mem.Allocator, start_dir: []const u8) Error![]u8 {
    // Realpath the start_dir so we walk an absolute path. This also catches
    // the case where start_dir doesn't exist.
    var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const abs = std.fs.realpath(start_dir, &buf) catch return Error.NoEnvlessRoot;

    var cur = allocator.dupe(u8, abs) catch return Error.OutOfMemory;
    while (true) {
        const candidate = std.fs.path.join(allocator, &.{ cur, ".envless", "identity.key" }) catch {
            allocator.free(cur);
            return Error.OutOfMemory;
        };
        defer allocator.free(candidate);
        if (std.fs.accessAbsolute(candidate, .{})) {
            return cur;
        } else |_| {}

        // Climb one level. If we're at root, give up.
        const parent = std.fs.path.dirname(cur) orelse {
            allocator.free(cur);
            return Error.NoEnvlessRoot;
        };
        if (parent.len == cur.len) {
            // Reached filesystem root.
            allocator.free(cur);
            return Error.NoEnvlessRoot;
        }
        const next = allocator.dupe(u8, parent) catch {
            allocator.free(cur);
            return Error.OutOfMemory;
        };
        allocator.free(cur);
        cur = next;
    }
}

/// Iso8601 timestamp ("YYYY-MM-DDTHH:MM:SSZ") for the manifest. Owned slice.
fn isoTimestamp(allocator: std.mem.Allocator) ![]u8 {
    const epoch_s: u64 = @intCast(std.time.timestamp());
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = epoch_s };
    const day_seconds = epoch_seconds.getDaySeconds();
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

/// List env names by scanning `<root>/secrets/` for `*.env.enc` files.
/// Returns owned slices and an owned outer slice. Sorted lexicographically.
fn listEnvs(allocator: std.mem.Allocator, root: []const u8) Error![][]u8 {
    const secrets_dir = std.fs.path.join(allocator, &.{ root, "secrets" }) catch return Error.OutOfMemory;
    defer allocator.free(secrets_dir);

    var list = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (list.items) |s| allocator.free(s);
        list.deinit();
    }

    var dir = std.fs.openDirAbsolute(secrets_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return list.toOwnedSlice() catch Error.OutOfMemory,
        else => return Error.IoError,
    };
    defer dir.close();

    var it = dir.iterate();
    while (it.next() catch return Error.IoError) |entry| {
        if (entry.kind != .file) continue;
        const suffix = ".env.enc";
        if (entry.name.len <= suffix.len) continue;
        if (!std.mem.endsWith(u8, entry.name, suffix)) continue;
        const env_name = entry.name[0 .. entry.name.len - suffix.len];
        const owned = allocator.dupe(u8, env_name) catch return Error.OutOfMemory;
        list.append(owned) catch return Error.OutOfMemory;
    }

    const slice = list.toOwnedSlice() catch return Error.OutOfMemory;
    std.mem.sort([]u8, slice, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return slice;
}

/// Count files that will be in the tarball: 1 (manifest) + 1 (recipients)
/// + N envs + maybe 1 (identity).
fn countFiles(envs_len: usize, include_identity: bool) usize {
    return 2 + envs_len + (if (include_identity) @as(usize, 1) else 0);
}

/// Write the MANIFEST.json file inside `stage_dir`. Caller passes the resolved
/// pubkey + envs + the chosen include_identity flag.
fn writeManifest(
    allocator: std.mem.Allocator,
    stage_dir: []const u8,
    opts: Options,
    pubkey: []const u8,
    envs: []const []u8,
) !void {
    const created_at = try isoTimestamp(allocator);
    defer allocator.free(created_at);

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    const w = buf.writer();

    try w.writeAll("{\n");
    try w.print("  \"schema_version\": 1,\n", .{});
    try w.print("  \"envless_version\": \"{s}\",\n", .{opts.version});
    try w.print("  \"created_at\": \"{s}\",\n", .{created_at});
    try w.writeAll("  \"repo_root\": ");
    try writeJsonString(w, opts.repo_root);
    try w.writeAll(",\n");
    try w.writeAll("  \"pubkey\": ");
    try writeJsonString(w, pubkey);
    try w.writeAll(",\n");
    try w.print("  \"includes_identity\": {s},\n", .{if (opts.include_identity) "true" else "false"});

    try w.writeAll("  \"envs\": [");
    for (envs, 0..) |env, i| {
        if (i != 0) try w.writeAll(", ");
        try writeJsonString(w, env);
    }
    try w.writeAll("],\n");

    try w.print("  \"file_count\": {d}\n", .{countFiles(envs.len, opts.include_identity)});
    try w.writeAll("}\n");

    const path = try std.fs.path.join(allocator, &.{ stage_dir, "MANIFEST.json" });
    defer allocator.free(path);

    var f = try std.fs.createFileAbsolute(path, .{ .truncate = true, .mode = 0o644 });
    defer f.close();
    try f.writeAll(buf.items);
}

/// Minimal JSON string writer: quote + escape \, ", control chars.
fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => {
            if (c < 0x20) {
                try w.print("\\u{x:0>4}", .{c});
            } else {
                try w.writeByte(c);
            }
        },
    };
    try w.writeByte('"');
}

/// Stage everything into a temp dir, run system tar to bundle it up, then
/// either move to opts.output_path or stream to stdout.
pub fn run(allocator: std.mem.Allocator, opts: Options) Error!void {
    const s = store_mod.Store.init(allocator, opts.repo_root);

    // Resolve pubkey upfront — also validates that identity.key is parseable.
    const pubkey = s.pubKey() catch return Error.IoError;
    defer allocator.free(pubkey);

    // List envs (sorted, empty allowed).
    const envs = try listEnvs(allocator, opts.repo_root);
    defer {
        for (envs) |e| allocator.free(e);
        allocator.free(envs);
    }

    // Build a temp staging dir.
    var stage_seed: u64 = @intCast(std.time.nanoTimestamp() & 0x7fff_ffff_ffff_ffff);
    stage_seed +%= @intFromPtr(&stage_seed);
    var prng = std.Random.DefaultPrng.init(stage_seed);
    const rnd = prng.random().int(u64);

    const tmp_root = std.posix.getenv("TMPDIR") orelse "/tmp";
    const stage_dir = std.fmt.allocPrint(allocator, "{s}/envless-backup-{x}", .{ tmp_root, rnd }) catch return Error.OutOfMemory;
    defer allocator.free(stage_dir);
    std.fs.makeDirAbsolute(stage_dir) catch return Error.StageFailed;
    defer std.fs.deleteTreeAbsolute(stage_dir) catch {};

    // Inside stage_dir, build the desired tree:
    //   .envless/recipients
    //   .envless/identity.key  (only if include_identity)
    //   secrets/<env>.env.enc  (per env)
    //   MANIFEST.json
    {
        const envless_sub = std.fs.path.join(allocator, &.{ stage_dir, ".envless" }) catch return Error.OutOfMemory;
        defer allocator.free(envless_sub);
        std.fs.makeDirAbsolute(envless_sub) catch return Error.StageFailed;
    }
    if (envs.len > 0) {
        const secrets_sub = std.fs.path.join(allocator, &.{ stage_dir, "secrets" }) catch return Error.OutOfMemory;
        defer allocator.free(secrets_sub);
        std.fs.makeDirAbsolute(secrets_sub) catch return Error.StageFailed;
    }

    // Copy recipients.
    {
        const src = std.fs.path.join(allocator, &.{ opts.repo_root, ".envless", "recipients" }) catch return Error.OutOfMemory;
        defer allocator.free(src);
        const dst = std.fs.path.join(allocator, &.{ stage_dir, ".envless", "recipients" }) catch return Error.OutOfMemory;
        defer allocator.free(dst);
        copyFile(src, dst) catch return Error.IoError;
    }

    // Conditionally copy identity.key.
    if (opts.include_identity) {
        const src = std.fs.path.join(allocator, &.{ opts.repo_root, ".envless", "identity.key" }) catch return Error.OutOfMemory;
        defer allocator.free(src);
        const dst = std.fs.path.join(allocator, &.{ stage_dir, ".envless", "identity.key" }) catch return Error.OutOfMemory;
        defer allocator.free(dst);
        copyFile(src, dst) catch return Error.IoError;
        // Preserve 0600.
        chmod600(dst) catch {};
    }

    // Copy each <env>.env.enc.
    for (envs) |env_name| {
        const fname = std.fmt.allocPrint(allocator, "{s}.env.enc", .{env_name}) catch return Error.OutOfMemory;
        defer allocator.free(fname);
        const src = std.fs.path.join(allocator, &.{ opts.repo_root, "secrets", fname }) catch return Error.OutOfMemory;
        defer allocator.free(src);
        const dst = std.fs.path.join(allocator, &.{ stage_dir, "secrets", fname }) catch return Error.OutOfMemory;
        defer allocator.free(dst);
        copyFile(src, dst) catch return Error.IoError;
    }

    // Write the manifest.
    writeManifest(allocator, stage_dir, opts, pubkey, envs) catch return Error.ManifestFailed;

    // Build the list of entries to feed to tar. Use the relative names so the
    // tarball entries are e.g. "MANIFEST.json", ".envless/recipients", etc.
    var members = std.ArrayList([]const u8).init(allocator);
    defer members.deinit();
    members.append("MANIFEST.json") catch return Error.OutOfMemory;
    members.append(".envless/recipients") catch return Error.OutOfMemory;
    if (opts.include_identity) members.append(".envless/identity.key") catch return Error.OutOfMemory;
    // Env names need ".env.enc" suffixes inside the tarball.
    var member_paths = std.ArrayList([]u8).init(allocator);
    defer {
        for (member_paths.items) |p| allocator.free(p);
        member_paths.deinit();
    }
    for (envs) |env_name| {
        const p = std.fmt.allocPrint(allocator, "secrets/{s}.env.enc", .{env_name}) catch return Error.OutOfMemory;
        member_paths.append(p) catch return Error.OutOfMemory;
        members.append(p) catch return Error.OutOfMemory;
    }

    // Invoke tar.
    //
    // Two cases:
    //   - output_path is a real path: `tar --format=ustar -czf <path> -C <stage> <members...>`
    //   - output_path is null / "-": pipe to our stdout via `-czf -`. We inherit
    //     stdout so the bytes flow straight through.
    const want_stdout = (opts.output_path == null) or std.mem.eql(u8, opts.output_path.?, "-");

    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    argv.append("tar") catch return Error.OutOfMemory;
    argv.append("--format=ustar") catch return Error.OutOfMemory;
    argv.append("-czf") catch return Error.OutOfMemory;
    argv.append(if (want_stdout) "-" else opts.output_path.?) catch return Error.OutOfMemory;
    argv.append("-C") catch return Error.OutOfMemory;
    argv.append(stage_dir) catch return Error.OutOfMemory;
    for (members.items) |m| argv.append(m) catch return Error.OutOfMemory;

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = if (want_stdout) .Inherit else .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch return Error.TarFailed;

    // Drain stderr so a tar warning doesn't deadlock.
    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();
    if (child.stderr) |se| {
        se.reader().readAllArrayList(&stderr_buf, 1024 * 1024) catch {};
    }
    if (child.stdout) |so| {
        var dummy = std.ArrayList(u8).init(allocator);
        defer dummy.deinit();
        so.reader().readAllArrayList(&dummy, 1024 * 1024) catch {};
    }

    const term = child.wait() catch return Error.TarFailed;
    switch (term) {
        .Exited => |c| if (c != 0) return Error.TarFailed,
        else => return Error.TarFailed,
    }
}

fn copyFile(src: []const u8, dst: []const u8) !void {
    var sf = try std.fs.openFileAbsolute(src, .{});
    defer sf.close();
    var df = try std.fs.createFileAbsolute(dst, .{ .truncate = true, .mode = 0o644 });
    defer df.close();
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try sf.read(&buf);
        if (n == 0) break;
        try df.writeAll(buf[0..n]);
    }
}

fn chmod600(path: []const u8) !void {
    var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const c_path = try std.fmt.bufPrintZ(&buf, "{s}", .{path});
    const rc = std.c.chmod(c_path.ptr, 0o600);
    if (rc != 0) return error.ChmodFailed;
}

// ----------------------------- tests -----------------------------------------

const testing = std.testing;

test "findRepoRoot returns dir holding .envless/identity.key" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    // Fake the marker.
    try tmp.dir.makePath(".envless");
    {
        var f = try tmp.dir.createFile(".envless/identity.key", .{});
        defer f.close();
        try f.writeAll("# created\n# public key: age1xyz\nAGE-SECRET-KEY-1FAKE\n");
    }

    // Make a nested subdir and resolve from there.
    try tmp.dir.makePath("sub/deep");
    const start = try std.fs.path.join(a, &.{ root, "sub", "deep" });
    defer a.free(start);

    const found = try findRepoRoot(a, start);
    defer a.free(found);
    try testing.expectEqualStrings(root, found);
}

test "findRepoRoot fails when no .envless exists" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    const res = findRepoRoot(a, root);
    try testing.expectError(Error.NoEnvlessRoot, res);
}

test "writeJsonString escapes specials" {
    const a = testing.allocator;
    var buf = std.ArrayList(u8).init(a);
    defer buf.deinit();
    try writeJsonString(buf.writer(), "a\"b\\c\nd");
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\"", buf.items);
}

test "countFiles math" {
    try testing.expectEqual(@as(usize, 2), countFiles(0, false));
    try testing.expectEqual(@as(usize, 3), countFiles(0, true));
    try testing.expectEqual(@as(usize, 4), countFiles(2, false));
    try testing.expectEqual(@as(usize, 5), countFiles(2, true));
}
