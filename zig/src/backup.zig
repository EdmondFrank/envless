//! backup: assemble a tar.gz of envless state (recipients + encrypted secrets,
//! optionally the identity key) plus a MANIFEST.json describing the archive.
//!
//! Design notes:
//!   - We shell out to system `tar` for the actual archive. The Zig stdlib
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
pub fn findRepoRoot(allocator: std.mem.Allocator, io: std.Io, start_dir: []const u8) Error![]u8 {
    // start_dir is expected to be absolute (from std.process.currentPath).
    // If it doesn't exist, the access check below will fail.
    var cur = allocator.dupe(u8, start_dir) catch return Error.OutOfMemory;
    while (true) {
        const candidate = std.fs.path.join(allocator, &.{ cur, ".envless", "identity.key" }) catch {
            allocator.free(cur);
            return Error.OutOfMemory;
        };
        defer allocator.free(candidate);
        std.Io.Dir.cwd().access(io, candidate, .{}) catch {
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
            continue;
        };
        return cur;
    }
}

/// Iso8601 timestamp ("YYYY-MM-DDTHH:MM:SSZ") for the manifest. Owned slice.
fn isoTimestamp(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const ts = std.Io.Timestamp.now(io, .real);
    const epoch_s: u64 = @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_s));
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
fn listEnvs(allocator: std.mem.Allocator, io: std.Io, root: []const u8) Error![][]u8 {
    const secrets_dir = std.fs.path.join(allocator, &.{ root, "secrets" }) catch return Error.OutOfMemory;
    defer allocator.free(secrets_dir);

    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |s| allocator.free(s);
        list.deinit(allocator);
    }

    var dir = std.Io.Dir.openDirAbsolute(io, secrets_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return list.toOwnedSlice(allocator) catch Error.OutOfMemory,
        else => return Error.IoError,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch return Error.IoError) |entry| {
        if (entry.kind != .file) continue;
        const suffix = ".env.enc";
        if (entry.name.len <= suffix.len) continue;
        if (!std.mem.endsWith(u8, entry.name, suffix)) continue;
        const env_name = entry.name[0 .. entry.name.len - suffix.len];
        const owned = allocator.dupe(u8, env_name) catch return Error.OutOfMemory;
        list.append(allocator, owned) catch return Error.OutOfMemory;
    }

    const slice = list.toOwnedSlice(allocator) catch return Error.OutOfMemory;
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
    io: std.Io,
    stage_dir: []const u8,
    opts: Options,
    pubkey: []const u8,
    envs: []const []u8,
) !void {
    const created_at = try isoTimestamp(allocator, io);
    defer allocator.free(created_at);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\n");
    try buf.print(allocator, "  \"schema_version\": 1,\n", .{});
    try buf.print(allocator, "  \"envless_version\": \"{s}\",\n", .{opts.version});
    try buf.print(allocator, "  \"created_at\": \"{s}\",\n", .{created_at});
    try buf.appendSlice(allocator, "  \"repo_root\": ");
    try writeJsonString(allocator, &buf, opts.repo_root);
    try buf.appendSlice(allocator, ",\n");
    try buf.appendSlice(allocator, "  \"pubkey\": ");
    try writeJsonString(allocator, &buf, pubkey);
    try buf.appendSlice(allocator, ",\n");
    try buf.print(allocator, "  \"includes_identity\": {s},\n", .{if (opts.include_identity) "true" else "false"});

    try buf.appendSlice(allocator, "  \"envs\": [");
    for (envs, 0..) |env, i| {
        if (i != 0) try buf.appendSlice(allocator, ", ");
        try writeJsonString(allocator, &buf, env);
    }
    try buf.appendSlice(allocator, "],\n");

    try buf.print(allocator, "  \"file_count\": {d}\n", .{countFiles(envs.len, opts.include_identity)});
    try buf.appendSlice(allocator, "}\n");

    const path = try std.fs.path.join(allocator, &.{ stage_dir, "MANIFEST.json" });
    defer allocator.free(path);

    var f = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
    defer f.close(io);
    var write_buf: [4096]u8 = undefined;
    var fw = f.writer(io, &write_buf);
    try fw.interface.writeAll(buf.items);
    try fw.flush();
}

