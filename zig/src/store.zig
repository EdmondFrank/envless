//! store: manage the local envless directory layout: .envless/ (identity,
//! recipients) and secrets/ (per-env encrypted dotenv files).
//!
//! Port of internal/store. Parity rules:
//!   - File layout:
//!       <root>/.envless/identity.key
//!       <root>/.envless/recipients
//!       <root>/secrets/<env>.env.enc
//!   - init(): creates .envless/ (mode 0700), runs `age-keygen -o <identity>`,
//!     chmods identity to 0600, parses pubkey from "# public key: " marker,
//!     writes recipients file with that pubkey + newline.
//!   - init() is idempotent: if identity already exists, returns without
//!     re-running age-keygen.
//!   - recipients(): parses the recipients file, skipping blank lines and
//!     '#'-prefixed comment lines. Errors if no usable recipients remain.
//!   - read(): returns empty map if the secrets file does not exist.
//!   - write/set/get/keys: thin wrappers over sops.

const std = @import("std");
const sops = @import("sops.zig");

pub const Error = error{
    NoPubKeyMarker,
    AgeKeygenFailed,
    ChmodFailed,
    MkdirFailed,
    ReadFailed,
    WriteFailed,
    NoRecipients,
    OutOfMemory,
} || sops.Error;

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, root: []const u8) Store {
        return .{ .allocator = allocator, .io = io, .root = root };
    }

    pub fn identityPath(self: Store, buf_allocator: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(buf_allocator, &.{ self.root, ".envless", "identity.key" });
    }

    pub fn recipientsPath(self: Store, buf_allocator: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(buf_allocator, &.{ self.root, ".envless", "recipients" });
    }

    pub fn secretsPath(self: Store, buf_allocator: std.mem.Allocator, env: []const u8) ![]u8 {
        const fname = try std.fmt.allocPrint(buf_allocator, "{s}.env.enc", .{env});
        defer buf_allocator.free(fname);
        return std.fs.path.join(buf_allocator, &.{ self.root, "secrets", fname });
    }

    /// init creates .envless/identity.key via age-keygen and seeds the
    /// recipients file with the new public key. Idempotent.
    pub fn initStore(self: Store) Error!void {
        const a = self.allocator;
        const dir = std.fs.path.join(a, &.{ self.root, ".envless" }) catch return Error.OutOfMemory;
        defer a.free(dir);
        std.Io.Dir.cwd().createDirPath(self.io, dir) catch return Error.MkdirFailed;
        // chmod 0700 on the directory (Go uses MkdirAll(... 0o700)).
        chmod(dir, 0o700) catch return Error.ChmodFailed;

        const id = self.identityPath(a) catch return Error.OutOfMemory;
        defer a.free(id);

        // If identity already exists, return (idempotent).
        const exists = blk: {
            std.Io.Dir.cwd().access(self.io, id, .{}) catch break :blk false;
            break :blk true;
        };
        if (exists) return;

        // Run age-keygen -o <id>.
        const r = std.process.run(a, self.io, .{
            .argv = &.{ "age-keygen", "-o", id },
        }) catch return Error.AgeKeygenFailed;
        defer a.free(r.stdout);
        defer a.free(r.stderr);
        switch (r.term) {
            .exited => |c| if (c != 0) return Error.AgeKeygenFailed,
            else => return Error.AgeKeygenFailed,
        }

        chmod(id, 0o600) catch return Error.ChmodFailed;

        const pub_key = try self.pubKey();
        defer a.free(pub_key);

        const rec_path = self.recipientsPath(a) catch return Error.OutOfMemory;
        defer a.free(rec_path);
        var rec_file = std.Io.Dir.cwd().createFile(self.io, rec_path, .{ .truncate = true }) catch return Error.WriteFailed;
        defer rec_file.close(self.io);
        var rec_buf: [4096]u8 = undefined;
        var fw = rec_file.writer(self.io, &rec_buf);
        fw.interface.writeAll(pub_key) catch return Error.WriteFailed;
        fw.interface.writeAll("\n") catch return Error.WriteFailed;
        fw.flush() catch return Error.WriteFailed;
    }

    /// recipients returns the list of age public keys for env (currently
    /// env-agnostic; reads .envless/recipients). Caller owns: each slice and
    /// the outer slice are heap-allocated.
    pub fn recipients(self: Store, env: []const u8) Error![][]u8 {
        _ = env; // matches Go: env-agnostic for now
        const a = self.allocator;
        const path = self.recipientsPath(a) catch return Error.OutOfMemory;
        defer a.free(path);
        const data = std.Io.Dir.cwd().readFileAlloc(self.io, path, a, .limited(1024 * 1024)) catch return Error.ReadFailed;
        defer a.free(data);

        var list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (list.items) |s| a.free(s);
            list.deinit(a);
        }
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            if (line[0] == '#') continue;
            const owned = a.dupe(u8, line) catch return Error.OutOfMemory;
            list.append(a, owned) catch return Error.OutOfMemory;
        }
        if (list.items.len == 0) return Error.NoRecipients;
        return list.toOwnedSlice(a) catch return Error.OutOfMemory;
    }

    /// read returns the decrypted KV map for env. Returns an empty owned map
    /// if the secrets file does not yet exist.
    pub fn read(self: Store, env: []const u8) Error!sops.KvMap {
        const a = self.allocator;
        const p = self.secretsPath(a, env) catch return Error.OutOfMemory;
        defer a.free(p);
        const exists = blk: {
            std.Io.Dir.cwd().access(self.io, p, .{}) catch break :blk false;
            break :blk true;
        };
        if (!exists) {
            return sops.KvMap{
                .inner = std.StringHashMap([]const u8).init(a),
                .allocator = a,
            };
        }
        const id = self.identityPath(a) catch return Error.OutOfMemory;
        defer a.free(id);
        return sops.decrypt(self.io, a, p, id);
    }

    /// write encrypts kv for env using current recipients.
    pub fn write(self: Store, env: []const u8, kv: std.StringHashMap([]const u8)) Error!void {
        const a = self.allocator;
        const recips = try self.recipients(env);
        defer {
            for (recips) |r| a.free(r);
            a.free(recips);
        }
        // Convert to []const []const u8
        var view = a.alloc([]const u8, recips.len) catch return Error.OutOfMemory;
        defer a.free(view);
        for (recips, 0..) |r, i| view[i] = r;

        const path = self.secretsPath(a, env) catch return Error.OutOfMemory;
        defer a.free(path);

        return sops.encrypt(self.io, a, path, kv, view);
    }

    /// set performs read-modify-write of a single key.
    pub fn set(self: Store, env: []const u8, key: []const u8, value: []const u8) Error!void {
        const a = self.allocator;
        var current = try self.read(env);
        defer current.deinit();

        // If key exists, free its old owned strings before overwriting.
        if (current.inner.fetchRemove(key)) |old| {
            a.free(old.key);
            a.free(old.value);
        }
        const k_dup = a.dupe(u8, key) catch return Error.OutOfMemory;
        errdefer a.free(k_dup);
        const v_dup = a.dupe(u8, value) catch return Error.OutOfMemory;
        errdefer a.free(v_dup);
        current.inner.put(k_dup, v_dup) catch return Error.OutOfMemory;

        return self.write(env, current.inner);
    }

    pub const GetResult = struct {
        value: []const u8, // borrowed from `map`
        found: bool,
        map: sops.KvMap,

        pub fn deinit(self: *GetResult) void {
            self.map.deinit();
        }
    };

    /// get fetches a single key. The .found field reports whether it exists.
    /// Caller must call deinit() on the result.
    pub fn get(self: Store, env: []const u8, key: []const u8) Error!GetResult {
        var current = try self.read(env);
        const v = current.inner.get(key);
        return .{
            .value = if (v) |x| x else "",
            .found = v != null,
            .map = current,
        };
    }

    /// keys returns the sorted key list for env. Caller owns the outer slice
    /// (the strings are borrowed from the underlying map; deinit the map via
    /// the returned KvMap).
    pub const KeysResult = struct {
        keys: [][]const u8,
        map: sops.KvMap,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *KeysResult) void {
            self.allocator.free(self.keys);
            self.map.deinit();
        }
    };

    pub fn keys(self: Store, env: []const u8) Error!KeysResult {
        const a = self.allocator;
        var current = try self.read(env);
        var ks = a.alloc([]const u8, current.inner.count()) catch return Error.OutOfMemory;
        var i: usize = 0;
        var it = current.inner.iterator();
        while (it.next()) |e| : (i += 1) ks[i] = e.key_ptr.*;
        std.mem.sort([]const u8, ks, {}, struct {
            fn lt(_: void, a2: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a2, b);
            }
        }.lt);
        return .{ .keys = ks, .map = current, .allocator = a };
    }

    /// pubKey reads the identity file and returns the value after
    /// "# public key: ". Owned slice.
    pub fn pubKey(self: Store) Error![]u8 {
        const a = self.allocator;
        const id = self.identityPath(a) catch return Error.OutOfMemory;
        defer a.free(id);
        const data = std.Io.Dir.cwd().readFileAlloc(self.io, id, a, .limited(64 * 1024)) catch return Error.ReadFailed;
        defer a.free(data);
        const marker = "# public key: ";
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, marker)) {
                const trimmed = std.mem.trim(u8, line[marker.len..], " \t\r");
                return a.dupe(u8, trimmed) catch return Error.OutOfMemory;
            }
        }
        return Error.NoPubKeyMarker;
    }
};

