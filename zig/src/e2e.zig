//! End-to-end tests for the envless binary.
//!
//! 1:1 port of e2e/e2e_test.go (which served as the parity oracle during the
//! Go → Zig migration). Each Go `func TestE2E_X` maps to one `test "X" { }`
//! block below. The harness shells out to a prebuilt envless binary located
//! via the BIN env var (set by `zig build e2e`) or falling back to a
//! repo-relative `zig-out/bin/envless` path so it works under
//! `zig build test --test-filter e2e` or direct `zig test` invocations.
//!
//! These tests skip themselves cleanly when their external prerequisites
//! (age-keygen, sops, sh) are not installed, matching the Go skipIfMissing
//! pattern. CI installs both binaries so the skip path is only taken in
//! contributor-local runs without the toolchain.

const std = @import("std");
const testing = std.testing;

// ---------------------------------------------------------------------------
// Harness helpers
// ---------------------------------------------------------------------------

/// Resolve the envless binary path. Order of precedence:
///   1. `BIN` env var — absolute path, used by `zig build e2e` and by
///      contributors who built the binary outside the build graph.
///   2. `zig-out/bin/envless` relative to the current working directory —
///      this is where `b.installArtifact` puts it when the build is rooted
///      at `zig/`, which is the case under `zig build`.
///
/// Returns an owned slice the caller must free.
fn resolveBin(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "BIN")) |bin| {
        return bin;
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }
    // Fallback: cwd-relative path. The zig build runs the test from the
    // zig/ subdirectory; the installed binary is at zig-out/bin/envless.
    return try allocator.dupe(u8, "zig-out/bin/envless");
}

/// Skip the current test if any of `bins` is not on PATH.
fn skipIfMissing(comptime bins: []const []const u8) !void {
    const a = testing.allocator;
    inline for (bins) |b| {
        const ok = lookPath(a, b) catch false;
        if (!ok) return error.SkipZigTest;
    }
}

fn lookPath(allocator: std.mem.Allocator, bin: []const u8) !bool {
    const path_env = std.process.getEnvVarOwned(allocator, "PATH") catch return false;
    defer allocator.free(path_env);
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = try std.fs.path.join(allocator, &.{ dir, bin });
        defer allocator.free(full);
        std.fs.accessAbsolute(full, .{}) catch continue;
        return true;
    }
    return false;
}