/// Minimal JSON string writer: quote + escape \, ", control chars.
fn writeJsonString(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(allocator, "\\\""),
        '\\' => try buf.appendSlice(allocator, "\\\\"),
        '\n' => try buf.appendSlice(allocator, "\\n"),
        '\r' => try buf.appendSlice(allocator, "\\r"),
        '\t' => try buf.appendSlice(allocator, "\\t"),
        else => {
            if (c < 0x20) {
                try buf.print(allocator, "\\u{x:0>4}", .{c});
            } else {
                try buf.append(allocator, c);
            }
        },
    };
    try buf.append(allocator, '"');
}

/// Stage everything into a temp dir, run system tar to bundle it up, then
/// either move to opts.output_path or stream to stdout.
pub fn run(allocator: std.mem.Allocator, io: std.Io, opts: Options) Error!void {
    const s = store_mod.Store.init(allocator, io, opts.repo_root);

    // Resolve pubkey upfront — also validates that identity.key is parseable.
    const pubkey = s.pubKey() catch return Error.IoError;
    defer allocator.free(pubkey);

    // List envs (sorted, empty allowed).
    const envs = try listEnvs(allocator, io, opts.repo_root);
    defer {
        for (envs) |e| allocator.free(e);
        allocator.free(envs);
    }

    // Build a temp staging dir.
    var rand_buf: [8]u8 = undefined;
    std.Io.randomSecure(io, &rand_buf) catch @memset(&rand_buf, 0);
    var stage_seed = std.mem.readInt(u64, &rand_buf, .little);
    stage_seed +%= @intFromPtr(&stage_seed);
    var prng = std.Random.DefaultPrng.init(stage_seed);
    const rnd = prng.random().int(u64);

    const tmp_root = std.c.getenv("TMPDIR");
    const tmp_root_str = if (tmp_root) |p| std.mem.span(p) else "/tmp";
    const stage_dir = std.fmt.allocPrint(allocator, "{s}/envless-backup-{x}", .{ tmp_root_str, rnd }) catch return Error.OutOfMemory;
    defer allocator.free(stage_dir);
    std.Io.Dir.createDirAbsolute(io, stage_dir, .default_dir) catch return Error.StageFailed;
    defer std.Io.Dir.cwd().deleteTree(io, stage_dir) catch {};

    // Inside stage_dir, build the desired tree:
    //   .envless/recipients
    //   .envless/identity.key  (only if include_identity)
    //   secrets/<env>.env.enc  (per env)
    //   MANIFEST.json
    {
        const envless_sub = std.fs.path.join(allocator, &.{ stage_dir, ".envless" }) catch return Error.OutOfMemory;
        defer allocator.free(envless_sub);
        std.Io.Dir.createDirAbsolute(io, envless_sub, .default_dir) catch return Error.StageFailed;
    }
    if (envs.len > 0) {
        const secrets_sub = std.fs.path.join(allocator, &.{ stage_dir, "secrets" }) catch return Error.OutOfMemory;
        defer allocator.free(secrets_sub);
        std.Io.Dir.createDirAbsolute(io, secrets_sub, .default_dir) catch return Error.StageFailed;
    }

    // Copy recipients.
    {
        const src = std.fs.path.join(allocator, &.{ opts.repo_root, ".envless", "recipients" }) catch return Error.OutOfMemory;
        defer allocator.free(src);
        const dst = std.fs.path.join(allocator, &.{ stage_dir, ".envless", "recipients" }) catch return Error.OutOfMemory;
        defer allocator.free(dst);
        copyFile(io, src, dst) catch return Error.IoError;
    }

    // Conditionally copy identity.key.
    if (opts.include_identity) {
        const src = std.fs.path.join(allocator, &.{ opts.repo_root, ".envless", "identity.key" }) catch return Error.OutOfMemory;
        defer allocator.free(src);
        const dst = std.fs.path.join(allocator, &.{ stage_dir, ".envless", "identity.key" }) catch return Error.OutOfMemory;
        defer allocator.free(dst);
        copyFile(io, src, dst) catch return Error.IoError;
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
        copyFile(io, src, dst) catch return Error.IoError;
    }

    // Write the manifest.
    writeManifest(allocator, io, stage_dir, opts, pubkey, envs) catch return Error.ManifestFailed;

    // Build the list of entries to feed to tar. Use the relative names so the
    // tarball entries are e.g. "MANIFEST.json", ".envless/recipients", etc.
    var members: std.ArrayList([]const u8) = .empty;
    defer members.deinit(allocator);
    members.append(allocator, "MANIFEST.json") catch return Error.OutOfMemory;
    members.append(allocator, ".envless/recipients") catch return Error.OutOfMemory;
    if (opts.include_identity) members.append(allocator, ".envless/identity.key") catch return Error.OutOfMemory;
    // Env names need ".env.enc" suffixes inside the tarball.
    var member_paths: std.ArrayList([]u8) = .empty;
    defer {
        for (member_paths.items) |p| allocator.free(p);
        member_paths.deinit(allocator);
    }
    for (envs) |env_name| {
        const p = std.fmt.allocPrint(allocator, "secrets/{s}.env.enc", .{env_name}) catch return Error.OutOfMemory;
        member_paths.append(allocator, p) catch return Error.OutOfMemory;
        members.append(allocator, p) catch return Error.OutOfMemory;
    }

    // Invoke tar.
    //
    // Two cases:
    //   - output_path is a real path: `tar --format=ustar -czf <path> -C <stage> <members...>`
    //   - output_path is null / "-": pipe to our stdout via `-czf -`. We inherit
    //     stdout so the bytes flow straight through.
    const want_stdout = (opts.output_path == null) or std.mem.eql(u8, opts.output_path.?, "-");

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    argv.append(allocator, "tar") catch return Error.OutOfMemory;
    argv.append(allocator, "--format=ustar") catch return Error.OutOfMemory;
    argv.append(allocator, "-czf") catch return Error.OutOfMemory;
    argv.append(allocator, if (want_stdout) "-" else opts.output_path.?) catch return Error.OutOfMemory;
    argv.append(allocator, "-C") catch return Error.OutOfMemory;
    argv.append(allocator, stage_dir) catch return Error.OutOfMemory;
    for (members.items) |m| argv.append(allocator, m) catch return Error.OutOfMemory;

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = if (want_stdout) .inherit else .pipe,
        .stderr = .pipe,
    }) catch return Error.TarFailed;

    // Drain stderr so a tar warning doesn't deadlock.
    if (child.stderr) |se| {
        var read_buf: [4096]u8 = undefined;
        var sr = se.reader(io, &read_buf);
        while (true) {
            const n = sr.interface.readSliceShort(&read_buf) catch break;
            if (n == 0) break;
        }
    }
    if (child.stdout) |so| {
        var read_buf: [4096]u8 = undefined;
        var sr = so.reader(io, &read_buf);
        while (true) {
            const n = sr.interface.readSliceShort(&read_buf) catch break;
            if (n == 0) break;
        }
    }

    const term = child.wait(io) catch return Error.TarFailed;
    switch (term) {
        .exited => |c| if (c != 0) return Error.TarFailed,
        else => return Error.TarFailed,
    }
}

