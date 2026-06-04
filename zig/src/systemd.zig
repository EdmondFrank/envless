//! systemd: Linux user-unit install/uninstall/status for `envless daemon`.
//!
//! Unit path: `$XDG_CONFIG_HOME/systemd/user/<unit>` (or
//! `$HOME/.config/systemd/user/` when XDG_CONFIG_HOME is unset).
//! Default unit: `envless.service` (override via `ENVLESS_SYSTEMD_UNIT`).
//!
//! Three subcommands wire in from `cli/daemon.zig`:
//!   envless daemon install    → write unit + systemctl --user enable --now
//!   envless daemon uninstall  → systemctl --user disable --now + delete unit
//!   envless daemon status     → systemctl --user status envless
//!
//! Constraints mirror launchd.zig:
//!   - Unit write is atomic (rename).
//!   - install refuses if the unit exists ("uninstall first").
//!   - uninstall refuses if the unit is missing.
//!
//! Self-locate via `std.fs.selfExePath` which resolves /proc/self/exe on
//! Linux. systemd requires absolute paths in ExecStart.

const std = @import("std");

pub const DEFAULT_UNIT = "envless.service";
pub const UNIT_ENV = "ENVLESS_SYSTEMD_UNIT";

const Paths = struct {
    unit: []const u8,
    unit_dir: []const u8,
    unit_abs: []const u8,
    cache_dir: []const u8,
};

fn pickUnit(env: ?[]const u8) []const u8 {
    if (env) |s| if (s.len > 0) return s;
    return DEFAULT_UNIT;
}

fn computePaths(a: std.mem.Allocator, home: []const u8, xdg_config: ?[]const u8, unit: []const u8) !Paths {
    const unit_dir = if (xdg_config) |x| blk: {
        if (x.len > 0) break :blk try std.fmt.allocPrint(a, "{s}/systemd/user", .{x});
        break :blk try std.fmt.allocPrint(a, "{s}/.config/systemd/user", .{home});
    } else try std.fmt.allocPrint(a, "{s}/.config/systemd/user", .{home});

    const unit_abs = try std.fmt.allocPrint(a, "{s}/{s}", .{ unit_dir, unit });
    const cache_dir = try std.fmt.allocPrint(a, "{s}/.cache/envless", .{home});
    return .{
        .unit = unit,
        .unit_dir = unit_dir,
        .unit_abs = unit_abs,
        .cache_dir = cache_dir,
    };
}

fn resolveExePath(a: std.mem.Allocator) ![]u8 {
    var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const slice = try std.fs.selfExePath(&buf);
    return a.dupe(u8, slice);
}

pub fn renderUnit(a: std.mem.Allocator, exe_path: []const u8, home: []const u8, cache_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(a,
        \\[Unit]
        \\Description=envless daemon (decrypt cache)
        \\Documentation=https://biliboss.github.io/envless/
        \\After=default.target
        \\
        \\[Service]
        \\Type=simple
        \\ExecStart={s} daemon
        \\WorkingDirectory={s}
        \\Environment=HOME={s}
        \\Restart=on-failure
        \\RestartSec=2
        \\StandardOutput=journal
        \\StandardError=journal
        \\
        \\[Install]
        \\WantedBy=default.target
        \\
    , .{ exe_path, cache_dir, home });
}

fn writeUnitAtomic(a: std.mem.Allocator, paths: Paths, contents: []const u8) !void {
    std.fs.cwd().makePath(paths.unit_dir) catch {};
    const tmp = try std.fmt.allocPrint(a, "{s}.tmp", .{paths.unit_abs});
    defer a.free(tmp);
    {
        var f = try std.fs.cwd().createFile(tmp, .{ .truncate = true, .mode = 0o644 });
        defer f.close();
        try f.writeAll(contents);
    }
    try std.fs.cwd().rename(tmp, paths.unit_abs);
}

fn unitExists(paths: Paths) bool {
    std.fs.cwd().access(paths.unit_abs, .{}) catch return false;
    return true;
}

fn runSystemctl(a: std.mem.Allocator, argv: []const []const u8) !std.process.Child.RunResult {
    return std.process.Child.run(.{ .allocator = a, .argv = argv });
}

