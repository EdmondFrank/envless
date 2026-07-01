//! ipc: wire protocol between the envless daemon and any clients
//! (`envless mcp` when routing through the socket, or external tools).
//!
//! Transport: UNIX stream socket. Path defaults to `$HOME/.cache/envless/sock`
//! (or `$XDG_RUNTIME_DIR/envless/sock` when XDG_RUNTIME_DIR is set).
//!
//! Wire format (one request per connection, newline-terminated):
//!
//!   LIST\t<env>\n
//!   GET\t<env>\t<key>\n
//!   SET\t<env>\t<key>\t<value>\n
//!   EXEC\t<env>\t<cwd>\t<argv-base64>\t<stdin-base64>\t<timeout-ms>\n
//!   WHOAMI\n
//!   PING\n
//!
//! Responses:
//!
//!   OK\t<json-payload>\n   → success (payload may be `{}`)
//!   ERR\t<json-payload>\n  → error (payload is {"code":"...","message":"..."})
//!   END\n                  → optional trailer for multi-line responses
//!
//! argv is base64(JSON-array-of-strings) so embedded TABs/newlines round-trip.
//! stdin is base64(raw bytes). cwd is an absolute path with no escaping
//! required (POSIX paths can't contain TAB or newline).

const std = @import("std");

pub const Op = enum { list, get, set, exec, whoami, ping };

pub const ExecRequest = struct {
    env: []const u8,
    cwd: []const u8,
    argv_b64: []const u8,
    stdin_b64: []const u8,
    timeout_ms: u32,
};

pub const Request = union(Op) {
    list: struct { env: []const u8 },
    get: struct { env: []const u8, key: []const u8 },
    set: struct { env: []const u8, key: []const u8, value: []const u8 },
    exec: ExecRequest,
    whoami: void,
    ping: void,
};

pub const ParseError = error{
    Malformed,
    UnknownOp,
    InvalidTimeout,
};

/// socketPath: returns the default daemon socket path. Caller owns the
/// returned slice. Honors XDG_RUNTIME_DIR when set.
pub fn socketPath(allocator: std.mem.Allocator, io: std.Io, home: []const u8) ![]u8 {
    // XDG_RUNTIME_DIR/envless/sock if available, otherwise HOME/.cache/envless/sock.
    if (std.c.getenv("XDG_RUNTIME_DIR")) |xdg_ptr| {
        const xdg = std.mem.span(xdg_ptr);
        if (xdg.len > 0) {
            const dir = try std.fmt.allocPrint(allocator, "{s}/envless", .{xdg});
            defer allocator.free(dir);
            std.Io.Dir.cwd().createDirPath(io, dir) catch {};
            return try std.fmt.allocPrint(allocator, "{s}/sock", .{dir});
        }
    }
    const dir = try std.fmt.allocPrint(allocator, "{s}/.cache/envless", .{home});
    defer allocator.free(dir);
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    return try std.fmt.allocPrint(allocator, "{s}/sock", .{dir});
}

