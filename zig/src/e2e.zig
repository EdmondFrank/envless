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
    if (std.c.getenv("BIN")) |bin_ptr| {
        return try allocator.dupe(u8, std.mem.span(bin_ptr));
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
    const path_ptr = std.c.getenv("PATH") orelse return false;
    const path_env = std.mem.span(path_ptr);
    _ = allocator;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = try std.fs.path.join(std.testing.allocator, &.{ dir, bin });
        defer std.testing.allocator.free(full);
        std.Io.Dir.cwd().access(std.testing.io, full, .{}) catch continue;
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
    const io = std.testing.io;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, bin);
    try argv.appendSlice(allocator, args);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = if (dir) |d| if (d.len != 0) .{ .path = d } else .inherit else .inherit,
        .stdin = if (stdin_text != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    if (stdin_text) |s| {
        if (child.stdin) |stdin_file| {
            var w_buf: [4096]u8 = undefined;
            var sw = stdin_file.writer(io, &w_buf);
            sw.interface.writeAll(s) catch {};
            sw.flush() catch {};
            stdin_file.close(io);
            child.stdin = null;
        }
    }

    // Drain stdout and stderr concurrently to avoid deadlock when the child
    // writes more than the pipe buffer size to one stream before the other.
    const stdout_file = child.stdout orelse return error.NoStdout;
    const stderr_file = child.stderr orelse return error.NoStderr;

    var mr_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var mr: std.Io.File.MultiReader = undefined;
    mr.init(allocator, io, mr_buffer.toStreams(), &.{ stdout_file, stderr_file });
    defer mr.deinit();

    while (mr.fill(64, .none)) |_| {
        if (mr.reader(0).buffered().len > 4 * 1024 * 1024) return error.StdoutTooLarge;
        if (mr.reader(1).buffered().len > 4 * 1024 * 1024) return error.StderrTooLarge;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try mr.checkAnyError();

    const term = try child.wait(io);
    const code: u8 = switch (term) {
        .exited => |c| @intCast(c),
        else => return error.UnexpectedTermination,
    };

    return RunOut{
        .stdout = try mr.toOwnedSlice(0),
        .stderr = try mr.toOwnedSlice(1),
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
    const io = std.testing.io;
    const tmp_root = if (std.c.getenv("TMPDIR")) |p| std.mem.span(p) else "/tmp";
    // Append a random suffix for uniqueness.
    var seed_buf: [8]u8 = undefined;
    std.Io.randomSecure(io, &seed_buf) catch {};
    const rnd = std.mem.readInt(u64, &seed_buf, .little);
    const dir = try std.fmt.allocPrint(allocator, "{s}/envless-e2e-{x}", .{ tmp_root, rnd });
    try std.Io.Dir.createDirAbsolute(io, dir, .default_dir);
    return dir;
}

fn rmTreeAbs(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(std.testing.io, path) catch {};
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
        std.Io.Dir.cwd().access(std.testing.io, id, .{}) catch |err| {
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

test "TestE2E_GetWithPassToken" {
    try skipIfMissing(&.{ "age-keygen", "sops" });
    const a = testing.allocator;
    const bin = try resolveBin(a);
    defer a.free(bin);

    const dir = try makeTmpDir(a);
    defer a.free(dir);
    defer rmTreeAbs(dir);

    // Bootstrap: init + set a secret + set ENVLESS_PASS_TOKEN.
    {
        var out = try runEnvlessOk(a, bin, dir, null, &.{"init"});
        defer out.deinit(a);
    }
    {
        var out = try runEnvlessOk(a, bin, dir, "secret-val", &.{ "set", "API_KEY" });
        defer out.deinit(a);
    }
    {
        var out = try runEnvlessOk(a, bin, dir, "my-pass-token", &.{ "set", "ENVLESS_PASS_TOKEN" });
        defer out.deinit(a);
    }

    // Get without --pass when ENVLESS_PASS_TOKEN is set: should fail.
    {
        var out = try runEnvless(a, bin, dir, null, &.{ "get", "API_KEY", "--confirm" });
        defer out.deinit(a);
        if (out.code == 0) {
            std.debug.print("get without --pass should fail when ENVLESS_PASS_TOKEN is set:\n{s}\n", .{out.stdout});
            return error.TestExpectedFailure;
        }
        if (std.mem.indexOf(u8, out.stderr, "pass token") == null) {
            std.debug.print("want stderr mentioning pass token, got: {s}\n", .{out.stderr});
            return error.TestMissingPassTokenMention;
        }
    }

    // Get with wrong --pass: should fail.
    {
        var out = try runEnvless(a, bin, dir, null, &.{ "get", "API_KEY", "--confirm", "--pass=wrong-token" });
        defer out.deinit(a);
        if (out.code == 0) {
            std.debug.print("get with wrong --pass should fail:\n{s}\n", .{out.stdout});
            return error.TestExpectedFailure;
        }
        if (std.mem.indexOf(u8, out.stderr, "mismatch") == null) {
            std.debug.print("want stderr mentioning mismatch, got: {s}\n", .{out.stderr});
            return error.TestMissingMismatchMention;
        }
    }

    // Get with correct --pass: should print.
    {
        var out = try runEnvless(a, bin, dir, null, &.{ "get", "API_KEY", "--confirm", "--pass=my-pass-token" });
        defer out.deinit(a);
        try testing.expectEqual(@as(u8, 0), out.code);
        try testing.expectEqualStrings("secret-val", trim(out.stdout));
    }
}

test "TestE2E_GetWithoutPassTokenBackwardCompat" {
    try skipIfMissing(&.{ "age-keygen", "sops" });
    const a = testing.allocator;
    const bin = try resolveBin(a);
    defer a.free(bin);

    const dir = try makeTmpDir(a);
    defer a.free(dir);
    defer rmTreeAbs(dir);

    // Bootstrap: init + set a secret (no ENVLESS_PASS_TOKEN).
    {
        var out = try runEnvlessOk(a, bin, dir, null, &.{"init"});
        defer out.deinit(a);
    }
    {
        var out = try runEnvlessOk(a, bin, dir, "secret-val", &.{ "set", "API_KEY" });
        defer out.deinit(a);
    }

    // Get with --confirm but no --pass: should succeed (no ENVLESS_PASS_TOKEN set).
    {
        var out = try runEnvless(a, bin, dir, null, &.{ "get", "API_KEY", "--confirm" });
        defer out.deinit(a);
        try testing.expectEqual(@as(u8, 0), out.code);
        try testing.expectEqualStrings("secret-val", trim(out.stdout));
    }

    // Get with --confirm and --pass (ignored when no ENVLESS_PASS_TOKEN): should succeed.
    {
        var out = try runEnvless(a, bin, dir, null, &.{ "get", "API_KEY", "--confirm", "--pass=anything" });
        defer out.deinit(a);
        try testing.expectEqual(@as(u8, 0), out.code);
        try testing.expectEqualStrings("secret-val", trim(out.stdout));
    }
}

test "TestE2E_McpGetWithPassToken" {
    try skipIfMissing(&.{ "age-keygen", "sops" });
    const a = testing.allocator;
    const bin = try resolveBin(a);
    defer a.free(bin);

    const dir = try makeTmpDir(a);
    defer a.free(dir);
    defer rmTreeAbs(dir);

    // Bootstrap a real envless repo.
    {
        var out = try runEnvlessOk(a, bin, dir, null, &.{"init"});
        defer out.deinit(a);
    }

    // Set a secret + ENVLESS_PASS_TOKEN via MCP, then get with and without pass.
    const script =
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1\"}}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"set\",\"arguments\":{\"env\":\"dev\",\"key\":\"API_KEY\",\"value\":\"secret-val\"}}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"set\",\"arguments\":{\"env\":\"dev\",\"key\":\"ENVLESS_PASS_TOKEN\",\"value\":\"my-pass-token\"}}}\n" ++
        // get without pass → should error (isError=true)
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"get\",\"arguments\":{\"env\":\"dev\",\"key\":\"API_KEY\",\"confirm\":true}}}\n" ++
        // get with wrong pass → should error (isError=true)
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"get\",\"arguments\":{\"env\":\"dev\",\"key\":\"API_KEY\",\"confirm\":true,\"pass\":\"wrong\"}}}\n" ++
        // get with correct pass → should succeed
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"get\",\"arguments\":{\"env\":\"dev\",\"key\":\"API_KEY\",\"confirm\":true,\"pass\":\"my-pass-token\"}}}\n";
    var out = try runMcpScript(a, bin, dir, script);
    defer out.deinit(a);
    try testing.expectEqual(@as(u8, 0), out.code);

    // id=4: get without pass → isError=true
    if (std.mem.indexOf(u8, out.stdout, "\"id\":4") == null) {
        std.debug.print("missing id=4 response:\n{s}\n", .{out.stdout});
        return error.TestMissingResponse;
    }
    // The isError=true for id=4 should appear before id=5's response.
    // We check that the id=4 response contains isError:true.
    {
        const id4_idx = std.mem.indexOf(u8, out.stdout, "\"id\":4") orelse {
            std.debug.print("missing id=4:\n{s}\n", .{out.stdout});
            return error.TestMissingResponse;
        };
        const id5_idx = std.mem.indexOf(u8, out.stdout, "\"id\":5") orelse out.stdout.len;
        const id4_block = out.stdout[id4_idx..id5_idx];
        if (std.mem.indexOf(u8, id4_block, "\"isError\":true") == null) {
            std.debug.print("expected isError=true for get without pass (id=4):\n{s}\n", .{id4_block});
            return error.TestGetWithoutPassShouldFail;
        }
    }

    // id=5: get with wrong pass → isError=true
    {
        const id5_idx = std.mem.indexOf(u8, out.stdout, "\"id\":5") orelse {
            std.debug.print("missing id=5:\n{s}\n", .{out.stdout});
            return error.TestMissingResponse;
        };
        const id6_idx = std.mem.indexOf(u8, out.stdout, "\"id\":6") orelse out.stdout.len;
        const id5_block = out.stdout[id5_idx..id6_idx];
        if (std.mem.indexOf(u8, id5_block, "\"isError\":true") == null) {
            std.debug.print("expected isError=true for get with wrong pass (id=5):\n{s}\n", .{id5_block});
            return error.TestGetWrongPassShouldFail;
        }
    }

    // id=6: get with correct pass → value=secret-val
    {
        const id6_idx = std.mem.indexOf(u8, out.stdout, "\"id\":6") orelse {
            std.debug.print("missing id=6:\n{s}\n", .{out.stdout});
            return error.TestMissingResponse;
        };
        const id6_block = out.stdout[id6_idx..];
        // The value is JSON-escaped inside the text field, so we search for
        // the raw value rather than the quoted key-value pair.
        if (std.mem.indexOf(u8, id6_block, "secret-val") == null) {
            std.debug.print("expected value containing secret-val for get with correct pass (id=6):\n{s}\n", .{id6_block});
            return error.TestGetWithPassFailed;
        }
        // Verify it's not an error.
        if (std.mem.indexOf(u8, id6_block, "\"isError\":false") == null) {
            std.debug.print("expected isError=false for get with correct pass (id=6):\n{s}\n", .{id6_block});
            return error.TestGetWithPassFailed;
        }
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
        const f = try std.Io.Dir.createFileAbsolute(std.testing.io, dotenv, .{});
        defer f.close(std.testing.io);
        var w_buf: [4096]u8 = undefined;
        var fw = f.writer(std.testing.io, &w_buf);
        try fw.interface.writeAll("A=1\nB=2\nURL=https://x.com?a=b\n");
        try fw.flush();
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
        const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, gi_path, a, .limited(64 * 1024));
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
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{
        .argv = &.{ bin, "mcp" },
        .cwd = if (dir) |d| if (d.len != 0) .{ .path = d } else .inherit else .inherit,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    if (child.stdin) |stdin_file| {
        var w_buf: [4096]u8 = undefined;
        var sw = stdin_file.writer(io, &w_buf);
        sw.interface.writeAll(script) catch {};
        sw.flush() catch {};
        stdin_file.close(io);
        child.stdin = null;
    }

    var stdout_buf: std.ArrayList(u8) = .empty;
    errdefer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    errdefer stderr_buf.deinit(allocator);

    if (child.stdout) |so| {
        var r_buf: [4096]u8 = undefined;
        var sr = so.reader(io, &r_buf);
        var data_buf: [4096]u8 = undefined;
        while (true) {
            const n = sr.interface.readSliceShort(&data_buf) catch break;
            if (n == 0) break;
            try stdout_buf.appendSlice(allocator, data_buf[0..n]);
        }
    }
    if (child.stderr) |se| {
        var r_buf: [4096]u8 = undefined;
        var sr = se.reader(io, &r_buf);
        var data_buf: [4096]u8 = undefined;
        while (true) {
            const n = sr.interface.readSliceShort(&data_buf) catch break;
            if (n == 0) break;
            try stderr_buf.appendSlice(allocator, data_buf[0..n]);
        }
    }

    const term = try child.wait(io);
    const code: u8 = switch (term) {
        .exited => |c| @intCast(c),
        else => return error.UnexpectedTermination,
    };
    return RunOut{
        .stdout = try stdout_buf.toOwnedSlice(allocator),
        .stderr = try stderr_buf.toOwnedSlice(allocator),
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
    try std.Io.Dir.createDirAbsolute(std.testing.io, xdg, .default_dir);

    // Spawn the daemon in the background with HOME=dir, XDG_RUNTIME_DIR=xdg.
    const io = std.testing.io;
    var env_map = std.process.Environ.Map.init(a);
    defer env_map.deinit();
    // Copy parent env.
    {
        var i: usize = 0;
        while (std.c.environ[i]) |entry_ptr| : (i += 1) {
            const entry = std.mem.span(entry_ptr);
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
            try env_map.put(entry[0..eq], entry[eq + 1 ..]);
        }
    }
    try env_map.put("HOME", dir);
    try env_map.put("XDG_RUNTIME_DIR", xdg);
    var child = try std.process.spawn(io, .{
        .argv = &.{ bin, "daemon" },
        .cwd = .{ .path = dir },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .environ_map = &env_map,
    });
    defer {
        // Best-effort teardown.
        if (child.id) |pid| {
            _ = std.posix.kill(pid, std.posix.SIG.TERM) catch {};
        }
        _ = child.wait(io) catch {};
    }

    // Wait up to 2s for the socket to appear, then probe it with PING.
    const sock_path = try std.fs.path.join(a, &.{ xdg, "envless", "sock" });
    defer a.free(sock_path);

    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        std.Io.Dir.cwd().access(io, sock_path, .{}) catch {
            std.Io.sleep(io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch {};
            continue;
        };
        break;
    }
    if (attempts == 200) {
        return error.SocketNeverAppeared;
    }

    // PING
    {
        var addr = try std.Io.net.UnixAddress.init(sock_path);
        var stream = try addr.connect(io);
        defer stream.close(io);
        var w_buf: [64]u8 = undefined;
        var w = stream.writer(io, &w_buf);
        try w.interface.writeAll("PING\n");
        var r_buf: [128]u8 = undefined;
        var sr = stream.reader(io, &r_buf);
        const n = try sr.interface.readSliceShort(&r_buf);
        if (!std.mem.startsWith(u8, r_buf[0..n], "OK\t")) {
            std.debug.print("ping reply unexpected: {s}\n", .{r_buf[0..n]});
            return error.PingFailed;
        }
    }
    // LIST dev
    {
        var addr = try std.Io.net.UnixAddress.init(sock_path);
        var stream = try addr.connect(io);
        defer stream.close(io);
        var w_buf: [64]u8 = undefined;
        var w = stream.writer(io, &w_buf);
        try w.interface.writeAll("LIST\tdev\n");
        var r_buf: [4096]u8 = undefined;
        var sr = stream.reader(io, &r_buf);
        const n = try sr.interface.readSliceShort(&r_buf);
        const line = r_buf[0..n];
        if (std.mem.indexOf(u8, line, "\"keys\":[\"TOKEN\"]") == null) {
            std.debug.print("LIST reply unexpected: {s}\n", .{line});
            return error.ListFailed;
        }
    }
}

// ---------------------------------------------------------------------------
// Backup e2e tests
// ---------------------------------------------------------------------------

/// Capture `tar -tzf <path>` member list as one big string. Caller owns.
fn tarMembers(allocator: std.mem.Allocator, tar_path: []const u8) ![]u8 {
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{
        .argv = &.{ "tar", "-tzf", tar_path },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var out_buf: std.ArrayList(u8) = .empty;
    errdefer out_buf.deinit(allocator);
    if (child.stdout) |so| {
        var r_buf: [4096]u8 = undefined;
        var sr = so.reader(io, &r_buf);
        while (true) {
            const n = sr.interface.readSliceShort(&r_buf) catch break;
            if (n == 0) break;
            try out_buf.appendSlice(allocator, r_buf[0..n]);
        }
    }
    _ = try child.wait(io);
    return out_buf.toOwnedSlice(allocator);
}

/// Read a single member's contents from a tarball, into memory. Returns owned.
fn tarReadMember(allocator: std.mem.Allocator, tar_path: []const u8, member: []const u8) ![]u8 {
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{
        .argv = &.{ "tar", "-xzOf", tar_path, member },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var out_buf: std.ArrayList(u8) = .empty;
    errdefer out_buf.deinit(allocator);
    if (child.stdout) |so| {
        var r_buf: [4096]u8 = undefined;
        var sr = so.reader(io, &r_buf);
        while (true) {
            const n = sr.interface.readSliceShort(&r_buf) catch break;
            if (n == 0) break;
            try out_buf.appendSlice(allocator, r_buf[0..n]);
        }
    }
    _ = try child.wait(io);
    return out_buf.toOwnedSlice(allocator);
}

test "backup: default excludes identity.key" {
    try skipIfMissing(&.{ "age-keygen", "sops", "tar" });
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
        var out = try runEnvlessOk(a, bin, dir, "sk-test-xyz", &.{ "set", "OPENAI_API_KEY" });
        defer out.deinit(a);
    }

    const tar_path = try std.fs.path.join(a, &.{ dir, "out.tar.gz" });
    defer a.free(tar_path);

    {
        var out = try runEnvlessOk(a, bin, dir, null, &.{ "backup", "--output", tar_path });
        defer out.deinit(a);
    }

    const members = try tarMembers(a, tar_path);
    defer a.free(members);

    if (std.mem.indexOf(u8, members, ".envless/identity.key") != null) {
        std.debug.print("default backup MUST NOT contain identity.key, got:\n{s}\n", .{members});
        return error.TestUnexpectedIdentity;
    }
    if (std.mem.indexOf(u8, members, ".envless/recipients") == null) {
        std.debug.print("expected recipients in members, got:\n{s}\n", .{members});
        return error.TestMissingRecipients;
    }
    if (std.mem.indexOf(u8, members, "secrets/dev.env.enc") == null) {
        std.debug.print("expected secrets/dev.env.enc, got:\n{s}\n", .{members});
        return error.TestMissingSecrets;
    }
    if (std.mem.indexOf(u8, members, "MANIFEST.json") == null) {
        std.debug.print("expected MANIFEST.json, got:\n{s}\n", .{members});
        return error.TestMissingManifest;
    }
}

test "backup: --include-identity --yes includes identity.key" {
    try skipIfMissing(&.{ "age-keygen", "sops", "tar" });
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
        var out = try runEnvlessOk(a, bin, dir, "sk-test-xyz", &.{ "set", "OPENAI_API_KEY" });
        defer out.deinit(a);
    }

    const tar_path = try std.fs.path.join(a, &.{ dir, "out.tar.gz" });
    defer a.free(tar_path);

    {
        var out = try runEnvlessOk(a, bin, dir, null, &.{
            "backup", "--include-identity", "--yes", "--output", tar_path,
        });
        defer out.deinit(a);
    }

    const members = try tarMembers(a, tar_path);
    defer a.free(members);

    if (std.mem.indexOf(u8, members, ".envless/identity.key") == null) {
        std.debug.print("expected identity.key in members, got:\n{s}\n", .{members});
        return error.TestMissingIdentity;
    }
}

test "backup: --include-identity without --yes in non-tty exits 2" {
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

    const tar_path = try std.fs.path.join(a, &.{ dir, "out.tar.gz" });
    defer a.free(tar_path);

    // runEnvless wires stdin via .Ignore when stdin_text is null, which the
    // child sees as a non-TTY descriptor. That matches the script-context
    // branch in cli/backup.zig (no --yes => exit 2).
    var out = try runEnvless(a, bin, dir, null, &.{
        "backup", "--include-identity", "--output", tar_path,
    });
    defer out.deinit(a);

    if (out.code != 2) {
        std.debug.print(
            "expected exit 2 (usage), got {d}\nstdout={s}\nstderr={s}\n",
            .{ out.code, out.stdout, out.stderr },
        );
        return error.TestUnexpectedExitCode;
    }
    if (std.mem.indexOf(u8, out.stderr, "--yes") == null) {
        std.debug.print("expected stderr to mention --yes:\n{s}\n", .{out.stderr});
        return error.TestMissingYesMention;
    }
}

test "backup: manifest schema_version + pubkey present" {
    try skipIfMissing(&.{ "age-keygen", "sops", "tar" });
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
        var out = try runEnvlessOk(a, bin, dir, "sk-test-xyz", &.{ "set", "OPENAI_API_KEY" });
        defer out.deinit(a);
    }

    const tar_path = try std.fs.path.join(a, &.{ dir, "out.tar.gz" });
    defer a.free(tar_path);

    {
        var out = try runEnvlessOk(a, bin, dir, null, &.{ "backup", "--output", tar_path });
        defer out.deinit(a);
    }

    const manifest = try tarReadMember(a, tar_path, "MANIFEST.json");
    defer a.free(manifest);

    // Minimal shape assertions — we don't pull in a JSON parser for this; the
    // manifest is rendered by hand so substring matching is sufficient.
    inline for ([_][]const u8{
        "\"schema_version\": 1",
        "\"envless_version\":",
        "\"created_at\":",
        "\"pubkey\": \"age1",
        "\"includes_identity\": false",
        "\"envs\": [\"dev\"]",
        "\"file_count\":",
    }) |needle| {
        if (std.mem.indexOf(u8, manifest, needle) == null) {
            std.debug.print("manifest missing {s}\n--- manifest ---\n{s}\n", .{ needle, manifest });
            return error.TestManifestShape;
        }
    }
}