pub fn install(
    a: std.mem.Allocator,
    writer: anytype,
    home: []const u8,
    xdg_config: ?[]const u8,
    unit_override: ?[]const u8,
    exe_path_override: ?[]const u8,
) !void {
    const unit = pickUnit(unit_override);
    const paths = try computePaths(a, home, xdg_config, unit);

    if (unitExists(paths)) {
        try writer.print("[systemd] already installed at {s} — uninstall first\n", .{paths.unit_abs});
        return error.AlreadyInstalled;
    }
    const exe_path = exe_path_override orelse try resolveExePath(a);
    std.fs.cwd().makePath(paths.cache_dir) catch {};

    const unit_text = try renderUnit(a, exe_path, home, paths.cache_dir);
    defer a.free(unit_text);
    try writeUnitAtomic(a, paths, unit_text);
    try writer.print("[systemd] wrote {s} ({d} bytes)\n", .{ paths.unit_abs, unit_text.len });

    {
        const argv = [_][]const u8{ "systemctl", "--user", "daemon-reload" };
        const r = runSystemctl(a, &argv) catch |err| {
            try writer.print("[systemd] daemon-reload spawn failed: {s}\n", .{@errorName(err)});
            return err;
        };
        defer a.free(r.stdout);
        defer a.free(r.stderr);
        switch (r.term) {
            .Exited => |c| if (c != 0) {
                try writer.print("[systemd] daemon-reload exit={d}\nstdout: {s}\nstderr: {s}\n", .{ c, r.stdout, r.stderr });
                return error.DaemonReloadFailed;
            },
            else => {
                try writer.print("[systemd] daemon-reload abnormal\n", .{});
                return error.DaemonReloadFailed;
            },
        }
    }

    const argv = [_][]const u8{ "systemctl", "--user", "enable", "--now", unit };
    const r = runSystemctl(a, &argv) catch |err| {
        try writer.print("[systemd] enable --now spawn failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer a.free(r.stdout);
    defer a.free(r.stderr);
    switch (r.term) {
        .Exited => |c| if (c == 0) {
            try writer.print("[systemd] enable --now OK (unit={s})\n", .{unit});
            return;
        } else {
            try writer.print("[systemd] enable --now exit={d}\nstdout: {s}\nstderr: {s}\n", .{ c, r.stdout, r.stderr });
            return error.EnableFailed;
        },
        else => {
            try writer.print("[systemd] enable --now abnormal\n", .{});
            return error.EnableFailed;
        },
    }
}

pub fn uninstall(
    a: std.mem.Allocator,
    writer: anytype,
    home: []const u8,
    xdg_config: ?[]const u8,
    unit_override: ?[]const u8,
) !void {
    const unit = pickUnit(unit_override);
    const paths = try computePaths(a, home, xdg_config, unit);
    if (!unitExists(paths)) {
        try writer.print("[systemd] not installed (no unit at {s})\n", .{paths.unit_abs});
        return error.NotInstalled;
    }
    {
        const argv = [_][]const u8{ "systemctl", "--user", "disable", "--now", unit };
        if (runSystemctl(a, &argv)) |r| {
            defer a.free(r.stdout);
            defer a.free(r.stderr);
            switch (r.term) {
                .Exited => |c| if (c != 0) {
                    try writer.print("[systemd] disable --now warn code={d} (continuing)\nstdout: {s}\nstderr: {s}\n", .{ c, r.stdout, r.stderr });
                } else {
                    try writer.print("[systemd] disable --now OK\n", .{});
                },
                else => try writer.print("[systemd] disable abnormal (continuing)\n", .{}),
            }
        } else |err| {
            try writer.print("[systemd] disable --now spawn failed: {s} (continuing)\n", .{@errorName(err)});
        }
    }
    std.fs.cwd().deleteFile(paths.unit_abs) catch |err| {
        try writer.print("[systemd] could not delete unit: {s}\n", .{@errorName(err)});
        return err;
    };
    try writer.print("[systemd] removed {s}\n", .{paths.unit_abs});

    const argv = [_][]const u8{ "systemctl", "--user", "daemon-reload" };
    if (runSystemctl(a, &argv)) |r| {
        defer a.free(r.stdout);
        defer a.free(r.stderr);
    } else |_| {}
}

pub fn status(
    a: std.mem.Allocator,
    writer: anytype,
    home: []const u8,
    xdg_config: ?[]const u8,
    unit_override: ?[]const u8,
) !void {
    const unit = pickUnit(unit_override);
    const paths = try computePaths(a, home, xdg_config, unit);
    const present = unitExists(paths);
    try writer.print("[systemd] unit: {s} ({s})\n", .{ paths.unit_abs, if (present) "present" else "missing" });
    try writer.print("[systemd] name: {s}\n", .{unit});

    const argv = [_][]const u8{ "systemctl", "--user", "status", unit };
    if (runSystemctl(a, &argv)) |r| {
        defer a.free(r.stdout);
        defer a.free(r.stderr);
        switch (r.term) {
            .Exited => |c| {
                try writer.print("[systemd] status code={d}\n--- begin ---\n{s}--- end ---\n", .{ c, r.stdout });
                if (r.stderr.len > 0) try writer.print("stderr: {s}\n", .{r.stderr});
            },
            else => try writer.print("[systemd] status abnormal\n", .{}),
        }
    } else |err| {
        try writer.print("[systemd] status spawn failed: {s}\n", .{@errorName(err)});
    }
}

// ----------------------------- tests -----------------------------------------

const testing = std.testing;

test "pickUnit falls back to default" {
    try testing.expectEqualStrings(DEFAULT_UNIT, pickUnit(null));
    try testing.expectEqualStrings(DEFAULT_UNIT, pickUnit(""));
    try testing.expectEqualStrings("custom.service", pickUnit("custom.service"));
}

test "computePaths honors XDG_CONFIG_HOME" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const w = try computePaths(aa, "/home/t", "/home/t/.cfg", "envless.service");
    try testing.expectEqualStrings("/home/t/.cfg/systemd/user", w.unit_dir);
    try testing.expectEqualStrings("/home/t/.cfg/systemd/user/envless.service", w.unit_abs);
    const f = try computePaths(aa, "/home/t", null, "envless.service");
    try testing.expectEqualStrings("/home/t/.config/systemd/user", f.unit_dir);
}

test "renderUnit contains required sections" {
    const a = testing.allocator;
    const txt = try renderUnit(a, "/usr/local/bin/envless", "/home/t", "/home/t/.cache/envless");
    defer a.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "[Unit]") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "[Service]") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "[Install]") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "ExecStart=/usr/local/bin/envless daemon") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "Restart=on-failure") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "Environment=HOME=/home/t") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "WantedBy=default.target") != null);
}
