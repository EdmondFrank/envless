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
    allocator: std.mem.Allocator,
    dst: []const u8,
    kv: std.StringHashMap([]const u8),
    recipients: []const []const u8,
) Error!void {
    if (recipients.len == 0) return Error.NoRecipients;

    // mkdir -p (dirname dst)
    if (std.fs.path.dirname(dst)) |dir| {
        std.fs.cwd().makePath(dir) catch return Error.MkdirFailed;
    }

    const plain = try renderDotenv(allocator, kv);
    defer allocator.free(plain);

    // Create a temp file in the same directory as dst (matches Go behavior).
    const dst_dir_path = std.fs.path.dirname(dst) orelse ".";
    var dst_dir = std.fs.cwd().openDir(dst_dir_path, .{}) catch return Error.TempFileFailed;
    defer dst_dir.close();

    // Generate a temp name. Go uses os.CreateTemp(dir, ".envless-enc-*.env").
    var rand_buf: [16]u8 = undefined;
    std.crypto.random.bytes(&rand_buf);
    var name_buf: [64]u8 = undefined;
    const tmp_name = std.fmt.bufPrint(&name_buf, ".envless-enc-{}.env", .{std.fmt.fmtSliceHexLower(&rand_buf)}) catch return Error.TempFileFailed;

    {
        var tmp_file = dst_dir.createFile(tmp_name, .{ .truncate = true, .mode = 0o600 }) catch return Error.TempFileFailed;
        defer tmp_file.close();
        tmp_file.writeAll(plain) catch return Error.WriteFailed;
    }
    // Ensure temp file is removed even on failure.
    defer dst_dir.deleteFile(tmp_name) catch {};

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

    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch return Error.SopsEncryptFailed;

    // Drain stdout/stderr.
    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();

    child.collectOutput(&stdout_buf, &stderr_buf, 64 * 1024 * 1024) catch return Error.SopsEncryptFailed;
    const term = child.wait() catch return Error.SopsEncryptFailed;
    switch (term) {
        .Exited => |code| if (code != 0) return Error.SopsEncryptFailed,
        else => return Error.SopsEncryptFailed,
    }

    // Write captured stdout to dst with mode 0o644.
    var out_file = std.fs.cwd().createFile(dst, .{ .truncate = true, .mode = 0o644 }) catch return Error.WriteFailed;
    defer out_file.close();
    out_file.writeAll(stdout_buf.items) catch return Error.WriteFailed;
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

    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    // Build env: parent + SOPS_AGE_KEY_FILE if non-empty.
    var env_map = std.process.getEnvMap(allocator) catch return Error.OutOfMemory;
    defer env_map.deinit();
    if (identity_file.len != 0) {
        env_map.put("SOPS_AGE_KEY_FILE", identity_file) catch return Error.OutOfMemory;
    }
    child.env_map = &env_map;

    child.spawn() catch return Error.SopsDecryptFailed;

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();

    child.collectOutput(&stdout_buf, &stderr_buf, 64 * 1024 * 1024) catch return Error.SopsDecryptFailed;
    const term = child.wait() catch return Error.SopsDecryptFailed;
    switch (term) {
        .Exited => |code| if (code != 0) return Error.SopsDecryptFailed,
        else => return Error.SopsDecryptFailed,
    }

    // Parse the decrypted dotenv output.
    const entries = envparse.parse(allocator, stdout_buf.items) catch return Error.OutOfMemory;
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

fn binAvailable(name: []const u8) bool {
    const a = testing.allocator;
    const argv = [_][]const u8{ "sh", "-c", "" };
    _ = argv;
    var child = std.process.Child.init(&.{ name, "--version" }, a);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;
    const term = child.wait() catch return false;
    _ = term;
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
    if (!binAvailable("sops") or !binAvailable("age-keygen")) {
        return error.SkipZigTest;
    }
    const a = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(tmp_path);

    const id_path = try std.fs.path.join(a, &.{ tmp_path, "id.key" });
    defer a.free(id_path);
    const dst_path = try std.fs.path.join(a, &.{ tmp_path, "secrets.env" });
    defer a.free(dst_path);

    // age-keygen -o <id_path>
    {
        var child = std.process.Child.init(&.{ "age-keygen", "-o", id_path }, a);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        try child.spawn();
        const t = try child.wait();
        switch (t) {
            .Exited => |c| try testing.expectEqual(@as(u8, 0), c),
            else => return error.AgeKeygenFailed,
        }
    }
    const id_content = try tmp.dir.readFileAlloc(a, "id.key", 16 * 1024);
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
    try encrypt(a, dst_path, kv, &recipients);

    var got = try decrypt(a, dst_path, id_path);
    defer got.deinit();

    try testing.expectEqual(@as(usize, 3), got.inner.count());
    try testing.expectEqualStrings("sk-test-xyz", got.inner.get("OPENAI_API_KEY").?);
    try testing.expectEqualStrings("postgres://u:p@h:5432/db", got.inner.get("DATABASE_URL").?);
    try testing.expectEqualStrings("", got.inner.get("EMPTY").?);
}