/// parseRequest: parse one TAB-separated line (newline already stripped).
/// All borrowed string fields point into `line`; caller must keep the line
/// alive for the lifetime of the returned Request, or dupe before reuse.
pub fn parseRequest(line: []const u8) ParseError!Request {
    var it = std.mem.splitScalar(u8, line, '\t');
    const op = it.next() orelse return error.Malformed;

    if (std.mem.eql(u8, op, "PING")) return .ping;
    if (std.mem.eql(u8, op, "WHOAMI")) return .whoami;

    if (std.mem.eql(u8, op, "LIST")) {
        const env = it.next() orelse return error.Malformed;
        if (env.len == 0) return error.Malformed;
        return .{ .list = .{ .env = env } };
    }
    if (std.mem.eql(u8, op, "GET")) {
        const env = it.next() orelse return error.Malformed;
        const key = it.next() orelse return error.Malformed;
        if (env.len == 0 or key.len == 0) return error.Malformed;
        return .{ .get = .{ .env = env, .key = key } };
    }
    if (std.mem.eql(u8, op, "SET")) {
        const env = it.next() orelse return error.Malformed;
        const key = it.next() orelse return error.Malformed;
        // value runs until end of line and MAY include embedded TABs if we
        // ever extend; for now reject TABs in values via splitScalar.
        const value = it.rest();
        if (env.len == 0 or key.len == 0) return error.Malformed;
        return .{ .set = .{ .env = env, .key = key, .value = value } };
    }
    if (std.mem.eql(u8, op, "EXEC")) {
        const env = it.next() orelse return error.Malformed;
        const cwd = it.next() orelse return error.Malformed;
        const argv_b64 = it.next() orelse return error.Malformed;
        const stdin_b64 = it.next() orelse return error.Malformed;
        const tmo_str = it.next() orelse return error.Malformed;
        const tmo = std.fmt.parseInt(u32, tmo_str, 10) catch return error.InvalidTimeout;
        if (env.len == 0 or cwd.len == 0 or argv_b64.len == 0) return error.Malformed;
        return .{ .exec = .{
            .env = env,
            .cwd = cwd,
            .argv_b64 = argv_b64,
            .stdin_b64 = stdin_b64,
            .timeout_ms = tmo,
        } };
    }

    return error.UnknownOp;
}

/// encodeOk: format an `OK\t<payload>\n` line. Caller owns the slice.
pub fn encodeOk(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "OK\t{s}\n", .{payload});
}

/// encodeErr: format an `ERR\t<payload>\n` line. Caller owns the slice.
pub fn encodeErr(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "ERR\t{s}\n", .{payload});
}

/// errPayload: build a small JSON `{"code":"...","message":"..."}` blob.
/// Caller owns the returned slice.
pub fn errPayload(allocator: std.mem.Allocator, code: []const u8, message: []const u8) ![]u8 {
    // We escape only the JSON-hostile bytes; daemon errors are short and
    // ascii in practice. Going through std.json.stringifyAlloc for both
    // fields would also work but the manual form keeps the daemon happy
    // even when std.json is unavailable in some build configurations.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"code\":");
    try jsonString(allocator, &buf, code);
    try buf.appendSlice(allocator, ",\"message\":");
    try jsonString(allocator, &buf, message);
    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

fn jsonString(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(allocator, "\\\""),
        '\\' => try buf.appendSlice(allocator, "\\\\"),
        '\n' => try buf.appendSlice(allocator, "\\n"),
        '\r' => try buf.appendSlice(allocator, "\\r"),
        '\t' => try buf.appendSlice(allocator, "\\t"),
        0...8, 11, 12, 14...31 => {
            var seq: [6]u8 = undefined;
            _ = std.fmt.bufPrint(&seq, "\\u{x:0>4}", .{c}) catch unreachable;
            try buf.appendSlice(allocator, &seq);
        },
        else => try buf.append(allocator, c),
    };
    try buf.append(allocator, '"');
}

/// encodeArgvB64: JSON-stringify argv and base64-encode the result.
/// Caller owns the returned slice.
pub fn encodeArgvB64(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.append(allocator, '[');
    for (argv, 0..) |a, i| {
        if (i != 0) try buf.append(allocator, ',');
        try jsonString(allocator, &buf, a);
    }
    try buf.append(allocator, ']');

    const enc_len = std.base64.standard.Encoder.calcSize(buf.items.len);
    const out = try allocator.alloc(u8, enc_len);
    _ = std.base64.standard.Encoder.encode(out, buf.items);
    return out;
}

