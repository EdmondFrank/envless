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
            .entries = .empty,
            .capacity = capacity,
            .ttl_ns = ttl_ns,
        };
    }

    pub fn deinit(self: *Cache) void {
        for (self.entries.items) |e| {
            e.deinit(self.allocator);
            self.allocator.destroy(e);
        }
        self.entries.deinit(self.allocator);
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
        try self.entries.append(self.allocator, entry);
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
    std.crypto.secureZero(u8, mutable);
}

// ----------------------------- daemon main ----------------------------------

var g_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);
var g_socket_path_for_cleanup: ?[]const u8 = null;
var g_cache_for_cleanup: ?*Cache = null;

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    g_running.store(false, .release);
}

/// run: foreground daemon entrypoint. Returns on SIGTERM/SIGINT or an
/// unrecoverable accept error.
pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    const home_ptr = std.c.getenv("HOME") orelse return error.EnvironmentVariableMissing;
    const home = try allocator.dupe(u8, std.mem.span(home_ptr));
    defer allocator.free(home);
    const sock_path = try ipc.socketPath(allocator, io, home);
    defer allocator.free(sock_path);

    // Best-effort cleanup of orphan socket.
    std.Io.Dir.cwd().deleteFile(io, sock_path) catch {};

    var cache = Cache.init(allocator, CACHE_CAPACITY, CACHE_TTL_NS);
    defer cache.deinit();

    g_socket_path_for_cleanup = sock_path;
    g_cache_for_cleanup = &cache;

    installSignalHandlers();

    const addr = try std.Io.net.UnixAddress.init(sock_path);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);

    var err_buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &err_buf);
    stderr.interface.print("[envless daemon] listening on {s} (cache cap={d} ttl={d}s)\n", .{ sock_path, CACHE_CAPACITY, @divTrunc(CACHE_TTL_NS, std.time.ns_per_s) }) catch {};
    stderr.flush() catch {};

    while (g_running.load(.acquire)) {
        const conn = server.accept(io) catch |err| switch (err) {
            error.SocketNotListening => break,
            else => {
                stderr.interface.print("[envless daemon] accept failed: {s}\n", .{@errorName(err)}) catch {};
                stderr.flush() catch {};
                continue;
            },
        };
        defer conn.close(io);
        handleClient(allocator, io, &cache, conn) catch |err| {
            stderr.interface.print("[envless daemon] client failed: {s}\n", .{@errorName(err)}) catch {};
            stderr.flush() catch {};
        };
    }

    // Best-effort wipe of the cache on shutdown.
    cache.deinit();
    cache.entries = .empty; // reset to empty
    std.Io.Dir.cwd().deleteFile(io, sock_path) catch {};
}

fn installSignalHandlers() void {
    if (builtin.os.tag == .windows) return;
    var act = std.posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    // Ignore SIGPIPE — clients dropping mid-write must not kill the daemon.
    var ign = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &ign, null);
}

// ----------------------------- per-client loop ------------------------------

fn handleClient(allocator: std.mem.Allocator, io: std.Io, cache: *Cache, stream: std.Io.net.Stream) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Read exactly one request line, dispatch, write the response.
    // Use a heap-allocated buffer large enough for big SET values or EXEC
    // payloads. The old 0.13 code used a dynamically-growing ArrayList with
    // a 64MB cap; 1MB is sufficient for any practical request and still
    // far below the old limit.
    const read_buf = try a.alloc(u8, 1024 * 1024);
    var reader = stream.reader(io, read_buf);

    const line_bytes = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
        error.EndOfStream => return,
        error.StreamTooLong => {
            const payload = try ipc.errPayload(a, "request_too_long", "request line exceeds 1MB limit");
            const resp = try ipc.encodeErr(a, payload);
            try streamWriteAll(io, stream, resp);
            return;
        },
        else => return err,
    };
    const line = std.mem.trimEnd(u8, line_bytes, " \t\r\n");
    if (line.len == 0) return;

    const req = ipc.parseRequest(line) catch {
        const payload = try ipc.errPayload(a, "malformed", "request line is malformed");
        const resp = try ipc.encodeErr(a, payload);
        try streamWriteAll(io, stream, resp);
        return;
    };

    switch (req) {
        .ping => {
            const resp = try ipc.encodeOk(a, "{}");
            try streamWriteAll(io, stream, resp);
        },
        .whoami => try serveWhoami(a, io, stream),
        .list => |x| try serveList(a, io, cache, stream, x.env),
        .get => |x| try serveGet(a, io, cache, stream, x.env, x.key),
        .set => |x| try serveSet(a, io, cache, stream, x.env, x.key, x.value),
        .exec => |x| try serveExec(a, io, cache, stream, x),
    }
}

