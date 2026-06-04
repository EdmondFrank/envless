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

pub const Context = struct {
    allocator: std.mem.Allocator,
    cwd: []const u8, // owned
    stdin: std.fs.File,
    stdout: std.fs.File,
    stderr: std.fs.File,
    version: []const u8,

    pub fn deinit(self: *Context) void {
        self.allocator.free(self.cwd);
    }
};

pub fn run(allocator: std.mem.Allocator, argv: []const []const u8, version: []const u8) !u8 {
    var cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const cwd_slice = try std.process.getCwd(&cwd_buf);
    const cwd_owned = try allocator.dupe(u8, cwd_slice);

    var ctx = Context{
        .allocator = allocator,
        .cwd = cwd_owned,
        .stdin = std.io.getStdIn(),
        .stdout = std.io.getStdOut(),
        .stderr = std.io.getStdErr(),
        .version = version,
    };
    defer ctx.deinit();

    if (argv.len <= 1) {
        try printUsage(&ctx);
        return 0;
    }

    const sub = argv[1];

    if (std.mem.eql(u8, sub, "--version") or std.mem.eql(u8, sub, "-v")) {
        try ctx.stdout.writer().print("envless version {s}\n", .{version});
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

    try ctx.stderr.writer().print("envless: unknown command: {s}\n", .{sub});
    try ctx.stderr.writer().writeAll("Run `envless -h` for the list of commands.\n");
    return 2;
}

// -------------------------- TTY / ANSI helpers -------------------------------

/// Style is a thin abstraction over the ANSI sequences used by help output.
/// `enabled = stdout.isTty()` at construction time; when disabled, all of
/// `bold/dim/reset` return the empty string so the help text stays clean
/// for pagers, pipelines, and CI logs.
pub const Style = struct {
    enabled: bool,

    pub fn fromFile(f: std.fs.File) Style {
        // NO_COLOR (https://no-color.org) and a non-TTY both disable ANSI.
        if (std.process.hasEnvVarConstant("NO_COLOR")) return .{ .enabled = false };
        return .{ .enabled = f.isTty() };
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
    const w = ctx.stdout.writer();
    const s = Style.fromFile(ctx.stdout);
    const b = s.bold();
    const d = s.dim();
    const r = s.reset();

    try w.print("envless {s}— agent-first secrets, zero .env{s}\n\n", .{ d, r });

    try w.print("{s}Usage:{s}\n", .{ b, r });
    try w.writeAll("  envless <command> [flags] [args]\n\n");

    try w.print("{s}Commands:{s}\n", .{ b, r });
    try w.writeAll("  init       initialize .envless/ in the current directory\n");
    try w.writeAll("  set KEY    store a secret value from stdin (--env=NAME, default: dev)\n");
    try w.writeAll("  get KEY    print a secret value (requires --confirm)\n");
    try w.writeAll("  list       list keys in an env (does not print values)\n");
    try w.writeAll("  exec       run a command with secrets injected as env vars\n");
    try w.writeAll("  migrate    encrypt a .env file into envless and gitignore the plaintext\n");
    try w.writeAll("  backup     emit a tar.gz of the encrypted artefacts (identity excluded)\n");
    try w.writeAll("  mcp        run MCP server (JSON-RPC 2.0 over stdio) for agents\n");
    try w.writeAll("  daemon     run/install/uninstall/status the optional decrypt-cache daemon\n\n");

    try w.writeAll("Run `envless <command> -h` for command-specific help.\n\n");

    try w.print("{s}Examples:{s}\n", .{ b, r });
    try w.print("  {s}# First-time setup in a repo{s}\n", .{ d, r });
    try w.writeAll("  envless init\n");
    try w.writeAll("  echo \"sk-test-xyz\" | envless set OPENAI_API_KEY --env=dev\n");
    try w.writeAll("  envless list --env=dev\n");
    try w.writeAll("  envless exec --env=dev -- node server.js\n\n");
    try w.print("  {s}# Multi-environment{s}\n", .{ d, r });
    try w.writeAll("  echo \"sk-prod-real\" | envless set OPENAI_API_KEY --env=prod\n");
    try w.writeAll("  envless exec --env=prod -- npm run deploy\n\n");
    try w.print("  {s}# Migrate an existing .env file{s}\n", .{ d, r });
    try w.writeAll("  envless migrate .env --env=dev\n\n");
    try w.print("  {s}# Inspect without leaking values{s}\n", .{ d, r });
    try w.writeAll("  envless list --env=staging\n");
    try w.writeAll("  envless get DATABASE_URL --env=staging --confirm\n\n");

    try w.print("{s}Environment variables:{s}\n", .{ b, r });
    try w.writeAll("  SOPS_AGE_KEY_FILE   path to the age identity file (default: .envless/identity.key)\n");
    try w.writeAll("  EDITOR              editor used by interactive prompts (when applicable)\n");
    try w.writeAll("  NO_COLOR            if set, disable ANSI colors in help output\n\n");

    try w.print("{s}Files:{s}\n", .{ b, r });
    try w.writeAll("  .envless/identity.key   age secret key for this developer (chmod 0600, gitignored)\n");
    try w.writeAll("  .envless/recipients     age pubkeys with read access (committed)\n");
    try w.writeAll("  secrets/<env>.env.enc   sops-encrypted env files (committed)\n\n");

    try w.print("{s}Exit codes:{s}\n", .{ b, r });
    try w.writeAll("  0   success\n");
    try w.writeAll("  1   generic error\n");
    try w.writeAll("  2   usage error (bad flags, missing args)\n");
    try w.writeAll("  64  configuration error (missing .envless/, no identity)\n");
    try w.writeAll("  65  data error (corrupt sops file)\n");
    try w.writeAll("  66  not found (env / key not present)\n");
    try w.writeAll("  74  IO error (filesystem, exec)\n\n");

    try w.print("{s}Flags:{s}\n", .{ b, r });
    try w.writeAll("  -h, --help        show this help\n");
    try w.writeAll("      --version     print envless version\n\n");

    try w.writeAll("Docs: https://biliboss.github.io/envless/\n");
    try w.writeAll("Repo: https://github.com/biliboss/envless\n");
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
pub fn popStringFlag(args: []const []const u8, name: []const u8, out_rest: *std.ArrayList([]const u8)) !?[]const u8 {
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
        try out_rest.append(a);
    }
    return value;
}

/// Pop a boolean flag (e.g. "--confirm"). Removes it from args.
pub fn popBoolFlag(args: []const []const u8, name: []const u8, out_rest: *std.ArrayList([]const u8)) !bool {
    var found = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, name)) {
            found = true;
            continue;
        }
        try out_rest.append(a);
    }
    return found;
}