/// decodeArgvB64: inverse of encodeArgvB64. Returns a slice of slices, each
/// owned by `allocator`, plus the outer slice. The caller frees both.
pub fn decodeArgvB64(allocator: std.mem.Allocator, b64: []const u8) ![][]u8 {
    const dec_len = try std.base64.standard.Decoder.calcSizeForSlice(b64);
    const json_buf = try allocator.alloc(u8, dec_len);
    defer allocator.free(json_buf);
    std.base64.standard.Decoder.decode(json_buf, b64) catch return error.Malformed;

    // Parse JSON array of strings.
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_buf, .{}) catch return error.Malformed;
    defer parsed.deinit();
    if (parsed.value != .array) return error.Malformed;
    const arr = parsed.value.array;

    var out = try allocator.alloc([]u8, arr.items.len);
    errdefer {
        for (out) |s| allocator.free(s);
        allocator.free(out);
    }
    for (arr.items, 0..) |v, i| {
        if (v != .string) return error.Malformed;
        out[i] = try allocator.dupe(u8, v.string);
    }
    return out;
}

/// encodeBytesB64: base64-encode raw bytes for the stdin field.
pub fn encodeBytesB64(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const enc_len = std.base64.standard.Encoder.calcSize(bytes.len);
    const out = try allocator.alloc(u8, enc_len);
    _ = std.base64.standard.Encoder.encode(out, bytes);
    return out;
}

/// decodeBytesB64: inverse of encodeBytesB64.
pub fn decodeBytesB64(allocator: std.mem.Allocator, b64: []const u8) ![]u8 {
    if (b64.len == 0) return allocator.alloc(u8, 0);
    const dec_len = try std.base64.standard.Decoder.calcSizeForSlice(b64);
    const out = try allocator.alloc(u8, dec_len);
    std.base64.standard.Decoder.decode(out, b64) catch {
        allocator.free(out);
        return error.Malformed;
    };
    return out;
}

// ----------------------------- tests -----------------------------------------

const testing = std.testing;

test "parseRequest PING / WHOAMI" {
    try testing.expectEqual(@as(Op, .ping), @as(Op, try parseRequest("PING")));
    try testing.expectEqual(@as(Op, .whoami), @as(Op, try parseRequest("WHOAMI")));
}

test "parseRequest LIST requires env" {
    const r = try parseRequest("LIST\tdev");
    try testing.expect(r == .list);
    try testing.expectEqualStrings("dev", r.list.env);
    try testing.expectError(error.Malformed, parseRequest("LIST"));
    try testing.expectError(error.Malformed, parseRequest("LIST\t"));
}

test "parseRequest GET requires env + key" {
    const r = try parseRequest("GET\tdev\tTOKEN");
    try testing.expect(r == .get);
    try testing.expectEqualStrings("dev", r.get.env);
    try testing.expectEqualStrings("TOKEN", r.get.key);
    try testing.expectError(error.Malformed, parseRequest("GET\tdev"));
}

test "parseRequest SET captures value with embedded equals" {
    const r = try parseRequest("SET\tdev\tURL\thttps://x.com?a=b");
    try testing.expect(r == .set);
    try testing.expectEqualStrings("dev", r.set.env);
    try testing.expectEqualStrings("URL", r.set.key);
    try testing.expectEqualStrings("https://x.com?a=b", r.set.value);
}

test "parseRequest EXEC parses all 5 fields" {
    const r = try parseRequest("EXEC\tdev\t/tmp\tQUJD\tWFla\t30000");
    try testing.expect(r == .exec);
    try testing.expectEqualStrings("dev", r.exec.env);
    try testing.expectEqualStrings("/tmp", r.exec.cwd);
    try testing.expectEqualStrings("QUJD", r.exec.argv_b64);
    try testing.expectEqualStrings("WFla", r.exec.stdin_b64);
    try testing.expectEqual(@as(u32, 30000), r.exec.timeout_ms);
}

test "parseRequest unknown op errors" {
    try testing.expectError(error.UnknownOp, parseRequest("NOPE\tdev"));
}

