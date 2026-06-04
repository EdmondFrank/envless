//! daemon: optional in-memory cache server for envless.
//!
//! Listens on a UNIX stream socket and serves the wire protocol defined in
//! `ipc.zig`. Each request decrypts on miss and caches the result keyed by
//! (repo_root, env) with the source file's mtime as a freshness check.
//!
//! Cache: bounded LRU, 32 entries, 60s TTL. Eviction is the simplest
//! possible — sweep the oldest `last_access` on insert. The daemon is
//! single-threaded (one client at a time) because the workload is fast and
//! we want the security story to be trivial: only the daemon process holds
//! decrypted env, never two threads simultaneously.
//!
//! Lifecycle: foreground only. `envless daemon` opens the socket and runs
//! the accept loop until SIGTERM/SIGINT. On signal we close the socket,
//! best-effort wipe the cache memory, and exit cleanly. Process supervisor
//! integration (launchd / systemd) lives in `launchd.zig` / `systemd.zig`.

const std = @import("std");
const builtin = @import("builtin");

const ipc = @import("ipc.zig");
const store = @import("store.zig");
const sops = @import("sops.zig");
const execenv = @import("execenv.zig");

pub const CACHE_CAPACITY: usize = 32;
pub const CACHE_TTL_NS: i128 = 60 * std.time.ns_per_s;

/// CacheEntry — one decrypted KV map plus freshness metadata.
pub const CacheEntry = struct {
    /// Identifier — `<repo_root>\x00<env>` (no escaping needed; both are
    /// path components without NUL).
    key: []u8,
    /// Decrypted KV map. Owns its key/value strings via `map.allocator`.
    map: sops.KvMap,
    /// mtime of the encrypted file at decrypt time. We re-decrypt when
    /// disk has changed.
    file_mtime_ns: i128,
    /// Wallclock ns when we last touched this entry. Used for both LRU and
    /// TTL bookkeeping.
    last_access_ns: i128,
    /// Wallclock ns of insert. Used for TTL.
    inserted_ns: i128,

    pub fn deinit(self: *CacheEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        // Best-effort wipe of value bytes before freeing — defence in depth
        // against ptrace/coredumps. Keys are likely uninteresting (KEY
        // names), so we only wipe values.
        var it = self.map.inner.iterator();
        while (it.next()) |e| {
            wipe(e.value_ptr.*);
        }
        self.map.deinit();
    }
};

/// Cache — bounded LRU with TTL. Single-threaded; no locks.
pub const Cache = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(*CacheEntry),
    capacity: usize,
    ttl_ns: i128,

    pub fn init(allocator: std.mem.Allocator, capacity: usize, ttl_ns: i128) Cache {
        return .{
            .allocator = allocator,
            .entries = std.ArrayList(*CacheEntry).init(allocator),
            .capacity = capacity,
            .ttl_ns = ttl_ns,
        };
    }

    pub fn deinit(self: *Cache) void {
        for (self.entries.items) |e| {
            e.deinit(self.allocator);
            self.allocator.destroy(e);
        }
        self.entries.deinit();
    }

    pub fn lookup(self: *Cache, key: []const u8, now_ns: i128) ?*CacheEntry {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.key, key)) {
                if (now_ns - e.inserted_ns > self.ttl_ns) return null;
                e.last_access_ns = now_ns;
                return e;
            }
        }
        return null;
    }

    /// insert: take ownership of `entry`. Evicts the oldest by `last_access`
    /// when we exceed `capacity`.
    pub fn insert(self: *Cache, entry: *CacheEntry) !void {
        // If a stale entry with the same key exists, remove it first.
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const e = self.entries.items[i];
            if (std.mem.eql(u8, e.key, entry.key)) {
                e.deinit(self.allocator);
                self.allocator.destroy(e);
                _ = self.entries.orderedRemove(i);
                continue;
            }
            i += 1;
        }
        while (self.entries.items.len >= self.capacity) {
            // Evict oldest by last_access.
            var oldest_idx: usize = 0;
            var oldest_ts: i128 = self.entries.items[0].last_access_ns;
            for (self.entries.items, 0..) |e, idx| {
                if (e.last_access_ns < oldest_ts) {
                    oldest_ts = e.last_access_ns;
                    oldest_idx = idx;
                }
            }
            const evicted = self.entries.items[oldest_idx];
            evicted.deinit(self.allocator);
            self.allocator.destroy(evicted);
            _ = self.entries.orderedRemove(oldest_idx);
        }
        try self.entries.append(entry);
    }

    pub fn invalidate(self: *Cache, key: []const u8) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const e = self.entries.items[i];
            if (std.mem.eql(u8, e.key, key)) {
                e.deinit(self.allocator);
                self.allocator.destroy(e);
                _ = self.entries.orderedRemove(i);
                continue;
            }
            i += 1;
        }
    }
};

