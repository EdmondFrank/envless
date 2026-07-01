//! cli/root: top-level subcommand dispatcher.
//!
//! Replaces cobra. Six subcommands plus root-level --version. Flag style:
//! `--key=value` or `--key value` for string flags, `--key` for bool flags.
//! Subcommands accept `--` to terminate flag parsing (used by exec).
//!
//! Help output: `envless -h` / `envless help` writes the expressive usage
//! page to stdout and exits 0. Each subcommand owns its own `printHelp` —
//! see `init.zig`, `set.zig`, etc. The dispatcher only intercepts -h/--help
//! for the top-level case; per-subcommand `-h` is handled inside each
//! `run` so subcommand-specific behavior stays co-located.
//!
//! Exit codes (see also AGENTS.md / docs/cli):
//!   0   success
//!   1   generic error (sops, store, IO failure once the args parsed)
//!   2   usage error (unknown command, bad flags, missing args)
//!  64   configuration error (no .envless/ — surfaced via store errors)
//!  65   data error (corrupt sops file)
//!  66   not found (env / key absent)
//!  74   IO error (filesystem, exec)
//!
//! Note: subcommands currently return 1 on most error paths. The exit-code
//! taxonomy above is the documented contract for callers and is enforced
//! incrementally; help text reflects the target, not necessarily the
//! current behavior of every error branch.

const std = @import("std");

const init_cmd = @import("init.zig");
const set_cmd = @import("set.zig");
const get_cmd = @import("get.zig");
const list_cmd = @import("list.zig");
const exec_cmd = @import("exec.zig");
const migrate_cmd = @import("migrate.zig");
const mcp_cmd = @import("mcp.zig");
const daemon_cmd = @import("daemon.zig");
const backup_cmd = @import("backup.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8, // owned
    stdin: std.Io.File,
    stdout: std.Io.File,
    stderr: std.Io.File,
    version: []const u8,
    _out_buf: [4096]u8 = undefined,
    _err_buf: [4096]u8 = undefined,

    pub fn deinit(self: *Context) void {
        self.allocator.free(self.cwd);
    }

    /// Create a buffered writer for stdout. Borrows `_out_buf` from self.
    pub fn stdoutWriter(self: *Context) std.Io.File.Writer {
        return self.stdout.writer(self.io, &self._out_buf);
    }

    /// Create a buffered writer for stderr. Borrows `_err_buf` from self.
    pub fn stderrWriter(self: *Context) std.Io.File.Writer {
        return self.stderr.writer(self.io, &self._err_buf);
    }

    /// One-shot stdout print (creates writer, prints, flushes).
    pub fn outPrint(self: *Context, comptime fmt: []const u8, args: anytype) !void {
        var w = self.stdoutWriter();
        try w.interface.print(fmt, args);
        try w.flush();
    }

    /// One-shot stdout writeAll (creates writer, writes, flushes).
    pub fn outWriteAll(self: *Context, data: []const u8) !void {
        var w = self.stdoutWriter();
        try w.interface.writeAll(data);
        try w.flush();
    }

    /// One-shot stderr print (creates writer, prints, flushes).
    pub fn errPrint(self: *Context, comptime fmt: []const u8, args: anytype) !void {
        var w = self.stderrWriter();
        try w.interface.print(fmt, args);
        try w.flush();
    }

    /// One-shot stderr writeAll (creates writer, writes, flushes).
    pub fn errWriteAll(self: *Context, data: []const u8) !void {
        var w = self.stderrWriter();
        try w.interface.writeAll(data);
        try w.flush();
    }
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, version: []const u8) !u8 {
    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const cwd_owned = try allocator.dupe(u8, cwd_buf[0..cwd_len]);

    var ctx = Context{
        .allocator = allocator,
        .io = io,
        .cwd = cwd_owned,
        .stdin = std.Io.File.stdin(),
        .stdout = std.Io.File.stdout(),
        .stderr = std.Io.File.stderr(),
        .version = version,
    };
    defer ctx.deinit();

    if (argv.len <= 1) {
        try printUsage(&ctx);
        return 0;
    }

    const sub = argv[1];

    if (std.mem.eql(u8, sub, "--version") or std.mem.eql(u8, sub, "-v")) {
        try ctx.outPrint("envless version {s}\n", .{version});
        return 0;
    }
    if (std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h") or std.mem.eql(u8, sub, "help")) {
        try printUsage(&ctx);
        return 0;
    }

    const rest = argv[2..];

    if (std.mem.eql(u8, sub, "init")) return init_cmd.run(&ctx, rest);
    if (std.mem.eql(u8, sub, "set")) return set_cmd.run(&ctx, rest);
    if (std.mem.eql(u8, sub, "get")) return get_cmd.run(&ctx, rest);
    if (std.mem.eql(u8, sub, "list")) return list_cmd.run(&ctx, rest);
    if (std.mem.eql(u8, sub, "exec")) return exec_cmd.run(&ctx, rest);
    if (std.mem.eql(u8, sub, "migrate")) return migrate_cmd.run(&ctx, rest);
    if (std.mem.eql(u8, sub, "mcp")) return mcp_cmd.run(&ctx, rest);
    if (std.mem.eql(u8, sub, "daemon")) return daemon_cmd.run(&ctx, rest);
    if (std.mem.eql(u8, sub, "backup")) return backup_cmd.run(&ctx, rest);

    try ctx.errPrint("envless: unknown command: {s}\n", .{sub});
    try ctx.errWriteAll("Run `envless -h` for the list of commands.\n");
    return 2;
}

