//! launchd: macOS LaunchAgent install/uninstall/status for `envless daemon`.
//!
//! Plist path: `$HOME/Library/LaunchAgents/<label>.plist`
//! Default label: `io.github.biliboss.envless`
//!   (override via env `ENVLESS_LAUNCHD_LABEL` — used by tests so a CI
//!    bootstrap doesn't fight a developer's real install)
//!
//! Three subcommands wire in from `cli/daemon.zig`:
//!   envless daemon install    → write plist + launchctl bootstrap gui/<uid>
//!   envless daemon uninstall  → launchctl bootout + delete plist
//!   envless daemon status     → loaded? + path probe
//!
//! Constraints:
//!   - Plist write is atomic (renameFile).
//!   - install refuses if the plist already exists ("uninstall first").
//!   - uninstall refuses if the plist is not present.
//!   - getuid() via std.c for the gui/<uid> domain target.
//!   - Self-locate via `std.fs.selfExePath` (resolves _NSGetExecutablePath
//!     + realpath on macOS); never trust argv[0] because login shells may
//!     hand us a bare binary name.

const std = @import("std");

// Cross-target libc decl. `std.posix.getuid` is not exposed for the macOS
// cross-compile in Zig 0.13's stdlib slice, so we bind libc directly.
extern fn getuid() callconv(.c) std.posix.uid_t;

pub const DEFAULT_LABEL = "io.github.biliboss.envless";
pub const LABEL_ENV = "ENVLESS_LAUNCHD_LABEL";

const Paths = struct {
    label: []const u8,
    plist_dir: []const u8,
    plist_basename: []const u8,
    plist_abs: []const u8,
    cache_dir: []const u8,
    stdout_log: []const u8,
    stderr_log: []const u8,
    uid: u32,
};

fn pickLabel(env: ?[]const u8) []const u8 {
    if (env) |s| if (s.len > 0) return s;
    return DEFAULT_LABEL;
}

fn computePaths(a: std.mem.Allocator, home: []const u8, label: []const u8) !Paths {
    const plist_dir = try std.fmt.allocPrint(a, "{s}/Library/LaunchAgents", .{home});
    const plist_basename = try std.fmt.allocPrint(a, "{s}.plist", .{label});
    const plist_abs = try std.fmt.allocPrint(a, "{s}/{s}", .{ plist_dir, plist_basename });
    const cache_dir = try std.fmt.allocPrint(a, "{s}/.cache/envless", .{home});
    const stdout_log = try std.fmt.allocPrint(a, "{s}/daemon.out.log", .{cache_dir});
    const stderr_log = try std.fmt.allocPrint(a, "{s}/daemon.err.log", .{cache_dir});
    const uid = getuid();
    return .{
        .label = label,
        .plist_dir = plist_dir,
        .plist_basename = plist_basename,
        .plist_abs = plist_abs,
        .cache_dir = cache_dir,
        .stdout_log = stdout_log,
        .stderr_log = stderr_log,
        .uid = uid,
    };
}

fn resolveExePath(a: std.mem.Allocator, io: std.Io) ![]u8 {
    var buf: [4096]u8 = undefined;
    const len = try std.process.executablePath(io, &buf);
    return a.dupe(u8, buf[0..len]);
}

fn xmlEscape(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try out.ensureTotalCapacity(a, s.len);
    for (s) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        '"' => try out.appendSlice(a, "&quot;"),
        '\'' => try out.appendSlice(a, "&apos;"),
        else => try out.append(a, c),
    };
    return out.toOwnedSlice(a);
}

pub fn renderPlist(
    a: std.mem.Allocator,
    label: []const u8,
    exe_path: []const u8,
    home: []const u8,
    cache_dir: []const u8,
    stdout_log: []const u8,
    stderr_log: []const u8,
) ![]u8 {
    const label_e = try xmlEscape(a, label);
    defer a.free(label_e);
    const exe_e = try xmlEscape(a, exe_path);
    defer a.free(exe_e);
    const home_e = try xmlEscape(a, home);
    defer a.free(home_e);
    const cache_e = try xmlEscape(a, cache_dir);
    defer a.free(cache_e);
    const stdout_e = try xmlEscape(a, stdout_log);
    defer a.free(stdout_e);
    const stderr_e = try xmlEscape(a, stderr_log);
    defer a.free(stderr_e);

    return std.fmt.allocPrint(a,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>Label</key>
        \\    <string>{s}</string>
        \\    <key>ProgramArguments</key>
        \\    <array>
        \\        <string>{s}</string>
        \\        <string>daemon</string>
        \\    </array>
        \\    <key>RunAtLoad</key>
        \\    <true/>
        \\    <key>KeepAlive</key>
        \\    <dict>
        \\        <key>SuccessfulExit</key>
        \\        <false/>
        \\    </dict>
        \\    <key>StandardOutPath</key>
        \\    <string>{s}</string>
        \\    <key>StandardErrorPath</key>
        \\    <string>{s}</string>
        \\    <key>WorkingDirectory</key>
        \\    <string>{s}</string>
        \\    <key>EnvironmentVariables</key>
        \\    <dict>
        \\        <key>HOME</key>
        \\        <string>{s}</string>
        \\    </dict>
        \\    <key>ProcessType</key>
        \\    <string>Background</string>
        \\</dict>
        \\</plist>
        \\
    , .{ label_e, exe_e, stdout_e, stderr_e, cache_e, home_e });
}