// Best-effort secure wipe. Zig optimizers may elide a plain memset, so we
// use std.crypto.utils.secureZero which is annotated to survive LTO.
fn wipe(buf: []const u8) void {
    if (buf.len == 0) return;
    // SAFETY: KvMap stores values as []const u8 but we own them through
    // the allocator; casting to mutable is sound here because the daemon
    // is the only writer.
    const mutable: []u8 = @constCast(buf);
    std.crypto.utils.secureZero(u8, mutable);
}

// ----------------------------- daemon main ----------------------------------

var g_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);
var g_socket_path_for_cleanup: ?[]const u8 = null;
var g_cache_for_cleanup: ?*Cache = null;

fn onSignal(_: c_int) callconv(.C) void {
    g_running.store(false, .release);
}

/// run: foreground daemon entrypoint. Returns on SIGTERM/SIGINT or an
/// unrecoverable accept error.
pub fn run(allocator: std.mem.Allocator) !void {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    const sock_path = try ipc.socketPath(allocator, home);
    defer allocator.free(sock_path);

    // Best-effort cleanup of orphan socket.
    std.fs.cwd().deleteFile(sock_path) catch {};

    var cache = Cache.init(allocator, CACHE_CAPACITY, CACHE_TTL_NS);
    defer cache.deinit();

    g_socket_path_for_cleanup = sock_path;
    g_cache_for_cleanup = &cache;

    installSignalHandlers();

    const addr = try std.net.Address.initUnix(sock_path);
    var server = try addr.listen(.{});
    defer server.deinit();

    const stderr = std.io.getStdErr().writer();
    stderr.print("[envless daemon] listening on {s} (cache cap={d} ttl={d}s)\n", .{ sock_path, CACHE_CAPACITY, @divTrunc(CACHE_TTL_NS, std.time.ns_per_s) }) catch {};

    while (g_running.load(.acquire)) {
        const conn = server.accept() catch |err| switch (err) {
            error.SocketNotListening => break,
            else => {
                stderr.print("[envless daemon] accept failed: {s}\n", .{@errorName(err)}) catch {};
                continue;
            },
        };
        defer conn.stream.close();
        handleClient(allocator, &cache, conn.stream) catch |err| {
            stderr.print("[envless daemon] client failed: {s}\n", .{@errorName(err)}) catch {};
        };
    }

    // Best-effort wipe of the cache on shutdown.
    cache.deinit();
    cache.entries = std.ArrayList(*CacheEntry).init(allocator); // reset to empty
    std.fs.cwd().deleteFile(sock_path) catch {};
}

fn installSignalHandlers() void {
    if (builtin.os.tag == .windows) return;
    var act = std.posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    _ = std.posix.sigaction(std.posix.SIG.TERM, &act, null) catch {};
    _ = std.posix.sigaction(std.posix.SIG.INT, &act, null) catch {};
    // Ignore SIGPIPE — clients dropping mid-write must not kill the daemon.
    var ign = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    _ = std.posix.sigaction(std.posix.SIG.PIPE, &ign, null) catch {};
}

// ----------------------------- per-client loop ------------------------------

const MAX_LINE: usize = 64 * 1024 * 1024;