// -------------------------- TTY / ANSI helpers -------------------------------

/// Style is a thin abstraction over the ANSI sequences used by help output.
/// `enabled = stdout.isTty()` at construction time; when disabled, all of
/// `bold/dim/reset` return the empty string so the help text stays clean
/// for pagers, pipelines, and CI logs.
pub const Style = struct {
    enabled: bool,

    pub fn fromFile(io: std.Io, f: std.Io.File) !Style {
        // NO_COLOR (https://no-color.org) and a non-TTY both disable ANSI.
        if (std.c.getenv("NO_COLOR") != null) return .{ .enabled = false };
        return .{ .enabled = try f.isTty(io) };
    }

    pub fn bold(self: Style) []const u8 {
        return if (self.enabled) "\x1b[1m" else "";
    }
    pub fn dim(self: Style) []const u8 {
        return if (self.enabled) "\x1b[2m" else "";
    }
    pub fn reset(self: Style) []const u8 {
        return if (self.enabled) "\x1b[0m" else "";
    }
};

/// Returns true if `args` requests help (`-h` or `--help`). Used by every
/// subcommand at the top of `run` so per-command help stays co-located.
pub fn wantsHelp(args: []const []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) return true;
    }
    return false;
}

fn printUsage(ctx: *Context) !void {
    var w = ctx.stdoutWriter();
    const s = try Style.fromFile(ctx.io, ctx.stdout);
    const b = s.bold();
    const d = s.dim();
    const r = s.reset();

    try w.interface.print("envless {s}— agent-first secrets, zero .env{s}\n\n", .{ d, r });

    try w.interface.print("{s}Usage:{s}\n", .{ b, r });
    try w.interface.writeAll("  envless <command> [flags] [args]\n\n");

    try w.interface.print("{s}Commands:{s}\n", .{ b, r });
    try w.interface.writeAll("  init       initialize .envless/ in the current directory\n");
    try w.interface.writeAll("  set KEY    store a secret value from stdin (--env=NAME, default: dev)\n");
    try w.interface.writeAll("  get KEY    print a secret value (requires --confirm)\n");
    try w.interface.writeAll("  list       list keys in an env (does not print values)\n");
    try w.interface.writeAll("  exec       run a command with secrets injected as env vars\n");
    try w.interface.writeAll("  migrate    encrypt a .env file into envless and gitignore the plaintext\n");
    try w.interface.writeAll("  backup     emit a tar.gz of the encrypted artefacts (identity excluded)\n");
    try w.interface.writeAll("  mcp        run MCP server (JSON-RPC 2.0 over stdio) for agents\n");
    try w.interface.writeAll("  daemon     run/install/uninstall/status the optional decrypt-cache daemon\n\n");

    try w.interface.writeAll("Run `envless <command> -h` for command-specific help.\n\n");

    try w.interface.print("{s}Examples:{s}\n", .{ b, r });
    try w.interface.print("  {s}# First-time setup in a repo{s}\n", .{ d, r });
    try w.interface.writeAll("  envless init\n");
    try w.interface.writeAll("  echo \"sk-test-xyz\" | envless set OPENAI_API_KEY --env=dev\n");
    try w.interface.writeAll("  envless list --env=dev\n");
    try w.interface.writeAll("  envless exec --env=dev -- node server.js\n\n");
    try w.interface.print("  {s}# Multi-environment{s}\n", .{ d, r });
    try w.interface.writeAll("  echo \"sk-prod-real\" | envless set OPENAI_API_KEY --env=prod\n");
    try w.interface.writeAll("  envless exec --env=prod -- npm run deploy\n\n");
    try w.interface.print("  {s}# Migrate an existing .env file{s}\n", .{ d, r });
    try w.interface.writeAll("  envless migrate .env --env=dev\n\n");
    try w.interface.print("  {s}# Inspect without leaking values{s}\n", .{ d, r });
    try w.interface.writeAll("  envless list --env=staging\n");
    try w.interface.writeAll("  envless get DATABASE_URL --env=staging --confirm\n\n");

    try w.interface.print("{s}Environment variables:{s}\n", .{ b, r });
    try w.interface.writeAll("  SOPS_AGE_KEY_FILE   path to the age identity file (default: .envless/identity.key)\n");
    try w.interface.writeAll("  EDITOR              editor used by interactive prompts (when applicable)\n");
    try w.interface.writeAll("  NO_COLOR            if set, disable ANSI colors in help output\n\n");

    try w.interface.print("{s}Files:{s}\n", .{ b, r });
    try w.interface.writeAll("  .envless/identity.key   age secret key for this developer (chmod 0600, gitignored)\n");
    try w.interface.writeAll("  .envless/recipients     age pubkeys with read access (committed)\n");
    try w.interface.writeAll("  secrets/<env>.env.enc   sops-encrypted env files (committed)\n\n");

    try w.interface.print("{s}Exit codes:{s}\n", .{ b, r });
    try w.interface.writeAll("  0   success\n");
    try w.interface.writeAll("  1   generic error\n");
    try w.interface.writeAll("  2   usage error (bad flags, missing args)\n");
    try w.interface.writeAll("  64  configuration error (missing .envless/, no identity)\n");
    try w.interface.writeAll("  65  data error (corrupt sops file)\n");
    try w.interface.writeAll("  66  not found (env / key not present)\n");
    try w.interface.writeAll("  74  IO error (filesystem, exec)\n\n");

    try w.interface.print("{s}Flags:{s}\n", .{ b, r });
    try w.interface.writeAll("  -h, --help        show this help\n");
    try w.interface.writeAll("      --version     print envless version\n\n");

    try w.interface.writeAll("Docs: https://biliboss.github.io/envless/\n");
    try w.interface.writeAll("Repo: https://github.com/biliboss/envless\n");
    try w.flush();
}

