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
extern fn getuid() callconv(.C) std.posix.uid_t;

const root = @import("root.zig");
const daemon = @import("../daemon.zig");
const ipc = @import("../ipc.zig");
const launchd = @import("../launchd.zig");
const systemd = @import("../systemd.zig");

pub fn run(ctx: *root.Context, args: []const []const u8) !u8 {
    if (args.len == 0) return runForeground(ctx);
    const sub = args[0];
    if (std.mem.eql(u8, sub, "install")) return runInstall(ctx);
    if (std.mem.eql(u8, sub, "uninstall")) return runUninstall(ctx);
    if (std.mem.eql(u8, sub, "status")) return runStatus(ctx);
    if (std.mem.eql(u8, sub, "stop")) return runStop(ctx);
    try ctx.stderr.writer().print("envless daemon: unknown subcommand: {s}\n", .{sub});
    return 1;
}

fn runForeground(ctx: *root.Context) !u8 {
    daemon.run(ctx.allocator) catch |err| {
        try ctx.stderr.writer().print("envless: daemon: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn runInstall(ctx: *root.Context) !u8 {
    const home = std.process.getEnvVarOwned(ctx.allocator, "HOME") catch |err| {
        try ctx.stderr.writer().print("envless: daemon install: HOME: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer ctx.allocator.free(home);

    const w = ctx.stdout.writer();

    switch (builtin.os.tag) {
        .macos => {
            const label_env = std.process.getEnvVarOwned(ctx.allocator, launchd.LABEL_ENV) catch null;
            defer if (label_env) |l| ctx.allocator.free(l);
            launchd.install(ctx.allocator, w, home, label_env, null) catch |err| {
                try ctx.stderr.writer().print("envless: daemon install: {s}\n", .{@errorName(err)});
                return 1;
            };
            return 0;
        },
        .linux => {
            const xdg = std.process.getEnvVarOwned(ctx.allocator, "XDG_CONFIG_HOME") catch null;
            defer if (xdg) |x| ctx.allocator.free(x);
            const unit_env = std.process.getEnvVarOwned(ctx.allocator, systemd.UNIT_ENV) catch null;
            defer if (unit_env) |u| ctx.allocator.free(u);
            systemd.install(ctx.allocator, w, home, xdg, unit_env, null) catch |err| {
                try ctx.stderr.writer().print("envless: daemon install: {s}\n", .{@errorName(err)});
                return 1;
            };
            return 0;
        },
        else => {
            try ctx.stderr.writer().writeAll("envless: daemon install: unsupported OS\n");
            return 1;
        },
    }
}

fn runUninstall(ctx: *root.Context) !u8 {
    const home = std.process.getEnvVarOwned(ctx.allocator, "HOME") catch |err| {
        try ctx.stderr.writer().print("envless: daemon uninstall: HOME: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer ctx.allocator.free(home);

    const w = ctx.stdout.writer();
    switch (builtin.os.tag) {
        .macos => {
            const label_env = std.process.getEnvVarOwned(ctx.allocator, launchd.LABEL_ENV) catch null;
            defer if (label_env) |l| ctx.allocator.free(l);
            launchd.uninstall(ctx.allocator, w, home, label_env) catch |err| {
                try ctx.stderr.writer().print("envless: daemon uninstall: {s}\n", .{@errorName(err)});
                return 1;
            };
            return 0;
        },
        .linux => {
            const xdg = std.process.getEnvVarOwned(ctx.allocator, "XDG_CONFIG_HOME") catch null;
            defer if (xdg) |x| ctx.allocator.free(x);
            const unit_env = std.process.getEnvVarOwned(ctx.allocator, systemd.UNIT_ENV) catch null;
            defer if (unit_env) |u| ctx.allocator.free(u);
            systemd.uninstall(ctx.allocator, w, home, xdg, unit_env) catch |err| {
                try ctx.stderr.writer().print("envless: daemon uninstall: {s}\n", .{@errorName(err)});
                return 1;
            };
            return 0;
        },
        else => {
            try ctx.stderr.writer().writeAll("envless: daemon uninstall: unsupported OS\n");
            return 1;
        },
    }
}

fn runStatus(ctx: *root.Context) !u8 {
    const home = std.process.getEnvVarOwned(ctx.allocator, "HOME") catch |err| {
        try ctx.stderr.writer().print("envless: daemon status: HOME: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer ctx.allocator.free(home);

    const w = ctx.stdout.writer();
    // Also probe the socket so the user sees both the supervisor view and
    // the runtime view in one pass.
    const sock = ipc.socketPath(ctx.allocator, home) catch null;
    if (sock) |s| {
        defer ctx.allocator.free(s);
        const ok = blk: {
            std.fs.cwd().access(s, .{}) catch break :blk false;
            break :blk true;
        };
        try w.print("[envless daemon] socket: {s} ({s})\n", .{ s, if (ok) "present" else "missing" });
    }
    switch (builtin.os.tag) {
        .macos => {
            const label_env = std.process.getEnvVarOwned(ctx.allocator, launchd.LABEL_ENV) catch null;
            defer if (label_env) |l| ctx.allocator.free(l);
            launchd.status(ctx.allocator, w, home, label_env) catch |err| {
                try ctx.stderr.writer().print("envless: daemon status: {s}\n", .{@errorName(err)});
                return 1;
            };
        },
        .linux => {
            const xdg = std.process.getEnvVarOwned(ctx.allocator, "XDG_CONFIG_HOME") catch null;
            defer if (xdg) |x| ctx.allocator.free(x);
            const unit_env = std.process.getEnvVarOwned(ctx.allocator, systemd.UNIT_ENV) catch null;
            defer if (unit_env) |u| ctx.allocator.free(u);
            systemd.status(ctx.allocator, w, home, xdg, unit_env) catch |err| {
                try ctx.stderr.writer().print("envless: daemon status: {s}\n", .{@errorName(err)});
                return 1;
            };
        },
        else => {
            try ctx.stderr.writer().writeAll("envless: daemon status: unsupported OS\n");
            return 1;
        },
    }
    return 0;
}

fn runStop(ctx: *root.Context) !u8 {
    // The supported shutdown path is whichever supervisor manages the
    // daemon: `launchctl kill TERM` on macOS, `systemctl stop` on Linux.
    // If neither is installed, we fall back to discovering the pid via
    // lsof on the socket and sending SIGTERM directly.
    const home = std.process.getEnvVarOwned(ctx.allocator, "HOME") catch |err| {
        try ctx.stderr.writer().print("envless: daemon stop: HOME: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer ctx.allocator.free(home);

    const w = ctx.stdout.writer();
    switch (builtin.os.tag) {
        .macos => {
            const label_env = std.process.getEnvVarOwned(ctx.allocator, launchd.LABEL_ENV) catch null;
            defer if (label_env) |l| ctx.allocator.free(l);
            const label = if (label_env) |l| l else launchd.DEFAULT_LABEL;
            const uid = getuid();
            const target = try std.fmt.allocPrint(ctx.allocator, "gui/{d}/{s}", .{ uid, label });
            defer ctx.allocator.free(target);
            const argv = [_][]const u8{ "/bin/launchctl", "kill", "TERM", target };
            const r = std.process.Child.run(.{ .allocator = ctx.allocator, .argv = &argv }) catch |err| {
                try ctx.stderr.writer().print("envless: daemon stop: launchctl spawn: {s}\n", .{@errorName(err)});
                return 1;
            };
            defer ctx.allocator.free(r.stdout);
            defer ctx.allocator.free(r.stderr);
            try w.print("[envless daemon] sent SIGTERM via launchctl ({s})\n", .{target});
            return 0;
        },
        .linux => {
            const unit_env = std.process.getEnvVarOwned(ctx.allocator, systemd.UNIT_ENV) catch null;
            defer if (unit_env) |u| ctx.allocator.free(u);
            const unit = if (unit_env) |u| u else systemd.DEFAULT_UNIT;
            const argv = [_][]const u8{ "systemctl", "--user", "stop", unit };
            const r = std.process.Child.run(.{ .allocator = ctx.allocator, .argv = &argv }) catch |err| {
                try ctx.stderr.writer().print("envless: daemon stop: systemctl spawn: {s}\n", .{@errorName(err)});
                return 1;
            };
            defer ctx.allocator.free(r.stdout);
            defer ctx.allocator.free(r.stderr);
            try w.print("[envless daemon] systemctl stop {s}\n", .{unit});
            return 0;
        },
        else => {
            try ctx.stderr.writer().writeAll("envless: daemon stop: unsupported OS\n");
            return 1;
        },
    }
}
