//! envparse: parse .env file content into ordered key-value entries.
//!
//! Port of pkg/envparse from the Go codebase. Parity rules:
//!   - Blank lines and lines whose first non-whitespace char is '#' are skipped.
//!   - Each remaining line is split on the FIRST '=' only; lines without '=' are skipped.
//!   - Key is whitespace-trimmed.
//!   - Value handling:
//!       * If the value begins with '"' or '\'', strip outer quotes (matching quote required).
//!       * Otherwise, a trailing " #" comment is stripped and the remainder is trimmed.
//!   - CRLF tolerated: Go's bufio.Scanner strips trailing \r implicitly via TrimSpace.

const std = @import("std");

pub const Entry = struct {
    key: []const u8,
    value: []const u8,
};

/// Parse returns a slice of Entry whose backing memory is owned by `allocator`.
/// Each Entry.key and Entry.value points into newly allocated buffers (independent
/// from the input slice), so the caller is free to drop `content` after the call.
/// Caller owns the result and must call `freeEntries(allocator, entries)`.
pub fn parse(allocator: std.mem.Allocator, content: []const u8) ![]Entry {
    var list = std.ArrayList(Entry).init(allocator);
    errdefer {
        for (list.items) |e| {
            allocator.free(e.key);
            allocator.free(e.value);
        }
        list.deinit();
    }

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key_raw = line[0..eq_idx];
        const val_raw = line[eq_idx + 1 ..];

        const key_trim = std.mem.trim(u8, key_raw, " \t\r");
        const val_trim = std.mem.trim(u8, val_raw, " \t\r");
        const val_parsed = parseValue(val_trim);

        const key_dup = try allocator.dupe(u8, key_trim);
        errdefer allocator.free(key_dup);
        const val_dup = try allocator.dupe(u8, val_parsed);
        try list.append(.{ .key = key_dup, .value = val_dup });
    }

    return list.toOwnedSlice();
}

pub fn freeEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| {
        allocator.free(e.key);
        allocator.free(e.value);
    }
    allocator.free(entries);
}

fn parseValue(s: []const u8) []const u8 {
    if (s.len == 0) return s;
    const q = s[0];
    if (q == '"' or q == '\'') {
        // Find matching closing quote.
        if (std.mem.indexOfScalar(u8, s[1..], q)) |end_rel| {
            return s[1 .. 1 + end_rel];
        }
        return s;
    }
    // Strip trailing " #..." comment.
    if (std.mem.indexOf(u8, s, " #")) |i| {
        return std.mem.trim(u8, s[0..i], " \t\r");
    }
    return s;
}

// ----------------------------- tests -----------------------------------------

const testing = std.testing;

fn expectEntries(input: []const u8, want: []const Entry) !void {
    const a = testing.allocator;
    const got = try parse(a, input);
    defer freeEntries(a, got);
    try testing.expectEqual(want.len, got.len);
    for (want, 0..) |w, i| {
        try testing.expectEqualStrings(w.key, got[i].key);
        try testing.expectEqualStrings(w.value, got[i].value);
    }
}

test "single simple assignment" {
    try expectEntries("KEY=value\n", &.{.{ .key = "KEY", .value = "value" }});
}

test "multiple lines preserve order" {
    try expectEntries("A=1\nB=2\nC=3\n", &.{
        .{ .key = "A", .value = "1" },
        .{ .key = "B", .value = "2" },
        .{ .key = "C", .value = "3" },
    });
}

test "blank lines and comments ignored" {
    try expectEntries("# header\n\nA=1\n   # indented comment\nB=2\n", &.{
        .{ .key = "A", .value = "1" },
        .{ .key = "B", .value = "2" },
    });
}

test "whitespace around key trimmed" {
    try expectEntries("  A = 1\nB=2\n", &.{
        .{ .key = "A", .value = "1" },
        .{ .key = "B", .value = "2" },
    });
}

test "double-quoted value strips outer quotes" {
    try expectEntries("A=\"hello world\"\n", &.{.{ .key = "A", .value = "hello world" }});
}

test "single-quoted value strips outer quotes" {
    try expectEntries("A='hello world'\n", &.{.{ .key = "A", .value = "hello world" }});
}

test "empty value valid" {
    try expectEntries("A=\nB=2\n", &.{
        .{ .key = "A", .value = "" },
        .{ .key = "B", .value = "2" },
    });
}

test "inline comment after unquoted value" {
    try expectEntries("A=1 # trailing\nB=2\n", &.{
        .{ .key = "A", .value = "1" },
        .{ .key = "B", .value = "2" },
    });
}

test "hash inside quoted value preserved" {
    try expectEntries("A=\"not # a comment\"\n", &.{.{ .key = "A", .value = "not # a comment" }});
}

test "equals inside value preserved (split first only)" {
    try expectEntries("URL=https://x.com?a=b&c=d\n", &.{.{ .key = "URL", .value = "https://x.com?a=b&c=d" }});
}

test "trailing CRLF tolerated" {
    try expectEntries("A=1\r\nB=2\r\n", &.{
        .{ .key = "A", .value = "1" },
        .{ .key = "B", .value = "2" },
    });
}
