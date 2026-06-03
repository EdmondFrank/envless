//! execenv: build process environments and run commands with injected secrets.
//!
//! Port of internal/execenv from the Go codebase. Parity rules:
//!   - buildEnv merges parent env with provided KV; KV overrides parent.
//!   - Output is deterministic: sorted lexicographically as KEY=VALUE strings.
//!   - Parent entries that lack '=' are dropped (matches Go's strings.Cut).
//!   - run() invokes argv with the supplied env, propagating exit codes via ExitError.

const std = @import("std");

/// ExitError signals that a child process exited with a non-zero status.
pub const ExitError = error{ChildExitNonZero};

/// Result of run(): either Success or NonZero with the captured exit code.
pub const RunResult = union(enum) {
    success,
    non_zero: u8,
};

pub const RunError = error{
    EmptyArgv,
    Signaled,
    LaunchFailed,
} || std.process.Child.SpawnError || std.mem.Allocator.Error;

/// buildEnv merges the parent env (e.g. from std.process.getEnvMap) with kv,
/// where kv keys override parent keys, returns a sorted []const u8 slice of
/// owned "KEY=VALUE" strings. Caller owns: free each string and the outer slice.
///
/// `parent` is an iterable yielding "KEY=VALUE" strings (matches Go's []string).
pub fn buildEnv(
    allocator: std.mem.Allocator,
    parent: []const []const u8,
    kv: std.StringHashMap([]const u8),
) ![][]const u8 {
    // Merge into a temporary map. We use a string-keyed map and store unowned
    // slices that point into either the parent string or the caller's kv keys.
    var merged = std.StringHashMap([]const u8).init(allocator);
    defer merged.deinit();

    for (parent) |e| {
        const eq = std.mem.indexOfScalar(u8, e, '=') orelse continue;
        const k = e[0..eq];
        const v = e[eq + 1 ..];
        try merged.put(k, v);
    }

    var it = kv.iterator();
    while (it.next()) |entry| {
        try merged.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    var out = try allocator.alloc([]const u8, merged.count());
    errdefer {
        for (out) |s| allocator.free(s);
        allocator.free(out);
    }

    var i: usize = 0;
    var mit = merged.iterator();
    while (mit.next()) |entry| : (i += 1) {
        const k = entry.key_ptr.*;
        const v = entry.value_ptr.*;
        const buf = try allocator.alloc(u8, k.len + 1 + v.len);
        @memcpy(buf[0..k.len], k);
        buf[k.len] = '=';
        @memcpy(buf[k.len + 1 ..], v);
        out[i] = buf;
    }

    std.mem.sort([]const u8, out, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    return out;
}

/// Free a slice returned by buildEnv.
pub fn freeEnv(allocator: std.mem.Allocator, env: [][]const u8) void {
    for (env) |s| allocator.free(s);
    allocator.free(env);
}

/// run executes argv with the given env. argv[0] is resolved via PATH (handled
/// by std.process.Child). Returns .non_zero with the exit code, or .success.
/// May return RunError on launch/setup failure.
///
/// stdin/stdout/stderr handling: nulls mean Ignore (closes the fd). Pass the
/// caller's std.fs.File to inherit.
pub fn run(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    env: []const []const u8,
    stdin: ?std.fs.File,
    stdout: ?std.fs.File,
    stderr: ?std.fs.File,
) RunError!RunResult {
    if (argv.len == 0) return RunError.EmptyArgv;

    // std.process.Child wants *EnvMap, not []const u8 entries. Materialize one.
    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();
    for (env) |e| {
        const eq = std.mem.indexOfScalar(u8, e, '=') orelse continue;
        try env_map.put(e[0..eq], e[eq + 1 ..]);
    }

    var child = std.process.Child.init(argv, allocator);
    child.env_map = &env_map;
    child.stdin_behavior = if (stdin != null) .Inherit else .Ignore;
    child.stdout_behavior = if (stdout != null) .Inherit else .Ignore;
    child.stderr_behavior = if (stderr != null) .Inherit else .Ignore;
    // If a specific file is provided, hook it up. Inherit picks fd 0/1/2 of
    // the parent process, which is what callers want when they pass the
    // process's std{in,out,err} files.

    const term = try child.spawnAndWait();
    return switch (term) {
        .Exited => |code| if (code == 0) .success else .{ .non_zero = code },
        .Signal, .Stopped, .Unknown => RunError.Signaled,
    };
}

// ----------------------------- tests -----------------------------------------

const testing = std.testing;

fn expectEnv(parent: []const []const u8, kv_pairs: []const [2][]const u8, want: []const []const u8) !void {
    const a = testing.allocator;
    var kv = std.StringHashMap([]const u8).init(a);
    defer kv.deinit();
    for (kv_pairs) |p| try kv.put(p[0], p[1]);

    const got = try buildEnv(a, parent, kv);
    defer freeEnv(a, got);

    try testing.expectEqual(want.len, got.len);
    for (want, 0..) |w, i| try testing.expectEqualStrings(w, got[i]);
}

test "kv overrides parent" {
    try expectEnv(
        &.{ "PATH=/usr/bin", "FOO=old" },
        &.{.{ "FOO", "new" }},
        &.{ "FOO=new", "PATH=/usr/bin" },
    );
}

test "kv adds new keys" {
    try expectEnv(
        &.{"PATH=/usr/bin"},
        &.{ .{ "BAR", "1" }, .{ "BAZ", "2" } },
        &.{ "BAR=1", "BAZ=2", "PATH=/usr/bin" },
    );
}

test "empty kv passthrough" {
    try expectEnv(
        &.{ "A=1", "B=2" },
        &.{},
        &.{ "A=1", "B=2" },
    );
}

test "value with equals sign preserved" {
    try expectEnv(
        &.{},
        &.{.{ "URL", "https://x.com?a=b" }},
        &.{"URL=https://x.com?a=b"},
    );
}

test "value with empty string allowed" {
    try expectEnv(
        &.{},
        &.{.{ "A", "" }},
        &.{"A="},
    );
}

test "deterministic sort order" {
    try expectEnv(
        &.{},
        &.{ .{ "Z", "1" }, .{ "A", "2" }, .{ "M", "3" } },
        &.{ "A=2", "M=3", "Z=1" },
    );
}

test "parent entry without equals is dropped" {
    try expectEnv(
        &.{ "BROKEN", "OK=1" },
        &.{},
        &.{"OK=1"},
    );
}

test "run injects env into child" {
    const a = testing.allocator;
    var kv = std.StringHashMap([]const u8).init(a);
    defer kv.deinit();
    try kv.put("ENVLESS_TEST", "hello");
    const env = try buildEnv(a, &.{}, kv);
    defer freeEnv(a, env);

    // Write to a temp file so we can read what the child produced.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(out_path);
    const out_file_path = try std.fs.path.join(a, &.{ out_path, "out.txt" });
    defer a.free(out_file_path);

    // Use sh -c to redirect; ignore stdout via Ignore, file path is hardcoded.
    const script = try std.fmt.allocPrint(a, "echo $ENVLESS_TEST > {s}", .{out_file_path});
    defer a.free(script);
    const argv = [_][]const u8{ "sh", "-c", script };

    const res = try run(a, &argv, env, null, null, null);
    try testing.expectEqual(RunResult.success, res);

    const data = try tmp.dir.readFileAlloc(a, "out.txt", 1024);
    defer a.free(data);
    try testing.expectEqualStrings("hello\n", data);
}

test "run does not leak parent env vars not in env arg" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_real = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(tmp_real);
    const out_file_path = try std.fs.path.join(a, &.{ tmp_real, "env.txt" });
    defer a.free(out_file_path);

    const env_arr = [_][]const u8{"ENVLESS_TEST=only"};
    const script = try std.fmt.allocPrint(a, "env > {s}", .{out_file_path});
    defer a.free(script);
    const argv = [_][]const u8{ "/bin/sh", "-c", script };

    const res = try run(a, &argv, &env_arr, null, null, null);
    try testing.expectEqual(RunResult.success, res);

    const data = try tmp.dir.readFileAlloc(a, "env.txt", 64 * 1024);
    defer a.free(data);

    if (std.mem.indexOf(u8, data, "ENVLESS_TEST=only") == null) {
        std.debug.print("env output:\n{s}\n", .{data});
        return error.TestExpectedSubstring;
    }
    if (std.mem.indexOf(u8, data, "HOME=") != null) {
        std.debug.print("HOME leaked into child env:\n{s}\n", .{data});
        return error.TestExpectedNoLeak;
    }
}

test "run propagates exit code" {
    const a = testing.allocator;
    const argv = [_][]const u8{ "sh", "-c", "exit 7" };
    const res = try run(a, &argv, &.{}, null, null, null);
    switch (res) {
        .non_zero => |code| try testing.expectEqual(@as(u8, 7), code),
        .success => return error.TestExpectedNonZero,
    }
}
