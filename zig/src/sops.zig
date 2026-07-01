//! sops: wrapper around the `sops` binary for encrypt/decrypt of dotenv files.
//!
//! Port of internal/sopswrap. Parity rules:
//!   - encrypt: write a temp dotenv file (sorted KEY=VALUE\n), then call
//!     `sops encrypt --input-type dotenv --output-type dotenv --age <csv> <tmp>`
//!     capturing stdout into dst. Requires >=1 recipient.
//!   - decrypt: call `sops decrypt --input-type dotenv --output-type dotenv <src>`
//!     with SOPS_AGE_KEY_FILE=<identity> in the env. Parse stdout with envparse.

const std = @import("std");
const envparse = @import("envparse.zig");

pub const Error = error{
    NoRecipients,
    SopsEncryptFailed,
    SopsDecryptFailed,
    MkdirFailed,
    WriteFailed,
    TempFileFailed,
    OutOfMemory,
};

/// Render a sorted dotenv document from kv. Returned slice is owned.
pub fn renderDotenv(allocator: std.mem.Allocator, kv: std.StringHashMap([]const u8)) ![]u8 {
    // Collect keys
    var keys = try allocator.alloc([]const u8, kv.count());
    defer allocator.free(keys);
    var i: usize = 0;
    var it = kv.iterator();
    while (it.next()) |e| : (i += 1) keys[i] = e.key_ptr.*;
    std.mem.sort([]const u8, keys, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    // Compute total length
    var total: usize = 0;
    for (keys) |k| {
        const v = kv.get(k) orelse "";
        total += k.len + 1 + v.len + 1;
    }
    var buf = try allocator.alloc(u8, total);
    var off: usize = 0;
    for (keys) |k| {
        const v = kv.get(k) orelse "";
        @memcpy(buf[off .. off + k.len], k);
        off += k.len;
        buf[off] = '=';
        off += 1;
        @memcpy(buf[off .. off + v.len], v);
        off += v.len;
        buf[off] = '\n';
        off += 1;
    }
    return buf;
}

/// Encrypt kv into a sops dotenv file at dst, using the given age recipients.
pub fn encrypt(
    io: std.Io,
    allocator: std.mem.Allocator,
    dst: []const u8,
    kv: std.StringHashMap([]const u8),
    recipients: []const []const u8,
) Error!void {
    if (recipients.len == 0) return Error.NoRecipients;

    // mkdir -p (dirname dst)
    if (std.fs.path.dirname(dst)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch return Error.MkdirFailed;
    }

    const plain = try renderDotenv(allocator, kv);
    defer allocator.free(plain);

    // Create a temp file in the same directory as dst (matches Go behavior).
    const dst_dir_path = std.fs.path.dirname(dst) orelse ".";
    var dst_dir = std.Io.Dir.cwd().openDir(io, dst_dir_path, .{}) catch return Error.TempFileFailed;
    defer dst_dir.close(io);

    // Generate a temp name. Go uses os.CreateTemp(dir, ".envless-enc-*.env").
    var rand_buf: [16]u8 = undefined;
    std.Io.randomSecure(io, &rand_buf) catch return Error.TempFileFailed;
    var name_buf: [64]u8 = undefined;
    const tmp_name = std.fmt.bufPrint(&name_buf, ".envless-enc-{x}.env", .{rand_buf}) catch return Error.TempFileFailed;

    {
        var tmp_file = dst_dir.createFile(io, tmp_name, .{ .truncate = true }) catch return Error.TempFileFailed;
        defer tmp_file.close(io);
        var tmp_w_buf: [4096]u8 = undefined;
        var tw = tmp_file.writer(io, &tmp_w_buf);
        tw.interface.writeAll(plain) catch return Error.WriteFailed;
        tw.flush() catch return Error.WriteFailed;
    }
    // Ensure temp file is removed even on failure.
    defer dst_dir.deleteFile(io, tmp_name) catch {};

    const tmp_full = std.fs.path.join(allocator, &.{ dst_dir_path, tmp_name }) catch return Error.OutOfMemory;
    defer allocator.free(tmp_full);

    // Join recipients with comma.
    var total: usize = 0;
    for (recipients, 0..) |r, idx| {
        total += r.len;
        if (idx + 1 < recipients.len) total += 1;
    }
    var csv = allocator.alloc(u8, total) catch return Error.OutOfMemory;
    defer allocator.free(csv);
    var co: usize = 0;
    for (recipients, 0..) |r, idx| {
        @memcpy(csv[co .. co + r.len], r);
        co += r.len;
        if (idx + 1 < recipients.len) {
            csv[co] = ',';
            co += 1;
        }
    }

    const argv = [_][]const u8{
        "sops",
        "encrypt",
        "--input-type", "dotenv",
        "--output-type", "dotenv",
        "--age",          csv,
        tmp_full,
    };

    const r = std.process.run(allocator, io, .{
        .argv = &argv,
        .stdout_limit = .limited(64 * 1024 * 1024),
    }) catch return Error.SopsEncryptFailed;
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    switch (r.term) {
        .exited => |code| if (code != 0) return Error.SopsEncryptFailed,
        else => return Error.SopsEncryptFailed,
    }

    // Write captured stdout to dst.
    var out_file = std.Io.Dir.cwd().createFile(io, dst, .{ .truncate = true }) catch return Error.WriteFailed;
    defer out_file.close(io);
    var out_w_buf: [4096]u8 = undefined;
    var ow = out_file.writer(io, &out_w_buf);
    ow.interface.writeAll(r.stdout) catch return Error.WriteFailed;
    ow.flush() catch return Error.WriteFailed;
}

/// Decrypted KV map. Caller owns: free each key/value and the map itself.
pub const KvMap = struct {
    inner: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *KvMap) void {
        var it = self.inner.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.inner.deinit();
    }
};