// ----------------------------- tests -----------------------------------------

const testing = std.testing;

test "popStringFlag --key=value" {
    const a = testing.allocator;
    var rest = std.ArrayList([]const u8).init(a);
    defer rest.deinit();
    const args = [_][]const u8{ "set", "--env=prod", "KEY" };
    const v = try popStringFlag(&args, "--env", &rest);
    try testing.expect(v != null);
    try testing.expectEqualStrings("prod", v.?);
    try testing.expectEqual(@as(usize, 2), rest.items.len);
    try testing.expectEqualStrings("set", rest.items[0]);
    try testing.expectEqualStrings("KEY", rest.items[1]);
}

test "popStringFlag --key value" {
    const a = testing.allocator;
    var rest = std.ArrayList([]const u8).init(a);
    defer rest.deinit();
    const args = [_][]const u8{ "--env", "prod", "KEY" };
    const v = try popStringFlag(&args, "--env", &rest);
    try testing.expect(v != null);
    try testing.expectEqualStrings("prod", v.?);
    try testing.expectEqual(@as(usize, 1), rest.items.len);
    try testing.expectEqualStrings("KEY", rest.items[0]);
}

test "popStringFlag absent returns null" {
    const a = testing.allocator;
    var rest = std.ArrayList([]const u8).init(a);
    defer rest.deinit();
    const args = [_][]const u8{ "set", "KEY" };
    const v = try popStringFlag(&args, "--env", &rest);
    try testing.expect(v == null);
    try testing.expectEqual(@as(usize, 2), rest.items.len);
}

test "popBoolFlag" {
    const a = testing.allocator;
    var rest = std.ArrayList([]const u8).init(a);
    defer rest.deinit();
    const args = [_][]const u8{ "get", "TOKEN", "--confirm" };
    const v = try popBoolFlag(&args, "--confirm", &rest);
    try testing.expect(v);
    try testing.expectEqual(@as(usize, 2), rest.items.len);
}