// chmod helper: portable across libc-linked targets.
fn chmod(path: []const u8, mode: u32) !void {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return error.PathTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const c_path = buf[0..path.len :0];
    const rc = std.c.chmod(c_path.ptr, @intCast(mode));
    if (rc != 0) return error.ChmodFailed;
}

// ----------------------------- tests -----------------------------------------

const testing = std.testing;

fn binAvailable(io: std.Io, name: []const u8) bool {
    var child = std.process.spawn(io, .{
        .argv = &.{ name, "--version" },
        .stdout = .ignore,
        .stderr = .ignore,
        .stdin = .ignore,
    }) catch return false;
    _ = child.wait(io) catch return false;
    return true;
}

test "init creates identity and returns age1 pubkey" {
    if (!binAvailable(std.testing.io, "age-keygen")) return error.SkipZigTest;
    const a = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var _path_buf: [4096]u8 = undefined;
    const _path_len = try tmp.dir.realPath(std.testing.io, &_path_buf);
    const root = try a.dupe(u8, _path_buf[0.._path_len]);
    defer a.free(root);

    const s = Store.init(a, std.testing.io, root);
    try s.initStore();
    const pub_key = try s.pubKey();
    defer a.free(pub_key);
    try testing.expect(pub_key.len >= 10);
    try testing.expectEqualStrings("age1", pub_key[0..4]);
}