// ----------------------------- shared helpers --------------------------------

pub const FlagParseError = error{
    UnknownFlag,
    MissingFlagValue,
};

/// Pop a string flag from args by name (e.g. "--env"). Supports both
/// "--env=value" and "--env value" forms. Returns the matched value (borrowed
/// from argv) and removes both elements from `args_out`. If the flag is not
/// present, returns null.
pub fn popStringFlag(allocator: std.mem.Allocator, args: []const []const u8, name: []const u8, out_rest: *std.ArrayList([]const u8)) !?[]const u8 {
    var value: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.startsWith(u8, a, name)) {
            if (a.len == name.len) {
                // "--env" alone: next arg is value
                if (i + 1 >= args.len) return FlagParseError.MissingFlagValue;
                value = args[i + 1];
                i += 1; // skip value
                continue;
            }
            if (a[name.len] == '=') {
                value = a[name.len + 1 ..];
                continue;
            }
        }
        try out_rest.append(allocator, a);
    }
    return value;
}

/// Pop a boolean flag (e.g. "--confirm"). Removes it from args.
pub fn popBoolFlag(allocator: std.mem.Allocator, args: []const []const u8, name: []const u8, out_rest: *std.ArrayList([]const u8)) !bool {
    var found = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, name)) {
            found = true;
            continue;
        }
        try out_rest.append(allocator, a);
    }
    return found;
}

// ----------------------------- tests -----------------------------------------

const testing = std.testing;

test "popStringFlag --key=value" {
    const a = testing.allocator;
    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(a);
    const args = [_][]const u8{ "set", "--env=prod", "KEY" };
    const v = try popStringFlag(a, &args, "--env", &rest);
    try testing.expect(v != null);
    try testing.expectEqualStrings("prod", v.?);
    try testing.expectEqual(@as(usize, 2), rest.items.len);
    try testing.expectEqualStrings("set", rest.items[0]);
    try testing.expectEqualStrings("KEY", rest.items[1]);
}

test "popStringFlag --key value" {
    const a = testing.allocator;
    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(a);
    const args = [_][]const u8{ "--env", "prod", "KEY" };
    const v = try popStringFlag(a, &args, "--env", &rest);
    try testing.expect(v != null);
    try testing.expectEqualStrings("prod", v.?);
    try testing.expectEqual(@as(usize, 1), rest.items.len);
    try testing.expectEqualStrings("KEY", rest.items[0]);
}

test "popStringFlag absent returns null" {
    const a = testing.allocator;
    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(a);
    const args = [_][]const u8{ "set", "KEY" };
    const v = try popStringFlag(a, &args, "--env", &rest);
    try testing.expect(v == null);
    try testing.expectEqual(@as(usize, 2), rest.items.len);
}

test "popBoolFlag" {
    const a = testing.allocator;
    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(a);
    const args = [_][]const u8{ "get", "TOKEN", "--confirm" };
    const v = try popBoolFlag(a, &args, "--confirm", &rest);
    try testing.expect(v);
    try testing.expectEqual(@as(usize, 2), rest.items.len);
}