fn handleClient(allocator: std.mem.Allocator, cache: *Cache, stream: std.net.Stream) !void {
    // Read exactly one request line, dispatch, write the response.
    var line_buf = std.ArrayList(u8).init(allocator);
    defer line_buf.deinit();

    var reader = stream.reader();
    reader.streamUntilDelimiter(line_buf.writer(), '\n', MAX_LINE) catch |err| switch (err) {
        error.EndOfStream => {
            if (line_buf.items.len == 0) return;
        },
        else => return err,
    };
    const line = std.mem.trimRight(u8, line_buf.items, " \t\r\n");
    if (line.len == 0) return;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const req = ipc.parseRequest(line) catch {
        const payload = try ipc.errPayload(a, "malformed", "request line is malformed");
        const resp = try ipc.encodeErr(a, payload);
        try stream.writer().writeAll(resp);
        return;
    };

    switch (req) {
        .ping => {
            const resp = try ipc.encodeOk(a, "{}");
            try stream.writer().writeAll(resp);
        },
        .whoami => try serveWhoami(a, stream),
        .list => |x| try serveList(a, cache, stream, x.env),
        .get => |x| try serveGet(a, cache, stream, x.env, x.key),
        .set => |x| try serveSet(a, cache, stream, x.env, x.key, x.value),
        .exec => |x| try serveExec(a, cache, stream, x),
    }
}

fn cwdAlloc(a: std.mem.Allocator) ![]u8 {
    var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const s = try std.process.getCwd(&buf);
    return a.dupe(u8, s);
}

fn cacheKey(a: std.mem.Allocator, root: []const u8, env: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}\x00{s}", .{ root, env });
}

fn readDecryptedCached(a: std.mem.Allocator, cache: *Cache, root: []const u8, env: []const u8) !*CacheEntry {
    const key = try cacheKey(a, root, env);
    const now = std.time.nanoTimestamp();

    // Probe disk for current mtime so we can invalidate on edit.
    const s_for_path = store.Store.init(a, root);
    const file_path = try s_for_path.secretsPath(a, env);
    defer a.free(file_path);
    var mtime_ns: i128 = 0;
    if (std.fs.cwd().statFile(file_path)) |st| {
        mtime_ns = st.mtime;
    } else |_| {
        // File may not exist yet (e.g. fresh init before any set). That's
        // fine — empty map.
    }

    if (cache.lookup(key, now)) |e| {
        if (e.file_mtime_ns == mtime_ns) return e;
        cache.invalidate(key);
    }

    // Cold path: decrypt fresh, then insert.
    const persistent_alloc = cache.allocator;
    const s = store.Store.init(persistent_alloc, root);
    var kv = try s.read(env);
    errdefer kv.deinit();

    const entry = try persistent_alloc.create(CacheEntry);
    errdefer persistent_alloc.destroy(entry);
    entry.* = .{
        .key = try persistent_alloc.dupe(u8, key),
        .map = kv,
        .file_mtime_ns = mtime_ns,
        .last_access_ns = now,
        .inserted_ns = now,
    };
    try cache.insert(entry);
    return entry;
}

fn serveList(a: std.mem.Allocator, cache: *Cache, stream: std.net.Stream, env: []const u8) !void {
    const cwd = try cwdAlloc(a);

    const entry = readDecryptedCached(a, cache, cwd, env) catch |err| {
        const payload = try ipc.errPayload(a, "decrypt_failed", @errorName(err));
        const resp = try ipc.encodeErr(a, payload);
        try stream.writer().writeAll(resp);
        return;
    };

    var keys = std.ArrayList([]const u8).init(a);
    defer keys.deinit();
    var it = entry.map.inner.iterator();
    while (it.next()) |e| try keys.append(e.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);

    var json_buf = std.ArrayList(u8).init(a);
    defer json_buf.deinit();
    try json_buf.appendSlice("{\"keys\":[");
    for (keys.items, 0..) |k, i| {
        if (i != 0) try json_buf.append(',');
        try json_buf.append('"');
        // Keys are ASCII identifiers in practice; we still escape defensively.
        for (k) |c| switch (c) {
            '"' => try json_buf.appendSlice("\\\""),
            '\\' => try json_buf.appendSlice("\\\\"),
            else => try json_buf.append(c),
        };
        try json_buf.append('"');
    }
    try json_buf.appendSlice("]}");
    const resp = try ipc.encodeOk(a, json_buf.items);
    try stream.writer().writeAll(resp);
}