test "init is idempotent" {
    if (!binAvailable(std.testing.io, "age-keygen")) return error.SkipZigTest;
    const a = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var _path_buf: [4096]u8 = undefined;
    const _path_len = try tmp.dir.realPath(std.testing.io, &_path_buf);
    const root = try a.dupe(u8, _path_buf[0.._path_len]);
    defer a.free(root);

    const s = Store.init(a, std.testing.io, root);
    try s.initStore();
    const p1 = try s.pubKey();
    defer a.free(p1);
    try s.initStore();
    const p2 = try s.pubKey();
    defer a.free(p2);
    try testing.expectEqualStrings(p1, p2);
}

test "set then get roundtrip" {
    if (!binAvailable(std.testing.io, "age-keygen") or !binAvailable(std.testing.io, "sops")) return error.SkipZigTest;
    const a = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var _path_buf: [4096]u8 = undefined;
    const _path_len = try tmp.dir.realPath(std.testing.io, &_path_buf);
    const root = try a.dupe(u8, _path_buf[0.._path_len]);
    defer a.free(root);

    const s = Store.init(a, std.testing.io, root);
    try s.initStore();
    try s.set("dev", "OPENAI_API_KEY", "sk-test-xyz");

    var r = try s.get("dev", "OPENAI_API_KEY");
    defer r.deinit();
    try testing.expect(r.found);
    try testing.expectEqualStrings("sk-test-xyz", r.value);
}

test "read returns empty map when no secrets file" {
    if (!binAvailable(std.testing.io, "age-keygen")) return error.SkipZigTest;
    const a = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var _path_buf: [4096]u8 = undefined;
    const _path_len = try tmp.dir.realPath(std.testing.io, &_path_buf);
    const root = try a.dupe(u8, _path_buf[0.._path_len]);
    defer a.free(root);

    const s = Store.init(a, std.testing.io, root);
    try s.initStore();
    var m = try s.read("dev");
    defer m.deinit();
    try testing.expectEqual(@as(usize, 0), m.inner.count());
}

test "set preserves existing keys" {
    if (!binAvailable(std.testing.io, "age-keygen") or !binAvailable(std.testing.io, "sops")) return error.SkipZigTest;
    const a = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var _path_buf: [4096]u8 = undefined;
    const _path_len = try tmp.dir.realPath(std.testing.io, &_path_buf);
    const root = try a.dupe(u8, _path_buf[0.._path_len]);
    defer a.free(root);

    const s = Store.init(a, std.testing.io, root);
    try s.initStore();
    try s.set("dev", "A", "1");
    try s.set("dev", "B", "2");
    try s.set("dev", "C", "3");

    var m = try s.read("dev");
    defer m.deinit();
    try testing.expectEqualStrings("1", m.inner.get("A").?);
    try testing.expectEqualStrings("2", m.inner.get("B").?);
    try testing.expectEqualStrings("3", m.inner.get("C").?);
}

test "keys returns sorted key list with no values" {
    if (!binAvailable(std.testing.io, "age-keygen") or !binAvailable(std.testing.io, "sops")) return error.SkipZigTest;
    const a = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var _path_buf: [4096]u8 = undefined;
    const _path_len = try tmp.dir.realPath(std.testing.io, &_path_buf);
    const root = try a.dupe(u8, _path_buf[0.._path_len]);
    defer a.free(root);

    const s = Store.init(a, std.testing.io, root);
    try s.initStore();
    try s.set("dev", "Z", "v");
    try s.set("dev", "A", "v");
    try s.set("dev", "M", "v");

    var r = try s.keys("dev");
    defer r.deinit();

    const want = [_][]const u8{ "A", "M", "Z" };
    try testing.expectEqual(want.len, r.keys.len);
    for (want, 0..) |w, i| try testing.expectEqualStrings(w, r.keys[i]);
}