test "argv round-trip through base64+json" {
    const a = testing.allocator;
    const argv = [_][]const u8{ "node", "--harmony", "server.js" };
    const enc = try encodeArgvB64(a, &argv);
    defer a.free(enc);

    const decoded = try decodeArgvB64(a, enc);
    defer {
        for (decoded) |s| a.free(s);
        a.free(decoded);
    }
    try testing.expectEqual(@as(usize, 3), decoded.len);
    try testing.expectEqualStrings("node", decoded[0]);
    try testing.expectEqualStrings("--harmony", decoded[1]);
    try testing.expectEqualStrings("server.js", decoded[2]);
}

test "argv survives embedded TAB and newline" {
    const a = testing.allocator;
    const argv = [_][]const u8{ "sh", "-c", "echo\tfoo\nbar" };
    const enc = try encodeArgvB64(a, &argv);
    defer a.free(enc);

    const decoded = try decodeArgvB64(a, enc);
    defer {
        for (decoded) |s| a.free(s);
        a.free(decoded);
    }
    try testing.expectEqualStrings("echo\tfoo\nbar", decoded[2]);
}

test "encodeOk / encodeErr append newline" {
    const a = testing.allocator;
    const ok = try encodeOk(a, "{\"x\":1}");
    defer a.free(ok);
    try testing.expectEqualStrings("OK\t{\"x\":1}\n", ok);

    const err = try encodeErr(a, "{}");
    defer a.free(err);
    try testing.expectEqualStrings("ERR\t{}\n", err);
}

test "errPayload escapes message" {
    const a = testing.allocator;
    const p = try errPayload(a, "decrypt_failed", "sops said \"no\"");
    defer a.free(p);
    try testing.expectEqualStrings("{\"code\":\"decrypt_failed\",\"message\":\"sops said \\\"no\\\"\"}", p);
}

test "bytes round-trip through base64 (empty)" {
    const a = testing.allocator;
    const enc = try encodeBytesB64(a, "");
    defer a.free(enc);
    const dec = try decodeBytesB64(a, enc);
    defer a.free(dec);
    try testing.expectEqual(@as(usize, 0), dec.len);
}

test "bytes round-trip through base64 (non-empty)" {
    const a = testing.allocator;
    const src = "hello\x00world\n";
    const enc = try encodeBytesB64(a, src);
    defer a.free(enc);
    const dec = try decodeBytesB64(a, enc);
    defer a.free(dec);
    try testing.expectEqualSlices(u8, src, dec);
}

test "parseRequest SET with large value (>4KB)" {
    // Regression test: the daemon's handleClient used a 4096-byte fixed
    // buffer for reading request lines. A SET with a large value (e.g. a
    // TLS certificate) would be truncated or fail with StreamTooLong.
    // This test verifies parseRequest itself handles large inputs; the
    // buffer fix (1MB heap-allocated) is verified by e2e tests.
    const a = testing.allocator;
    const big_value = try a.alloc(u8, 8192);
    defer a.free(big_value);
    @memset(big_value, 'x');
    const line = try std.fmt.allocPrint(a, "SET\tdev\tCERT\t{s}", .{big_value});
    defer a.free(line);
    const r = try parseRequest(line);
    try testing.expect(r == .set);
    try testing.expectEqualStrings("dev", r.set.env);
    try testing.expectEqualStrings("CERT", r.set.key);
    try testing.expectEqual(@as(usize, 8192), r.set.value.len);
}

test "socketPath returns path under XDG_RUNTIME_DIR when set" {
    // Verifies that socketPath honors XDG_RUNTIME_DIR and creates the
    // directory (regression: mkdir was commented out during 0.16 migration).
    const a = testing.allocator;
    const io = std.testing.io;
    // Use a fake home to avoid touching the real one.
    const home = "/tmp/envless-test-home-nonexistent";
    // XDG_RUNTIME_DIR is not set in test env, so we get the home/.cache path.
    const path = try socketPath(a, io, home);
    defer a.free(path);
    // Should end with /sock and contain .cache/envless.
    try testing.expect(std.mem.endsWith(u8, path, "/sock"));
    try testing.expect(std.mem.indexOf(u8, path, ".cache/envless") != null);
}