fn serveGet(a: std.mem.Allocator, cache: *Cache, stream: std.net.Stream, env: []const u8, key: []const u8) !void {
    const cwd = try cwdAlloc(a);
    const entry = readDecryptedCached(a, cache, cwd, env) catch |err| {
        const payload = try ipc.errPayload(a, "decrypt_failed", @errorName(err));
        const resp = try ipc.encodeErr(a, payload);
        try stream.writer().writeAll(resp);
        return;
    };
    const v = entry.map.inner.get(key) orelse {
        const payload = try ipc.errPayload(a, "not_found", "key not found");
        const resp = try ipc.encodeErr(a, payload);
        try stream.writer().writeAll(resp);
        return;
    };
    // {"value":"<escaped>"}
    var buf = std.ArrayList(u8).init(a);
    defer buf.deinit();
    try buf.appendSlice("{\"value\":");
    try jsonString(&buf, v);
    try buf.append('}');
    const resp = try ipc.encodeOk(a, buf.items);
    try stream.writer().writeAll(resp);
}

fn serveSet(a: std.mem.Allocator, cache: *Cache, stream: std.net.Stream, env: []const u8, key: []const u8, value: []const u8) !void {
    const cwd = try cwdAlloc(a);
    const s = store.Store.init(a, cwd);
    s.set(env, key, value) catch |err| {
        const payload = try ipc.errPayload(a, "set_failed", @errorName(err));
        const resp = try ipc.encodeErr(a, payload);
        try stream.writer().writeAll(resp);
        return;
    };
    // Drop the cached entry so the next read sees the new file mtime.
    const ckey = try cacheKey(a, cwd, env);
    cache.invalidate(ckey);
    const resp = try ipc.encodeOk(a, "{\"ok\":true}");
    try stream.writer().writeAll(resp);
}

fn serveWhoami(a: std.mem.Allocator, stream: std.net.Stream) !void {
    const cwd = try cwdAlloc(a);
    const s = store.Store.init(a, cwd);
    const pubkey = s.pubKey() catch |err| {
        const payload = try ipc.errPayload(a, "no_identity", @errorName(err));
        const resp = try ipc.encodeErr(a, payload);
        try stream.writer().writeAll(resp);
        return;
    };
    var recipients_count: usize = 0;
    if (s.recipients("")) |recs| {
        defer {
            for (recs) |r| a.free(r);
            a.free(recs);
        }
        recipients_count = recs.len;
    } else |_| {}

    var buf = std.ArrayList(u8).init(a);
    defer buf.deinit();
    try buf.appendSlice("{\"pubkey\":");
    try jsonString(&buf, pubkey);
    try buf.writer().print(",\"recipients\":{d}}}", .{recipients_count});
    const resp = try ipc.encodeOk(a, buf.items);
    try stream.writer().writeAll(resp);
}