fn writePlistAtomic(a: std.mem.Allocator, io: std.Io, paths: Paths, contents: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(io, paths.plist_dir) catch {};
    const tmp = try std.fmt.allocPrint(a, "{s}.tmp", .{paths.plist_abs});
    defer a.free(tmp);
    {
        var f = try std.Io.Dir.cwd().createFile(io, tmp, .{ .truncate = true });
        defer f.close(io);
        var write_buf: [4096]u8 = undefined;
        var fw = f.writer(io, &write_buf);
        try fw.interface.writeAll(contents);
        try fw.flush();
    }
    try std.Io.Dir.renameAbsolute(tmp, paths.plist_abs, io);
}

fn plistExists(io: std.Io, paths: Paths) bool {
    std.Io.Dir.cwd().access(io, paths.plist_abs, .{}) catch return false;
    return true;
}

fn runLaunchctl(a: std.mem.Allocator, io: std.Io, argv: []const []const u8) !std.process.RunResult {
    return std.process.run(a, io, .{ .argv = argv });
}

pub fn install(
    a: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.File.Writer,
    home: []const u8,
    label_override: ?[]const u8,
    exe_path_override: ?[]const u8,
) !void {
    const label = pickLabel(label_override);
    const paths = try computePaths(a, home, label);

    if (plistExists(io, paths)) {
        try writer.interface.print("[launchd] already installed at {s} — uninstall first\n", .{paths.plist_abs});
        return error.AlreadyInstalled;
    }

    const exe_path = exe_path_override orelse try resolveExePath(a, io);

    std.Io.Dir.cwd().createDirPath(io, paths.cache_dir) catch {};

    const xml = try renderPlist(a, label, exe_path, home, paths.cache_dir, paths.stdout_log, paths.stderr_log);
    defer a.free(xml);

    try writePlistAtomic(a, io, paths, xml);
    try writer.interface.print("[launchd] wrote {s} ({d} bytes)\n", .{ paths.plist_abs, xml.len });

    const domain = try std.fmt.allocPrint(a, "gui/{d}", .{paths.uid});
    defer a.free(domain);
    const argv = [_][]const u8{ "/bin/launchctl", "bootstrap", domain, paths.plist_abs };

    const r = runLaunchctl(a, io, &argv) catch |err| {
        try writer.interface.print("[launchd] launchctl spawn failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer a.free(r.stdout);
    defer a.free(r.stderr);
    switch (r.term) {
        .exited => |code| {
            if (code == 0) {
                try writer.interface.print("[launchd] bootstrap OK (domain={s} label={s})\n", .{ domain, label });
                return;
            }
            try writer.interface.print("[launchd] bootstrap exit={d}\nstdout: {s}\nstderr: {s}\n", .{ code, r.stdout, r.stderr });
            return error.BootstrapFailed;
        },
        else => {
            try writer.interface.print("[launchd] bootstrap abnormal term\n", .{});
            return error.BootstrapFailed;
        },
    }
}

pub fn uninstall(a: std.mem.Allocator, io: std.Io,
    writer: *std.Io.File.Writer, home: []const u8, label_override: ?[]const u8) !void {
    const label = pickLabel(label_override);
    const paths = try computePaths(a, home, label);
    if (!plistExists(io, paths)) {
        try writer.interface.print("[launchd] not installed (no plist at {s})\n", .{paths.plist_abs});
        return error.NotInstalled;
    }
    const domain = try std.fmt.allocPrint(a, "gui/{d}", .{paths.uid});
    defer a.free(domain);
    const argv = [_][]const u8{ "/bin/launchctl", "bootout", domain, paths.plist_abs };
    if (runLaunchctl(a, io, &argv)) |r| {
        defer a.free(r.stdout);
        defer a.free(r.stderr);
        switch (r.term) {
            .exited => |code| if (code != 0) {
                try writer.interface.print("[launchd] bootout warn code={d}\nstdout: {s}\nstderr: {s}\n", .{ code, r.stdout, r.stderr });
            } else {
                try writer.interface.print("[launchd] bootout OK\n", .{});
            },
            else => try writer.interface.print("[launchd] bootout abnormal\n", .{}),
        }
    } else |err| {
        try writer.interface.print("[launchd] bootout spawn failed: {s} (continuing)\n", .{@errorName(err)});
    }
    std.Io.Dir.cwd().deleteFile(io, paths.plist_abs) catch |err| {
        try writer.interface.print("[launchd] could not delete plist: {s}\n", .{@errorName(err)});
        return err;
    };
    try writer.interface.print("[launchd] removed {s}\n", .{paths.plist_abs});
}

pub fn status(a: std.mem.Allocator, io: std.Io,
    writer: *std.Io.File.Writer, home: []const u8, label_override: ?[]const u8) !void {
    const label = pickLabel(label_override);
    const paths = try computePaths(a, home, label);
    const present = plistExists(io, paths);
    try writer.interface.print("[launchd] plist: {s} ({s})\n", .{ paths.plist_abs, if (present) "present" else "missing" });
    try writer.interface.print("[launchd] label: {s}\n", .{label});
    try writer.interface.print("[launchd] uid:   {d}\n", .{paths.uid});

    const service_target = try std.fmt.allocPrint(a, "gui/{d}/{s}", .{ paths.uid, label });
    defer a.free(service_target);
    const argv = [_][]const u8{ "/bin/launchctl", "print", service_target };
    if (runLaunchctl(a, io, &argv)) |r| {
        defer a.free(r.stdout);
        defer a.free(r.stderr);
        switch (r.term) {
            .exited => |code| if (code == 0) {
                try writer.interface.print("[launchd] print OK\n--- begin ---\n{s}--- end ---\n", .{r.stdout});
            } else {
                try writer.interface.print("[launchd] print code={d} (not loaded?)\nstderr: {s}\n", .{ code, r.stderr });
            },
            else => try writer.interface.print("[launchd] print abnormal\n", .{}),
        }
    } else |err| {
        try writer.interface.print("[launchd] print spawn failed: {s}\n", .{@errorName(err)});
    }
}

/// stopRunning: send SIGTERM to any running daemon process by sniffing the
/// socket and connecting (the daemon doesn't expose a STOP op — the signal
/// handler is the supported shutdown path). We fall back to the supervisor's
/// stop path when available.
pub fn stopRunning(a: std.mem.Allocator, io: std.Io,
    writer: *std.Io.File.Writer, home: []const u8) !void {
    _ = a;
    _ = io;
    _ = writer;
    _ = home;
    // Best path on macOS: launchctl kill TERM gui/<uid>/<label>.
    // Implementation lives in cli/daemon.zig because the supervisor choice
    // (launchd vs systemd) depends on the platform — we keep that decision
    // out of this module.
}

// ----------------------------- tests -----------------------------------------

const testing = std.testing;

test "pickLabel falls back to default" {
    try testing.expectEqualStrings(DEFAULT_LABEL, pickLabel(null));
    try testing.expectEqualStrings(DEFAULT_LABEL, pickLabel(""));
    try testing.expectEqualStrings("foo.bar", pickLabel("foo.bar"));
}

test "xmlEscape covers the five entities" {
    const a = testing.allocator;
    const out = try xmlEscape(a, "a&b<c>d\"e'f");
    defer a.free(out);
    try testing.expectEqualStrings("a&amp;b&lt;c&gt;d&quot;e&apos;f", out);
}

test "renderPlist includes label, exe, daemon arg" {
    const a = testing.allocator;
    const xml = try renderPlist(
        a,
        "test.label",
        "/usr/local/bin/envless",
        "/Users/test",
        "/Users/test/.cache/envless",
        "/Users/test/.cache/envless/daemon.out.log",
        "/Users/test/.cache/envless/daemon.err.log",
    );
    defer a.free(xml);
    try testing.expect(std.mem.indexOf(u8, xml, "<string>test.label</string>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<string>/usr/local/bin/envless</string>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<string>daemon</string>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<key>KeepAlive</key>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<key>SuccessfulExit</key>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<key>WorkingDirectory</key>") != null);
}

test "renderPlist escapes ampersand in HOME" {
    const a = testing.allocator;
    const xml = try renderPlist(
        a,
        "envless.test",
        "/bin/envless",
        "/Users/test & co",
        "/Users/test & co/.cache/envless",
        "/Users/test & co/.cache/envless/daemon.out.log",
        "/Users/test & co/.cache/envless/daemon.err.log",
    );
    defer a.free(xml);
    try testing.expect(std.mem.indexOf(u8, xml, "Users/test &amp; co") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "test & co/.cache") == null);
}