fn copyFile(io: std.Io, src: []const u8, dst: []const u8) !void {
    var sf = try std.Io.Dir.openFileAbsolute(io, src, .{});
    defer sf.close(io);
    var df = try std.Io.Dir.createFileAbsolute(io, dst, .{ .truncate = true });
    defer df.close(io);
    var reader_buf: [64 * 1024]u8 = undefined;
    var sr = sf.reader(io, &reader_buf);
    var write_buf: [64 * 1024]u8 = undefined;
    var dw = df.writer(io, &write_buf);
    var data_buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try sr.interface.readSliceShort(&data_buf);
        if (n == 0) break;
        try dw.interface.writeAll(data_buf[0..n]);
    }
    try dw.flush();
}

fn chmod600(path: []const u8) !void {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return error.PathTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const c_path = buf[0..path.len :0];
    const rc = std.c.chmod(c_path.ptr, 0o600);
    if (rc != 0) return error.ChmodFailed;
}

// ----------------------------- tests -----------------------------------------

const testing = std.testing;

test "findRepoRoot returns dir holding .envless/identity.key" {
    const a = testing.allocator;
    const io = std.testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var _path_buf: [4096]u8 = undefined;
    const _path_len = try tmp.dir.realPath(std.testing.io, &_path_buf);
    const root = try a.dupe(u8, _path_buf[0.._path_len]);
    defer a.free(root);

    // Fake the marker.
    try tmp.dir.createDirPath(io, ".envless");
    {
        var f = try tmp.dir.createFile(io, ".envless/identity.key", .{});
        defer f.close(io);
        var w_buf: [256]u8 = undefined;
        var fw = f.writer(io, &w_buf);
        try fw.interface.writeAll("# created\n# public key: age1xyz\nAGE-SECRET-KEY-1FAKE\n");
        try fw.flush();
    }

    // Make a nested subdir and resolve from there.
    try tmp.dir.createDirPath(io, "sub/deep");
    const start = try std.fs.path.join(a, &.{ root, "sub", "deep" });
    defer a.free(start);

    const found = try findRepoRoot(a, io, start);
    defer a.free(found);
    try testing.expectEqualStrings(root, found);
}