/// Write all bytes to a stream via a stack buffer.
fn streamWriteAll(io: std.Io, stream: std.Io.net.Stream, data: []const u8) !void {
    var w_buf: [4096]u8 = undefined;
    var w = stream.writer(io, &w_buf);
    try w.interface.writeAll(data);
}

fn cwdAlloc(a: std.mem.Allocator, io: std.Io) ![]u8 {
    var buf: [4096]u8 = undefined;
    const len = try std.process.currentPath(io, &buf);
    return a.dupe(u8, buf[0..len]);
}

fn cacheKey(a: std.mem.Allocator, root: []const u8, env: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}\x00{s}", .{ root, env });
}

fn readDecryptedCached(a: std.mem.Allocator, io: std.Io, cache: *Cache, root: []const u8, env: []const u8) !*CacheEntry {
    const key = try cacheKey(a, root, env);
    const now = std.Io.Timestamp.now(io, .real).nanoseconds;

    // Probe disk for current mtime so we can invalidate on edit.
    const s_for_path = store.Store.init(a, io, root);
    const file_path = try s_for_path.secretsPath(a, env);
    defer a.free(file_path);
    var mtime_ns: i128 = 0;
    if (std.Io.Dir.cwd().statFile(io, file_path, .{})) |st| {
        mtime_ns = st.mtime.nanoseconds;
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
    const s = store.Store.init(persistent_alloc, io, root);
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

fn serveList(a: std.mem.Allocator, io: std.Io, cache: *Cache, stream: std.Io.net.Stream, env: []const u8) !void {
    const cwd = try cwdAlloc(a, io);

    const entry = readDecryptedCached(a, io, cache, cwd, env) catch |err| {
        const payload = try ipc.errPayload(a, "decrypt_failed", @errorName(err));
        const resp = try ipc.encodeErr(a, payload);
        try streamWriteAll(io, stream, resp);
        return;
    };

    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(a);
    var it = entry.map.inner.iterator();
    while (it.next()) |e| try keys.append(a, e.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);

    var json_buf: std.ArrayList(u8) = .empty;
    defer json_buf.deinit(a);
    try json_buf.appendSlice(a, "{\"keys\":[");
    for (keys.items, 0..) |k, i| {
        if (i != 0) try json_buf.append(a, ',');
        try json_buf.append(a, '"');
        // Keys are ASCII identifiers in practice; we still escape defensively.
        for (k) |c| switch (c) {
            '"' => try json_buf.appendSlice(a, "\\\""),
            '\\' => try json_buf.appendSlice(a, "\\\\"),
            else => try json_buf.append(a, c),
        };
        try json_buf.append(a, '"');
    }
    try json_buf.appendSlice(a, "]}");
    const resp = try ipc.encodeOk(a, json_buf.items);
    try streamWriteAll(io, stream, resp);
}

fn serveGet(a: std.mem.Allocator, io: std.Io, cache: *Cache, stream: std.Io.net.Stream, env: []const u8, key: []const u8) !void {
    const cwd = try cwdAlloc(a, io);
    const entry = readDecryptedCached(a, io, cache, cwd, env) catch |err| {
        const payload = try ipc.errPayload(a, "decrypt_failed", @errorName(err));
        const resp = try ipc.encodeErr(a, payload);
        try streamWriteAll(io, stream, resp);
        return;
    };
    const v = entry.map.inner.get(key) orelse {
        const payload = try ipc.errPayload(a, "not_found", "key not found");
        const resp = try ipc.encodeErr(a, payload);
        try streamWriteAll(io, stream, resp);
        return;
    };
    // {"value":"<escaped>"}
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "{\"value\":");
    try jsonString(a, &buf, v);
    try buf.append(a, '}');
    const resp = try ipc.encodeOk(a, buf.items);
    try streamWriteAll(io, stream, resp);
}

fn serveSet(a: std.mem.Allocator, io: std.Io, cache: *Cache, stream: std.Io.net.Stream, env: []const u8, key: []const u8, value: []const u8) !void {
    const cwd = try cwdAlloc(a, io);
    const s = store.Store.init(a, io, cwd);
    s.set(env, key, value) catch |err| {
        const payload = try ipc.errPayload(a, "set_failed", @errorName(err));
        const resp = try ipc.encodeErr(a, payload);
        try streamWriteAll(io, stream, resp);
        return;
    };
    // Drop the cached entry so the next read sees the new file mtime.
    const ckey = try cacheKey(a, cwd, env);
    cache.invalidate(ckey);
    const resp = try ipc.encodeOk(a, "{\"ok\":true}");
    try streamWriteAll(io, stream, resp);
}

fn serveWhoami(a: std.mem.Allocator, io: std.Io, stream: std.Io.net.Stream) !void {
    const cwd = try cwdAlloc(a, io);
    const s = store.Store.init(a, io, cwd);
    const pubkey = s.pubKey() catch |err| {
        const payload = try ipc.errPayload(a, "no_identity", @errorName(err));
        const resp = try ipc.encodeErr(a, payload);
        try streamWriteAll(io, stream, resp);
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

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "{\"pubkey\":");
    try jsonString(a, &buf, pubkey);
    try buf.print(a, ",\"recipients\":{d}}}", .{recipients_count});
    const resp = try ipc.encodeOk(a, buf.items);
    try streamWriteAll(io, stream, resp);
}

fn serveExec(a: std.mem.Allocator, io: std.Io, cache: *Cache, stream: std.Io.net.Stream, x: ipc.ExecRequest) !void {
    // EXEC routes through the cached decrypt path so repeated invocations
    // are cheap. The actual child env+spawn lives in execenv; we capture
    // stdout/stderr and ship them back as a JSON payload.
    const cwd_for_child = x.cwd;
    const root_for_decrypt = try cwdAlloc(a, io);

    const entry = readDecryptedCached(a, io, cache, root_for_decrypt, x.env) catch |err| {
        const payload = try ipc.errPayload(a, "decrypt_failed", @errorName(err));
        const resp = try ipc.encodeErr(a, payload);
        try streamWriteAll(io, stream, resp);
        return;
    };

    const argv = ipc.decodeArgvB64(a, x.argv_b64) catch {
        const payload = try ipc.errPayload(a, "argv_decode", "argv_b64 invalid");
        const resp = try ipc.encodeErr(a, payload);
        try streamWriteAll(io, stream, resp);
        return;
    };
    if (argv.len == 0) {
        const payload = try ipc.errPayload(a, "argv_empty", "argv must not be empty");
        const resp = try ipc.encodeErr(a, payload);
        try streamWriteAll(io, stream, resp);
        return;
    }
    const stdin_text = ipc.decodeBytesB64(a, x.stdin_b64) catch {
        const payload = try ipc.errPayload(a, "stdin_decode", "stdin_b64 invalid");
        const resp = try ipc.encodeErr(a, payload);
        try streamWriteAll(io, stream, resp);
        return;
    };

    var argv_view = try a.alloc([]const u8, argv.len);
    for (argv, 0..) |s, i| argv_view[i] = s;

    // Build child env: daemon env + secrets.
    var parent: std.ArrayList([]const u8) = .empty;
    defer parent.deinit(a);
    {
        var i: usize = 0;
        while (std.c.environ[i]) |entry_ptr| : (i += 1) {
            const e = std.mem.span(entry_ptr);
            try parent.append(a, try a.dupe(u8, e));
        }
    }
    const child_env = try execenv.buildEnv(a, parent.items, entry.map.inner);

    // Build Environ.Map for spawn.
    var env_map = std.process.Environ.Map.init(a);
    defer env_map.deinit();
    for (child_env) |kv_str| {
        const eq = std.mem.indexOfScalar(u8, kv_str, '=') orelse continue;
        try env_map.put(kv_str[0..eq], kv_str[eq + 1 ..]);
    }

    var child = std.process.spawn(io, .{
        .argv = argv_view,
        .environ_map = &env_map,
        .cwd = .{ .path = cwd_for_child },
        .stdin = if (stdin_text.len > 0) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| {
        const payload = try ipc.errPayload(a, "spawn_failed", @errorName(err));
        const resp = try ipc.encodeErr(a, payload);
        try streamWriteAll(io, stream, resp);
        return;
    };

    if (stdin_text.len > 0) {
        if (child.stdin) |stdin_file| {
            var w_buf: [4096]u8 = undefined;
            var sw = stdin_file.writer(io, &w_buf);
            sw.interface.writeAll(stdin_text) catch {};
            sw.flush() catch {};
            stdin_file.close(io);
            child.stdin = null;
        }
    }

    // Drain stdout and stderr concurrently to avoid deadlock when the child
    // writes more than the pipe buffer size to one stream before the other.
    // The old 0.13 code used collectOutput which drained both concurrently;
    // we replicate that with Io.File.MultiReader.
    const stdout_file = child.stdout orelse {
        const payload = try ipc.errPayload(a, "spawn_failed", "stdout pipe not available");
        const resp = try ipc.encodeErr(a, payload);
        try streamWriteAll(io, stream, resp);
        return;
    };
    const stderr_file = child.stderr orelse {
        const payload = try ipc.errPayload(a, "spawn_failed", "stderr pipe not available");
        const resp = try ipc.encodeErr(a, payload);
        try streamWriteAll(io, stream, resp);
        return;
    };

    var mr_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var mr: std.Io.File.MultiReader = undefined;
    mr.init(a, io, mr_buffer.toStreams(), &.{ stdout_file, stderr_file });
    defer mr.deinit();

    const stdout_reader = mr.reader(0);
    const stderr_reader = mr.reader(1);

    while (mr.fill(64, .none)) |_| {
        if (stdout_reader.buffered().len > 16 * 1024 * 1024) {
            const payload = try ipc.errPayload(a, "output_too_large", "stdout exceeds 16MB limit");
            const resp = try ipc.encodeErr(a, payload);
            try streamWriteAll(io, stream, resp);
            return;
        }
        if (stderr_reader.buffered().len > 16 * 1024 * 1024) {
            const payload = try ipc.errPayload(a, "output_too_large", "stderr exceeds 16MB limit");
            const resp = try ipc.encodeErr(a, payload);
            try streamWriteAll(io, stream, resp);
            return;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }

    try mr.checkAnyError();

    const term = child.wait(io) catch |err| {
        const payload = try ipc.errPayload(a, "wait_failed", @errorName(err));
        const resp = try ipc.encodeErr(a, payload);
        try streamWriteAll(io, stream, resp);
        return;
    };

    const stdout_data = try mr.toOwnedSlice(0);
    const stderr_data = try mr.toOwnedSlice(1);

    var exit_code: i64 = -1;
    switch (term) {
        .exited => |c| exit_code = @as(i64, c),
        .signal => |sig| exit_code = -(@as(i64, @intCast(@intFromEnum(sig)))),
        else => exit_code = -1,
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.print(a, "{{\"exit_code\":{d},\"stdout\":", .{exit_code});
    try jsonString(a, &buf, stdout_data);
    try buf.appendSlice(a, ",\"stderr\":");
    try jsonString(a, &buf, stderr_data);
    try buf.append(a, '}');
    const resp = try ipc.encodeOk(a, buf.items);
    try streamWriteAll(io, stream, resp);
}

fn jsonString(a: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(a, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(a, "\\\""),
        '\\' => try buf.appendSlice(a, "\\\\"),
        '\n' => try buf.appendSlice(a, "\\n"),
        '\r' => try buf.appendSlice(a, "\\r"),
        '\t' => try buf.appendSlice(a, "\\t"),
        0...8, 11, 12, 14...31 => {
            var seq: [6]u8 = undefined;
            _ = std.fmt.bufPrint(&seq, "\\u{x:0>4}", .{c}) catch unreachable;
            try buf.appendSlice(a, &seq);
        },
        else => try buf.append(a, c),
    };
    try buf.append(a, '"');
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