/// Decrypt a sops-encrypted dotenv file. identity_file may be empty to skip
/// setting SOPS_AGE_KEY_FILE (matches Go behavior when identityFile == "").
pub fn decrypt(
    io: std.Io,
    allocator: std.mem.Allocator,
    src: []const u8,
    identity_file: []const u8,
) Error!KvMap {
    const argv = [_][]const u8{
        "sops",
        "decrypt",
        "--input-type", "dotenv",
        "--output-type", "dotenv",
        src,
    };

    // Build env: parent + SOPS_AGE_KEY_FILE if identity_file is set.
    // We use environ_map to pass the env var directly to the child process,
    // avoiding shell injection via sh -c (security: this is a secrets manager).
    var env_map: ?std.process.Environ.Map = null;
    defer if (env_map != null) env_map.?.deinit();
    if (identity_file.len != 0) {
        env_map = std.process.Environ.Map.init(allocator);
        var i: usize = 0;
        while (std.c.environ[i]) |entry_ptr| : (i += 1) {
            const e = std.mem.span(entry_ptr);
            const eq = std.mem.indexOfScalar(u8, e, '=') orelse continue;
            env_map.?.put(e[0..eq], e[eq + 1 ..]) catch return Error.OutOfMemory;
        }
        env_map.?.put("SOPS_AGE_KEY_FILE", identity_file) catch return Error.OutOfMemory;
    }

    const r = std.process.run(allocator, io, .{
        .argv = &argv,
        .stdout_limit = .limited(64 * 1024 * 1024),
        .environ_map = if (env_map != null) &env_map.? else null,
    }) catch return Error.SopsDecryptFailed;
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    switch (r.term) {
        .exited => |code| if (code != 0) return Error.SopsDecryptFailed,
        else => return Error.SopsDecryptFailed,
    }

    // Parse the decrypted dotenv output.
    const entries = envparse.parse(allocator, r.stdout) catch return Error.OutOfMemory;
    defer allocator.free(entries);
    // entries' key/value slices are heap-owned. Move them into the map.

    var map = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var mit = map.iterator();
        while (mit.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        map.deinit();
    }

    for (entries) |e| {
        // put() does not duplicate keys; ownership transfers from `entries`.
        // If the key already exists in the map, free the old strings before overwriting.
        if (map.fetchRemove(e.key)) |old| {
            allocator.free(old.key);
            allocator.free(old.value);
        }
        map.put(e.key, e.value) catch return Error.OutOfMemory;
    }

    return .{ .inner = map, .allocator = allocator };
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

test "renderDotenv sorts keys and emits KEY=VALUE\\n" {
    const a = testing.allocator;
    var kv = std.StringHashMap([]const u8).init(a);
    defer kv.deinit();
    try kv.put("Z", "1");
    try kv.put("A", "2");
    try kv.put("M", "");
    const out = try renderDotenv(a, kv);
    defer a.free(out);
    try testing.expectEqualStrings("A=2\nM=\nZ=1\n", out);
}

test "renderDotenv empty map yields empty buffer" {
    const a = testing.allocator;
    var kv = std.StringHashMap([]const u8).init(a);
    defer kv.deinit();
    const out = try renderDotenv(a, kv);
    defer a.free(out);
    try testing.expectEqualStrings("", out);
}

// Roundtrip test: requires sops + age-keygen to be on PATH. Skips otherwise.
fn parsePubKey(content: []const u8) ?[]const u8 {
    const marker = "# public key: ";
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, marker)) {
            return std.mem.trim(u8, line[marker.len..], " \t\r");
        }
    }
    return null;
}