fn serveExec(a: std.mem.Allocator, cache: *Cache, stream: std.net.Stream, x: ipc.ExecRequest) !void {
    // EXEC routes through the cached decrypt path so repeated invocations
    // are cheap. The actual child env+spawn lives in execenv; we capture
    // stdout/stderr and ship them back as a JSON payload.
    const cwd_for_child = x.cwd;
    const root_for_decrypt = try cwdAlloc(a);

    const entry = readDecryptedCached(a, cache, root_for_decrypt, x.env) catch |err| {
        const payload = try ipc.errPayload(a, "decrypt_failed", @errorName(err));
        const resp = try ipc.encodeErr(a, payload);
        try stream.writer().writeAll(resp);
        return;
    };

    const argv = ipc.decodeArgvB64(a, x.argv_b64) catch {
        const payload = try ipc.errPayload(a, "argv_decode", "argv_b64 invalid");
        const resp = try ipc.encodeErr(a, payload);
        try stream.writer().writeAll(resp);
        return;
    };
    if (argv.len == 0) {
        const payload = try ipc.errPayload(a, "argv_empty", "argv must not be empty");
        const resp = try ipc.encodeErr(a, payload);
        try stream.writer().writeAll(resp);
        return;
    }
    const stdin_text = ipc.decodeBytesB64(a, x.stdin_b64) catch {
        const payload = try ipc.errPayload(a, "stdin_decode", "stdin_b64 invalid");
        const resp = try ipc.encodeErr(a, payload);
        try stream.writer().writeAll(resp);
        return;
    };

    var argv_view = try a.alloc([]const u8, argv.len);
    for (argv, 0..) |s, i| argv_view[i] = s;

    // Build child env: daemon env + secrets.
    var env_map = std.process.getEnvMap(a) catch unreachable;
    defer env_map.deinit();
    var parent = std.ArrayList([]const u8).init(a);
    defer parent.deinit();
    var it = env_map.iterator();
    while (it.next()) |e| {
        try parent.append(try std.fmt.allocPrint(a, "{s}={s}", .{ e.key_ptr.*, e.value_ptr.* }));
    }
    const child_env = try execenv.buildEnv(a, parent.items, entry.map.inner);

    var child = std.process.Child.init(argv_view, a);
    var child_env_map = std.process.EnvMap.init(a);
    defer child_env_map.deinit();
    for (child_env) |kv_str| {
        const eq = std.mem.indexOfScalar(u8, kv_str, '=') orelse continue;
        try child_env_map.put(kv_str[0..eq], kv_str[eq + 1 ..]);
    }
    child.env_map = &child_env_map;
    child.cwd = cwd_for_child;
    child.stdin_behavior = if (stdin_text.len > 0) .Pipe else .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch |err| {
        const payload = try ipc.errPayload(a, "spawn_failed", @errorName(err));
        const resp = try ipc.encodeErr(a, payload);
        try stream.writer().writeAll(resp);
        return;
    };
    if (stdin_text.len > 0) {
        if (child.stdin) |stdin| {
            stdin.writeAll(stdin_text) catch {};
            stdin.close();
            child.stdin = null;
        }
    }
    var stdout_buf = std.ArrayList(u8).init(a);
    var stderr_buf = std.ArrayList(u8).init(a);
    child.collectOutput(&stdout_buf, &stderr_buf, 16 * 1024 * 1024) catch {};
    const term = child.wait() catch |err| {
        const payload = try ipc.errPayload(a, "wait_failed", @errorName(err));
        const resp = try ipc.encodeErr(a, payload);
        try stream.writer().writeAll(resp);
        return;
    };

    var exit_code: i64 = -1;
    switch (term) {
        .Exited => |c| exit_code = @as(i64, c),
        .Signal => |sig| exit_code = -(@as(i64, @intCast(sig))),
        else => exit_code = -1,
    }
    var buf = std.ArrayList(u8).init(a);
    defer buf.deinit();
    try buf.writer().print("{{\"exit_code\":{d},\"stdout\":", .{exit_code});
    try jsonString(&buf, stdout_buf.items);
    try buf.appendSlice(",\"stderr\":");
    try jsonString(&buf, stderr_buf.items);
    try buf.append('}');
    const resp = try ipc.encodeOk(a, buf.items);
    try stream.writer().writeAll(resp);
}

fn jsonString(buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append('"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice("\\\""),
        '\\' => try buf.appendSlice("\\\\"),
        '\n' => try buf.appendSlice("\\n"),
        '\r' => try buf.appendSlice("\\r"),
        '\t' => try buf.appendSlice("\\t"),
        0...8, 11, 12, 14...31 => {
            var seq: [6]u8 = undefined;
            _ = std.fmt.bufPrint(&seq, "\\u{x:0>4}", .{c}) catch unreachable;
            try buf.appendSlice(&seq);
        },
        else => try buf.append(c),
    };
    try buf.append('"');
}