test "findRepoRoot fails when no .envless exists" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var _path_buf: [4096]u8 = undefined;
    const _path_len = try tmp.dir.realPath(std.testing.io, &_path_buf);
    const root = try a.dupe(u8, _path_buf[0.._path_len]);
    defer a.free(root);

    const res = findRepoRoot(a, std.testing.io, root);
    try testing.expectError(Error.NoEnvlessRoot, res);
}

test "writeJsonString escapes specials" {
    const a = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try writeJsonString(a, &buf, "a\"b\\c\nd");
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\"", buf.items);
}

test "countFiles math" {
    try testing.expectEqual(@as(usize, 2), countFiles(0, false));
    try testing.expectEqual(@as(usize, 3), countFiles(0, true));
    try testing.expectEqual(@as(usize, 4), countFiles(2, false));
    try testing.expectEqual(@as(usize, 5), countFiles(2, true));
}

test "isoTimestamp produces valid ISO 8601 format" {
    // Regression test: isoTimestamp was migrated from std.time.timestamp()
    // to std.Io.Timestamp.now(io, .real).nanoseconds. Verify the output
    // format is still YYYY-MM-DDTHH:MM:SSZ.
    const a = testing.allocator;
    const io = std.testing.io;
    const ts = try isoTimestamp(a, io);
    defer a.free(ts);
    // Expected length: 20 chars (e.g. "2026-07-01T12:34:56Z").
    try testing.expectEqual(@as(usize, 20), ts.len);
    try testing.expectEqual(@as(u8, 'T'), ts[10]);
    try testing.expectEqual(@as(u8, 'Z'), ts[19]);
    // Verify all other positions are digits or separators.
    for (ts, 0..) |c, i| {
        switch (i) {
            4, 7 => try testing.expectEqual(@as(u8, '-'), c),
            13, 16 => try testing.expectEqual(@as(u8, ':'), c),
            10 => try testing.expectEqual(@as(u8, 'T'), c),
            19 => try testing.expectEqual(@as(u8, 'Z'), c),
            else => try testing.expect(c >= '0' and c <= '9'),
        }
    }
}

test "findRepoRoot fails gracefully with non-existent path" {
    // The old 0.13 code used std.fs.realpath which would catch non-existent
    // paths. The new code assumes start_dir is absolute and relies on the
    // access check. Verify that a non-existent path returns NoEnvlessRoot
    // rather than crashing.
    const a = testing.allocator;
    const res = findRepoRoot(a, std.testing.io, "/nonexistent/path/that/does/not/exist");
    try testing.expectError(Error.NoEnvlessRoot, res);
}
