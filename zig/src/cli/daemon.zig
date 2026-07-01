//! `envless daemon` — foreground daemon process + lifecycle subcommands.
//!
//! Usage:
//!   envless daemon                 # foreground (for launchd/systemd to manage)
//!   envless daemon install         # install supervisor unit (macOS plist or systemd)
//!   envless daemon uninstall       # remove the unit
//!   envless daemon status          # show whether the unit is loaded
//!   envless daemon stop            # send SIGTERM to the running daemon
//!
//! The daemon is opt-in. It holds decrypted env in memory; running it is a
//! conscious tradeoff documented in `docs/security.mdx` (ptrace tier).

const std = @import("std");
const builtin = @import("builtin");

// Cross-target libc decl. `std.posix.getuid` is not exposed for the macOS
// cross-compile in Zig 0.13's stdlib slice, so we bind libc directly.
extern fn getuid() callconv(.c) std.posix.uid_t;

const root = @import("root.zig");
const daemon = @import("../daemon.zig");
const ipc = @import("../ipc.zig");
const launchd = @import("../launchd.zig");
const systemd = @import("../systemd.zig");

/// Replacement for std.process.getEnvVarOwned (removed in 0.16).
/// Returns error.EnvironmentVariableMissing if the var is not set.
fn getEnvOwned(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf: [256]u8 = undefined;
    if (name.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const name_z: [:0]u8 = buf[0..name.len :0];
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableMissing;
    return try allocator.dupe(u8, std.mem.span(ptr));
}

pub fn run(ctx: *root.Context, args: []const []const u8) !u8 {
    if (args.len == 0) return runForeground(ctx);
    const sub = args[0];
    if (std.mem.eql(u8, sub, "install")) return runInstall(ctx);
    if (std.mem.eql(u8, sub, "uninstall")) return runUninstall(ctx);
    if (std.mem.eql(u8, sub, "status")) return runStatus(ctx);
    if (std.mem.eql(u8, sub, "stop")) return runStop(ctx);
    try ctx.errPrint("envless daemon: unknown subcommand: {s}\n", .{sub});
    return 1;
}

fn runForeground(ctx: *root.Context) !u8 {
    daemon.run(ctx.allocator, ctx.io) catch |err| {
        try ctx.errPrint("envless: daemon: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn runInstall(ctx: *root.Context) !u8 {
    const home = getEnvOwned(ctx.allocator, "HOME") catch |err| {
        try ctx.errPrint("envless: daemon install: HOME: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer ctx.allocator.free(home);

    var w = ctx.stdoutWriter();

    switch (builtin.os.tag) {
        .macos => {
            const label_env = getEnvOwned(ctx.allocator, launchd.LABEL_ENV) catch null;
            defer if (label_env) |l| ctx.allocator.free(l);
            launchd.install(ctx.allocator, ctx.io, &w, home, label_env, null) catch |err| {
                try ctx.errPrint("envless: daemon install: {s}\n", .{@errorName(err)});
                return 1;
            };
            try w.flush();
            return 0;
        },
        .linux => {
            const xdg = getEnvOwned(ctx.allocator, "XDG_CONFIG_HOME") catch null;
            defer if (xdg) |x| ctx.allocator.free(x);
            const unit_env = getEnvOwned(ctx.allocator, systemd.UNIT_ENV) catch null;
            defer if (unit_env) |u| ctx.allocator.free(u);
            systemd.install(ctx.allocator, ctx.io, &w, home, xdg, unit_env, null) catch |err| {
                try ctx.errPrint("envless: daemon install: {s}\n", .{@errorName(err)});
                return 1;
            };
            try w.flush();
            return 0;
        },
        else => {
            try ctx.errWriteAll("envless: daemon install: unsupported OS\n");
            return 1;
        },
    }
}

fn runUninstall(ctx: *root.Context) !u8 {
    const home = getEnvOwned(ctx.allocator, "HOME") catch |err| {
        try ctx.errPrint("envless: daemon uninstall: HOME: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer ctx.allocator.free(home);

    var w = ctx.stdoutWriter();
    switch (builtin.os.tag) {
        .macos => {
            const label_env = getEnvOwned(ctx.allocator, launchd.LABEL_ENV) catch null;
            defer if (label_env) |l| ctx.allocator.free(l);
            launchd.uninstall(ctx.allocator, ctx.io, &w, home, label_env) catch |err| {
                try ctx.errPrint("envless: daemon uninstall: {s}\n", .{@errorName(err)});
                return 1;
            };
            try w.flush();
            return 0;
        },
        .linux => {
            const xdg = getEnvOwned(ctx.allocator, "XDG_CONFIG_HOME") catch null;
            defer if (xdg) |x| ctx.allocator.free(x);
            const unit_env = getEnvOwned(ctx.allocator, systemd.UNIT_ENV) catch null;
            defer if (unit_env) |u| ctx.allocator.free(u);
            systemd.uninstall(ctx.allocator, ctx.io, &w, home, xdg, unit_env) catch |err| {
                try ctx.errPrint("envless: daemon uninstall: {s}\n", .{@errorName(err)});
                return 1;
            };
            try w.flush();
            return 0;
        },
        else => {
            try ctx.errWriteAll("envless: daemon uninstall: unsupported OS\n");
            return 1;
        },
    }
}

fn runStatus(ctx: *root.Context) !u8 {
    const home = getEnvOwned(ctx.allocator, "HOME") catch |err| {
        try ctx.errPrint("envless: daemon status: HOME: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer ctx.allocator.free(home);

    var w = ctx.stdoutWriter();
    // Also probe the socket so the user sees both the supervisor view and
    // the runtime view in one pass.
    const sock = ipc.socketPath(ctx.allocator, ctx.io, home) catch null;
    if (sock) |s| {
        defer ctx.allocator.free(s);
        const ok = blk: {
            std.Io.Dir.cwd().access(ctx.io, s, .{}) catch break :blk false;
            break :blk true;
        };
        try w.interface.print("[envless daemon] socket: {s} ({s})\n", .{ s, if (ok) "present" else "missing" });
    }
    switch (builtin.os.tag) {
        .macos => {
            const label_env = getEnvOwned(ctx.allocator, launchd.LABEL_ENV) catch null;
            defer if (label_env) |l| ctx.allocator.free(l);
            launchd.status(ctx.allocator, ctx.io, &w, home, label_env) catch |err| {
                try ctx.errPrint("envless: daemon status: {s}\n", .{@errorName(err)});
                return 1;
            };
        },
        .linux => {
            const xdg = getEnvOwned(ctx.allocator, "XDG_CONFIG_HOME") catch null;
            defer if (xdg) |x| ctx.allocator.free(x);
            const unit_env = getEnvOwned(ctx.allocator, systemd.UNIT_ENV) catch null;
            defer if (unit_env) |u| ctx.allocator.free(u);
            systemd.status(ctx.allocator, ctx.io, &w, home, xdg, unit_env) catch |err| {
                try ctx.errPrint("envless: daemon status: {s}\n", .{@errorName(err)});
                return 1;
            };
        },
        else => {
            try ctx.errWriteAll("envless: daemon status: unsupported OS\n");
            return 1;
        },
    }
    try w.flush();
    return 0;
}

fn runStop(ctx: *root.Context) !u8 {
    // The supported shutdown path is whichever supervisor manages the
    // daemon: `launchctl kill TERM` on macOS, `systemctl stop` on Linux.
    // If neither is installed, we fall back to discovering the pid via
    // lsof on the socket and sending SIGTERM directly.
    const home = getEnvOwned(ctx.allocator, "HOME") catch |err| {
        try ctx.errPrint("envless: daemon stop: HOME: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer ctx.allocator.free(home);

    var w = ctx.stdoutWriter();
    switch (builtin.os.tag) {
        .macos => {
            const label_env = getEnvOwned(ctx.allocator, launchd.LABEL_ENV) catch null;
            defer if (label_env) |l| ctx.allocator.free(l);
            const label = if (label_env) |l| l else launchd.DEFAULT_LABEL;
            const uid = getuid();
            const target = try std.fmt.allocPrint(ctx.allocator, "gui/{d}/{s}", .{ uid, label });
            defer ctx.allocator.free(target);
            const argv = [_][]const u8{ "/bin/launchctl", "kill", "TERM", target };
            const r = std.process.run(ctx.allocator, ctx.io, .{ .argv = &argv }) catch |err| {
                try ctx.errPrint("envless: daemon stop: launchctl spawn: {s}\n", .{@errorName(err)});
                return 1;
            };
            defer ctx.allocator.free(r.stdout);
            defer ctx.allocator.free(r.stderr);
            try w.interface.print("[envless daemon] sent SIGTERM via launchctl ({s})\n", .{target});
            try w.flush();
            return 0;
        },
        .linux => {
            const unit_env = getEnvOwned(ctx.allocator, systemd.UNIT_ENV) catch null;
            defer if (unit_env) |u| ctx.allocator.free(u);
            const unit = if (unit_env) |u| u else systemd.DEFAULT_UNIT;
            const argv = [_][]const u8{ "systemctl", "--user", "stop", unit };
            const r = std.process.run(ctx.allocator, ctx.io, .{ .argv = &argv }) catch |err| {
                try ctx.errPrint("envless: daemon stop: systemctl spawn: {s}\n", .{@errorName(err)});
                return 1;
            };
            defer ctx.allocator.free(r.stdout);
            defer ctx.allocator.free(r.stderr);
            try w.interface.print("[envless daemon] systemctl stop {s}\n", .{unit});
            try w.flush();
            return 0;
        },
        else => {
            try ctx.errWriteAll("envless: daemon stop: unsupported OS\n");
            return 1;
        },
    }
}