/// Output capture from one envless invocation.
const RunOut = struct {
    stdout: []u8, // owned
    stderr: []u8, // owned
    code: u8,

    fn deinit(self: *RunOut, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// Run the envless binary with `args`, cwd at `dir` (if non-empty), and the
/// optional `stdin_text` piped in on standard input. Captures stdout+stderr
/// in memory. Non-zero child exit is NOT an error — the exit code is
/// returned in `RunOut.code` so individual tests can assert on it.
fn runEnvless(
    allocator: std.mem.Allocator,
    bin: []const u8,
    dir: ?[]const u8,
    stdin_text: ?[]const u8,
    args: []const []const u8,
) !RunOut {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append(bin);
    try argv.appendSlice(args);

    var child = std.process.Child.init(argv.items, allocator);
    if (dir) |d| if (d.len != 0) {
        child.cwd = d;
    };
    child.stdin_behavior = if (stdin_text != null) .Pipe else .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    if (stdin_text) |s| {
        if (child.stdin) |stdin| {
            stdin.writeAll(s) catch {};
            stdin.close();
            child.stdin = null;
        }
    }

    // Drain stdout/stderr concurrently via the harness in std.process.Child.
    var stdout_buf = std.ArrayList(u8).init(allocator);
    errdefer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(allocator);
    errdefer stderr_buf.deinit();

    try child.collectOutput(&stdout_buf, &stderr_buf, 4 * 1024 * 1024);

    const term = try child.wait();
    const code: u8 = switch (term) {
        .Exited => |c| @intCast(c),
        else => return error.UnexpectedTermination,
    };

    return RunOut{
        .stdout = try stdout_buf.toOwnedSlice(),
        .stderr = try stderr_buf.toOwnedSlice(),
        .code = code,
    };
}

/// Run envless and fail the test if exit != 0. Returns the captured output
/// so callers can still inspect stdout/stderr.
fn runEnvlessOk(
    allocator: std.mem.Allocator,
    bin: []const u8,
    dir: ?[]const u8,
    stdin_text: ?[]const u8,
    args: []const []const u8,
) !RunOut {
    var out = try runEnvless(allocator, bin, dir, stdin_text, args);
    if (out.code != 0) {
        std.debug.print(
            "envless {s} (cwd={s}) exit={d}\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n",
            .{ argsToStr(args), dir orelse "", out.code, out.stdout, out.stderr },
        );
        out.deinit(allocator);
        return error.EnvlessNonZeroExit;
    }
    return out;
}

fn argsToStr(args: []const []const u8) []const u8 {
    // Best-effort flat join for diagnostics; we don't allocate because
    // std.debug.print only needs a fmt string. Return the first arg as a
    // diagnostic anchor; the full args list is implicit in the caller's
    // test name. Kept simple to avoid allocator plumbing in a print path.
    if (args.len == 0) return "(none)";
    return args[0];
}

/// Make a temporary directory under the OS tmp dir, prefixed `envless-e2e-`,
/// and return its absolute path (owned).
fn makeTmpDir(allocator: std.mem.Allocator) ![]u8 {
    // Use std.testing.tmpDir for cleanup but then realpath it to absolute,
    // because envless's child process spawn needs an absolute cwd.
    const tmp_root = std.posix.getenv("TMPDIR") orelse "/tmp";
    // Append a random suffix for uniqueness.
    var seed: u64 = @intCast(std.time.nanoTimestamp() & 0x7fff_ffff_ffff_ffff);
    seed +%= @intFromPtr(&seed);
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random().int(u64);
    const dir = try std.fmt.allocPrint(allocator, "{s}/envless-e2e-{x}", .{ tmp_root, rnd });
    try std.fs.makeDirAbsolute(dir);
    return dir;
}

fn rmTreeAbs(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

// ---------------------------------------------------------------------------
// Tests — one per Go TestE2E_* in e2e/e2e_test.go.
// ---------------------------------------------------------------------------

test "TestE2E_VersionFlag" {
    const a = testing.allocator;
    const bin = try resolveBin(a);
    defer a.free(bin);

    var out = try runEnvless(a, bin, null, null, &.{"--version"});
    defer out.deinit(a);

    try testing.expectEqual(@as(u8, 0), out.code);
    if (trim(out.stdout).len == 0) {
        std.debug.print("expected non-empty version output, got empty\n", .{});
        return error.TestUnexpectedEmpty;
    }
}

test "TestE2E_InitSetExecRoundtrip" {
    try skipIfMissing(&.{ "age-keygen", "sops", "sh" });
    const a = testing.allocator;
    const bin = try resolveBin(a);
    defer a.free(bin);

    const dir = try makeTmpDir(a);
    defer a.free(dir);
    defer rmTreeAbs(dir);

    // 1. init
    {
        var out = try runEnvlessOk(a, bin, dir, null, &.{"init"});
        defer out.deinit(a);
    }
    {
        const id = try std.fs.path.join(a, &.{ dir, ".envless", "identity.key" });
        defer a.free(id);
        std.fs.accessAbsolute(id, .{}) catch |err| {
            std.debug.print("identity not created: {s}\n", .{@errorName(err)});
            return error.TestUnexpectedIdentityMissing;
        };
    }

    // 2. set via stdin
    {
        var out = try runEnvlessOk(a, bin, dir, "sk-test-xyz", &.{ "set", "OPENAI_API_KEY" });
        defer out.deinit(a);
    }

    // 3. exec — child sees the secret in its env
    {
        var out = try runEnvlessOk(a, bin, dir, null, &.{
            "exec", "--", "/bin/sh", "-c", "echo $OPENAI_API_KEY",
        });
        defer out.deinit(a);
        try testing.expectEqualStrings("sk-test-xyz", trim(out.stdout));
    }
}

test "TestE2E_MultiEnvIsolation" {
    try skipIfMissing(&.{ "age-keygen", "sops", "sh" });
    const a = testing.allocator;
    const bin = try resolveBin(a);
    defer a.free(bin);

    const dir = try makeTmpDir(a);
    defer a.free(dir);
    defer rmTreeAbs(dir);

    {
        var out = try runEnvlessOk(a, bin, dir, null, &.{"init"});
        defer out.deinit(a);
    }
    {
        var out = try runEnvlessOk(a, bin, dir, "dev-val", &.{ "set", "TOKEN" });
        defer out.deinit(a);
    }
    {
        var out = try runEnvlessOk(a, bin, dir, "prod-val", &.{ "set", "TOKEN", "--env=prod" });
        defer out.deinit(a);
    }

    {
        var out = try runEnvless(a, bin, dir, null, &.{ "exec", "--", "/bin/sh", "-c", "echo $TOKEN" });
        defer out.deinit(a);
        try testing.expectEqualStrings("dev-val", trim(out.stdout));
    }
    {
        var out = try runEnvless(a, bin, dir, null, &.{ "exec", "--env=prod", "--", "/bin/sh", "-c", "echo $TOKEN" });
        defer out.deinit(a);
        try testing.expectEqualStrings("prod-val", trim(out.stdout));
    }
}

test "TestE2E_List" {
    try skipIfMissing(&.{ "age-keygen", "sops" });
    const a = testing.allocator;
    const bin = try resolveBin(a);
    defer a.free(bin);

    const dir = try makeTmpDir(a);
    defer a.free(dir);
    defer rmTreeAbs(dir);

    {
        var out = try runEnvlessOk(a, bin, dir, null, &.{"init"});
        defer out.deinit(a);
    }
    {
        var out = try runEnvlessOk(a, bin, dir, "v1", &.{ "set", "A" });
        defer out.deinit(a);
    }
    {
        var out = try runEnvlessOk(a, bin, dir, "v2", &.{ "set", "B" });
        defer out.deinit(a);
    }

    var out = try runEnvless(a, bin, dir, null, &.{"list"});
    defer out.deinit(a);
    try testing.expectEqual(@as(u8, 0), out.code);

    if (std.mem.indexOf(u8, out.stdout, "A") == null or std.mem.indexOf(u8, out.stdout, "B") == null) {
        std.debug.print("want A and B in list output:\n{s}\n", .{out.stdout});
        return error.TestMissingKeys;
    }
    if (std.mem.indexOf(u8, out.stdout, "v1") != null or std.mem.indexOf(u8, out.stdout, "v2") != null) {
        std.debug.print("list must not print values:\n{s}\n", .{out.stdout});
        return error.TestUnexpectedValues;
    }
}

test "TestE2E_GetRequiresConfirm" {
    try skipIfMissing(&.{ "age-keygen", "sops" });
    const a = testing.allocator;
    const bin = try resolveBin(a);
    defer a.free(bin);

    const dir = try makeTmpDir(a);
    defer a.free(dir);
    defer rmTreeAbs(dir);

    {
        var out = try runEnvlessOk(a, bin, dir, null, &.{"init"});
        defer out.deinit(a);
    }
    {
        var out = try runEnvlessOk(a, bin, dir, "secret-val", &.{ "set", "TOKEN" });
        defer out.deinit(a);
    }

    // Without --confirm: should refuse.
    {
        var out = try runEnvless(a, bin, dir, null, &.{ "get", "TOKEN" });
        defer out.deinit(a);
        if (out.code == 0) {
            std.debug.print("get without --confirm should fail (stdout={s}, stderr={s})\n", .{ out.stdout, out.stderr });
            return error.TestExpectedFailure;
        }
        if (std.mem.indexOf(u8, out.stderr, "confirm") == null) {
            std.debug.print("want stderr mentioning confirm, got: {s}\n", .{out.stderr});
            return error.TestMissingConfirmMention;
        }
    }

    // With --confirm: should print.
    {
        var out = try runEnvless(a, bin, dir, null, &.{ "get", "TOKEN", "--confirm" });
        defer out.deinit(a);
        try testing.expectEqual(@as(u8, 0), out.code);
        try testing.expectEqualStrings("secret-val", trim(out.stdout));
    }
}

test "TestE2E_Migrate" {
    try skipIfMissing(&.{ "age-keygen", "sops" });
    const a = testing.allocator;
    const bin = try resolveBin(a);
    defer a.free(bin);

    const dir = try makeTmpDir(a);
    defer a.free(dir);
    defer rmTreeAbs(dir);

    {
        var out = try runEnvlessOk(a, bin, dir, null, &.{"init"});
        defer out.deinit(a);
    }

    // Seed a .env file at <dir>/.env
    {
        const dotenv = try std.fs.path.join(a, &.{ dir, ".env" });
        defer a.free(dotenv);
        const f = try std.fs.createFileAbsolute(dotenv, .{});
        defer f.close();
        try f.writeAll("A=1\nB=2\nURL=https://x.com?a=b\n");
    }

    {
        var out = try runEnvlessOk(a, bin, dir, null, &.{ "migrate", ".env" });
        defer out.deinit(a);
    }

    // .env keys should now be retrievable through the store.
    {
        var out = try runEnvless(a, bin, dir, null, &.{"list"});
        defer out.deinit(a);
        try testing.expectEqual(@as(u8, 0), out.code);
        inline for ([_][]const u8{ "A", "B", "URL" }) |k| {
            if (std.mem.indexOf(u8, out.stdout, k) == null) {
                std.debug.print("want {s} in list, got:\n{s}\n", .{ k, out.stdout });
                return error.TestMissingMigratedKey;
            }
        }
    }

    // .env should be in .gitignore.
    {
        const gi_path = try std.fs.path.join(a, &.{ dir, ".gitignore" });
        defer a.free(gi_path);
        const data = try std.fs.cwd().readFileAlloc(a, gi_path, 64 * 1024);
        defer a.free(data);
        if (std.mem.indexOf(u8, data, ".env") == null) {
            std.debug.print(".env not in .gitignore:\n{s}\n", .{data});
            return error.TestMissingGitignoreEntry;
        }
    }
}

// ---------------------------------------------------------------------------
// Help output (no external toolchain needed — runs in every environment).
// ---------------------------------------------------------------------------

test "help: top-level contains Examples section" {
    const a = testing.allocator;
    const bin = try resolveBin(a);
    defer a.free(bin);

    var out = try runEnvless(a, bin, null, null, &.{"-h"});
    defer out.deinit(a);
    try testing.expectEqual(@as(u8, 0), out.code);
    if (std.mem.indexOf(u8, out.stdout, "Examples:") == null) {
        std.debug.print("missing Examples section:\n{s}\n", .{out.stdout});
        return error.TestMissingExamples;
    }
    if (std.mem.indexOf(u8, out.stdout, "envless init") == null) {
        std.debug.print("missing 'envless init' in examples:\n{s}\n", .{out.stdout});
        return error.TestMissingInitExample;
    }
}

test "help: per-command help is shown" {
    const a = testing.allocator;
    const bin = try resolveBin(a);
    defer a.free(bin);

    var out = try runEnvless(a, bin, null, null, &.{ "exec", "-h" });
    defer out.deinit(a);
    try testing.expectEqual(@as(u8, 0), out.code);
    inline for ([_][]const u8{ "Usage:", "envless exec", "Exit codes:" }) |needle| {
        if (std.mem.indexOf(u8, out.stdout, needle) == null) {
            std.debug.print("missing {s} in exec -h:\n{s}\n", .{ needle, out.stdout });
            return error.TestMissingHelpSection;
        }
    }
}

test "help: -h goes to stdout exit 0" {
    const a = testing.allocator;
    const bin = try resolveBin(a);
    defer a.free(bin);

    var out = try runEnvless(a, bin, null, null, &.{"-h"});
    defer out.deinit(a);
    try testing.expectEqual(@as(u8, 0), out.code);
    if (trim(out.stdout).len == 0) {
        std.debug.print("expected non-empty stdout for -h\n", .{});
        return error.TestUnexpectedEmpty;
    }
}

test "help: unknown command exits 2" {
    const a = testing.allocator;
    const bin = try resolveBin(a);
    defer a.free(bin);

    var out = try runEnvless(a, bin, null, null, &.{"nonexistent-cmd"});
    defer out.deinit(a);
    if (out.code != 2) {
        std.debug.print("want exit 2 for unknown cmd, got {d} stderr={s}\n", .{ out.code, out.stderr });
        return error.TestUnexpectedExitCode;
    }
    if (std.mem.indexOf(u8, out.stderr, "unknown command") == null) {
        std.debug.print("expected 'unknown command' in stderr:\n{s}\n", .{out.stderr});
        return error.TestMissingUnknownCmdMsg;
    }
}

// ---------------------------------------------------------------------------
// MCP server E2E — drive `envless mcp` as a child, send NDJSON, parse replies.
// ---------------------------------------------------------------------------

/// runMcpScript: spawn `envless mcp`, write `script` to stdin, close, capture
/// stdout/stderr until EOF.
fn runMcpScript(
    allocator: std.mem.Allocator,
    bin: []const u8,
    dir: ?[]const u8,
    script: []const u8,
) !RunOut {
    var child = std.process.Child.init(&.{ bin, "mcp" }, allocator);
    if (dir) |d| if (d.len != 0) {
        child.cwd = d;
    };
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    if (child.stdin) |stdin| {
        try stdin.writeAll(script);
        stdin.close();
        child.stdin = null;
    }

    var stdout_buf = std.ArrayList(u8).init(allocator);
    errdefer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(allocator);
    errdefer stderr_buf.deinit();
    try child.collectOutput(&stdout_buf, &stderr_buf, 4 * 1024 * 1024);

    const term = try child.wait();
    const code: u8 = switch (term) {
        .Exited => |c| @intCast(c),
        else => return error.UnexpectedTermination,
    };
    return RunOut{
        .stdout = try stdout_buf.toOwnedSlice(),
        .stderr = try stderr_buf.toOwnedSlice(),
        .code = code,
    };
}

test "TestE2E_McpInitializeAndToolsList" {
    const a = testing.allocator;
    const bin = try resolveBin(a);
    defer a.free(bin);

    const script =
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1\"}}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\",\"params\":{}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"envs\",\"arguments\":{}}}\n";

    const dir = try makeTmpDir(a);
    defer a.free(dir);
    defer rmTreeAbs(dir);

    var out = try runMcpScript(a, bin, dir, script);
    defer out.deinit(a);
    try testing.expectEqual(@as(u8, 0), out.code);

    // Three responses on stdout (one per id-bearing request). The
    // notification produces no output.
    var lines = std.mem.tokenizeScalar(u8, out.stdout, '\n');
    var count: usize = 0;
    var saw_initialize = false;
    var saw_tools_list = false;
    var saw_envs_call = false;
    while (lines.next()) |line| {
        count += 1;
        // Sanity: each line is JSON with jsonrpc=2.0.
        if (std.mem.indexOf(u8, line, "\"jsonrpc\":\"2.0\"") == null) {
            std.debug.print("non-jsonrpc line: {s}\n", .{line});
            return error.TestNonJsonRpc;
        }
        if (std.mem.indexOf(u8, line, "\"protocolVersion\":\"2024-11-05\"") != null) saw_initialize = true;
        if (std.mem.indexOf(u8, line, "\"tools\":[") != null) saw_tools_list = true;
        // envs in an empty dir returns an empty envs array.
        if (std.mem.indexOf(u8, line, "\\\"envs\\\":[]") != null) saw_envs_call = true;
    }
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expect(saw_initialize);
    try testing.expect(saw_tools_list);
    try testing.expect(saw_envs_call);
}

test "TestE2E_McpWhoamiAfterInit" {
    try skipIfMissing(&.{ "age-keygen", "sops" });
    const a = testing.allocator;
    const bin = try resolveBin(a);
    defer a.free(bin);

    const dir = try makeTmpDir(a);
    defer a.free(dir);
    defer rmTreeAbs(dir);

    // Bootstrap an envless repo.
    {
        var out = try runEnvlessOk(a, bin, dir, null, &.{"init"});
        defer out.deinit(a);
    }

    // whoami via MCP should report a pubkey + recipients=1.
    const script =
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1\"}}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"whoami\",\"arguments\":{}}}\n";
    var out = try runMcpScript(a, bin, dir, script);
    defer out.deinit(a);
    try testing.expectEqual(@as(u8, 0), out.code);
    if (std.mem.indexOf(u8, out.stdout, "age1") == null) {
        std.debug.print("expected age1 pubkey in whoami output:\n{s}\n", .{out.stdout});
        return error.TestMissingPubkey;
    }
    if (std.mem.indexOf(u8, out.stdout, "\\\"recipients\\\":1") == null) {
        std.debug.print("expected recipients:1 in whoami output:\n{s}\n", .{out.stdout});
        return error.TestMissingRecipients;
    }
}

test "TestE2E_McpSetGetListRoundtrip" {
    try skipIfMissing(&.{ "age-keygen", "sops" });
    const a = testing.allocator;
    const bin = try resolveBin(a);
    defer a.free(bin);

    const dir = try makeTmpDir(a);
    defer a.free(dir);
    defer rmTreeAbs(dir);

    {
        var out = try runEnvlessOk(a, bin, dir, null, &.{"init"});
        defer out.deinit(a);
    }

    // set TOKEN=hello via MCP, then list, then get with confirm=true.
    const script =
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1\"}}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"set\",\"arguments\":{\"env\":\"dev\",\"key\":\"TOKEN\",\"value\":\"hello\"}}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"list\",\"arguments\":{\"env\":\"dev\"}}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"get\",\"arguments\":{\"env\":\"dev\",\"key\":\"TOKEN\",\"confirm\":true}}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"get\",\"arguments\":{\"env\":\"dev\",\"key\":\"TOKEN\"}}}\n";
    var out = try runMcpScript(a, bin, dir, script);
    defer out.deinit(a);
    try testing.expectEqual(@as(u8, 0), out.code);

    if (std.mem.indexOf(u8, out.stdout, "\\\"ok\\\":true") == null) {
        std.debug.print("expected set ok=true:\n{s}\n", .{out.stdout});
        return error.TestSetFailed;
    }
    if (std.mem.indexOf(u8, out.stdout, "\\\"keys\\\":[\\\"TOKEN\\\"]") == null) {
        std.debug.print("expected keys=[TOKEN]:\n{s}\n", .{out.stdout});
        return error.TestListFailed;
    }
    if (std.mem.indexOf(u8, out.stdout, "\\\"value\\\":\\\"hello\\\"") == null) {
        std.debug.print("expected value=hello on get:\n{s}\n", .{out.stdout});
        return error.TestGetFailed;
    }
    // get without confirm must error (isError=true).
    if (std.mem.indexOf(u8, out.stdout, "\"isError\":true") == null) {
        std.debug.print("expected isError=true for confirmless get:\n{s}\n", .{out.stdout});
        return error.TestGetWithoutConfirm;
    }
}

// ---------------------------------------------------------------------------
// Daemon E2E (Linux-only by default — macOS Tahoe blocks Zig 0.13 locally).
// ---------------------------------------------------------------------------

test "TestE2E_DaemonPingAndList" {
    // Daemon e2e shells out to age-keygen+sops via the cached decrypt path.
    try skipIfMissing(&.{ "age-keygen", "sops" });
    const a = testing.allocator;
    const bin = try resolveBin(a);
    defer a.free(bin);

    const dir = try makeTmpDir(a);
    defer a.free(dir);
    defer rmTreeAbs(dir);

    // Bootstrap a real envless repo so the daemon has something to decrypt.
    {
        var out = try runEnvlessOk(a, bin, dir, null, &.{"init"});
        defer out.deinit(a);
    }
    {
        var out = try runEnvlessOk(a, bin, dir, "hello", &.{ "set", "TOKEN" });
        defer out.deinit(a);
    }

    // Pick a unique XDG_RUNTIME_DIR for this test so we never clash with
    // a developer's daemon. Note: the spawned daemon inherits this.
    const xdg = try std.fs.path.join(a, &.{ dir, ".xdg-rt" });
    defer a.free(xdg);
    try std.fs.makeDirAbsolute(xdg);

    // Spawn the daemon in the background with HOME=dir, XDG_RUNTIME_DIR=xdg.
    var child = std.process.Child.init(&.{ bin, "daemon" }, a);
    child.cwd = dir;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    var env_map = try std.process.getEnvMap(a);
    defer env_map.deinit();
    try env_map.put("HOME", dir);
    try env_map.put("XDG_RUNTIME_DIR", xdg);
    child.env_map = &env_map;
    try child.spawn();
    defer {
        // Best-effort teardown.
        _ = std.posix.kill(child.id, std.posix.SIG.TERM) catch {};
        _ = child.wait() catch {};
    }

    // Wait up to 2s for the socket to appear, then probe it with PING.
    const sock_path = try std.fs.path.join(a, &.{ xdg, "envless", "sock" });
    defer a.free(sock_path);

    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        std.fs.accessAbsolute(sock_path, .{}) catch {
            std.time.sleep(10 * std.time.ns_per_ms);
            continue;
        };
        break;
    }
    if (attempts == 200) {
        return error.SocketNeverAppeared;
    }

    // PING
    {
        var stream = try std.net.connectUnixSocket(sock_path);
        defer stream.close();
        try stream.writer().writeAll("PING\n");
        var buf: [128]u8 = undefined;
        const n = try stream.reader().read(&buf);
        if (!std.mem.startsWith(u8, buf[0..n], "OK\t")) {
            std.debug.print("ping reply unexpected: {s}\n", .{buf[0..n]});
            return error.PingFailed;
        }
    }
    // LIST dev
    {
        var stream = try std.net.connectUnixSocket(sock_path);
        defer stream.close();
        try stream.writer().writeAll("LIST\tdev\n");
        var buf: [4096]u8 = undefined;
        const n = try stream.reader().read(&buf);
        const line = buf[0..n];
        if (std.mem.indexOf(u8, line, "\"keys\":[\"TOKEN\"]") == null) {
            std.debug.print("LIST reply unexpected: {s}\n", .{line});
            return error.ListFailed;
        }
    }
}