// ----------------------------- tests -----------------------------------------

const testing = std.testing;

test "Cache: insert + lookup hit, ttl miss, eviction" {
    const a = testing.allocator;
    var c = Cache.init(a, 2, 1 * std.time.ns_per_s);
    defer c.deinit();

    // Insert two entries.
    const e1 = try a.create(CacheEntry);
    e1.* = .{
        .key = try a.dupe(u8, "/repo\x00dev"),
        .map = .{ .inner = std.StringHashMap([]const u8).init(a), .allocator = a },
        .file_mtime_ns = 1,
        .last_access_ns = 1,
        .inserted_ns = 1,
    };
    try c.insert(e1);

    const e2 = try a.create(CacheEntry);
    e2.* = .{
        .key = try a.dupe(u8, "/repo\x00prod"),
        .map = .{ .inner = std.StringHashMap([]const u8).init(a), .allocator = a },
        .file_mtime_ns = 1,
        .last_access_ns = 2,
        .inserted_ns = 2,
    };
    try c.insert(e2);

    // Hit.
    try testing.expect(c.lookup("/repo\x00dev", 3) != null);
    try testing.expect(c.lookup("/repo\x00prod", 3) != null);

    // TTL miss (now is 2s after insert, ttl is 1s).
    const after_ttl = 1 + 2 * std.time.ns_per_s;
    try testing.expect(c.lookup("/repo\x00dev", after_ttl) == null);

    // Eviction on overflow.
    const e3 = try a.create(CacheEntry);
    e3.* = .{
        .key = try a.dupe(u8, "/repo\x00stage"),
        .map = .{ .inner = std.StringHashMap([]const u8).init(a), .allocator = a },
        .file_mtime_ns = 1,
        .last_access_ns = 10,
        .inserted_ns = 10,
    };
    try c.insert(e3);
    // We should still see prod (touched at 3) and stage; dev (touched at 1
    // → not accessed since we read it post-TTL which doesn't update) gone.
    var saw_stage = false;
    for (c.entries.items) |e| {
        if (std.mem.eql(u8, e.key, "/repo\x00stage")) saw_stage = true;
    }
    try testing.expect(saw_stage);
    try testing.expect(c.entries.items.len == 2);
}

test "Cache: re-insert same key replaces old entry" {
    const a = testing.allocator;
    var c = Cache.init(a, 4, 60 * std.time.ns_per_s);
    defer c.deinit();
    const e1 = try a.create(CacheEntry);
    e1.* = .{
        .key = try a.dupe(u8, "k"),
        .map = .{ .inner = std.StringHashMap([]const u8).init(a), .allocator = a },
        .file_mtime_ns = 1,
        .last_access_ns = 1,
        .inserted_ns = 1,
    };
    try c.insert(e1);
    const e2 = try a.create(CacheEntry);
    e2.* = .{
        .key = try a.dupe(u8, "k"),
        .map = .{ .inner = std.StringHashMap([]const u8).init(a), .allocator = a },
        .file_mtime_ns = 5,
        .last_access_ns = 5,
        .inserted_ns = 5,
    };
    try c.insert(e2);
    try testing.expectEqual(@as(usize, 1), c.entries.items.len);
    try testing.expectEqual(@as(i128, 5), c.entries.items[0].file_mtime_ns);
}

test "Cache: invalidate by key" {
    const a = testing.allocator;
    var c = Cache.init(a, 4, 60 * std.time.ns_per_s);
    defer c.deinit();
    const e1 = try a.create(CacheEntry);
    e1.* = .{
        .key = try a.dupe(u8, "x"),
        .map = .{ .inner = std.StringHashMap([]const u8).init(a), .allocator = a },
        .file_mtime_ns = 1,
        .last_access_ns = 1,
        .inserted_ns = 1,
    };
    try c.insert(e1);
    c.invalidate("x");
    try testing.expectEqual(@as(usize, 0), c.entries.items.len);
}