test "encrypt/decrypt roundtrip with age + sops" {
    if (!binAvailable(std.testing.io, "sops") or !binAvailable(std.testing.io, "age-keygen")) {
        return error.SkipZigTest;
    }
    const a = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var _path_buf: [4096]u8 = undefined;
    const _path_len = try tmp.dir.realPath(std.testing.io, &_path_buf);
    const tmp_path = try a.dupe(u8, _path_buf[0.._path_len]);
    defer a.free(tmp_path);

    const id_path = try std.fs.path.join(a, &.{ tmp_path, "id.key" });
    defer a.free(id_path);
    const dst_path = try std.fs.path.join(a, &.{ tmp_path, "secrets.env" });
    defer a.free(dst_path);

    // age-keygen -o <id_path>
    {
        var child = try std.process.spawn(std.testing.io, .{
            .argv = &.{ "age-keygen", "-o", id_path },
            .stdout = .ignore,
            .stderr = .ignore,
            .stdin = .ignore,
        });
        const t = try child.wait(std.testing.io);
        switch (t) {
            .exited => |c| try testing.expectEqual(@as(u8, 0), c),
            else => return error.AgeKeygenFailed,
        }
    }
    const id_content = try tmp.dir.readFileAlloc(std.testing.io, "id.key", a, .limited(16 * 1024));
    defer a.free(id_content);
    const pub_slice = parsePubKey(id_content) orelse return error.NoPubKey;
    const pub_owned = try a.dupe(u8, pub_slice);
    defer a.free(pub_owned);

    var kv = std.StringHashMap([]const u8).init(a);
    defer kv.deinit();
    try kv.put("OPENAI_API_KEY", "sk-test-xyz");
    try kv.put("DATABASE_URL", "postgres://u:p@h:5432/db");
    try kv.put("EMPTY", "");

    const recipients = [_][]const u8{pub_owned};
    try encrypt(std.testing.io, a, dst_path, kv, &recipients);

    var got = try decrypt(std.testing.io, a, dst_path, id_path);
    defer got.deinit();

    try testing.expectEqual(@as(usize, 3), got.inner.count());
    try testing.expectEqualStrings("sk-test-xyz", got.inner.get("OPENAI_API_KEY").?);
    try testing.expectEqualStrings("postgres://u:p@h:5432/db", got.inner.get("DATABASE_URL").?);
    try testing.expectEqualStrings("", got.inner.get("EMPTY").?);
}
