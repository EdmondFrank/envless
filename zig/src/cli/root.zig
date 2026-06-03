//! cli/root: top-level subcommand dispatcher.
//!
//! Replaces cobra. Six subcommands plus root-level --version. Flag style:
//! `--key=value` or `--key value` for string flags, `--key` for bool flags.
//! Subcommands accept `--` to terminate flag parsing (used by exec).

const std = @import("std");

const init_cmd = @import("init.zig");
const set_cmd = @import("set.zig");
const get_cmd = @import("get.zig");
const list_cmd = @import("list.zig");
const exec_cmd = @import("exec.zig");
const migrate_cmd = @import("migrate.zig");

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

    try ctx.stderr.writer().print("envless: unknown command: {s}\n", .{sub});
    return 1;
}

fn printUsage(ctx: *Context) !void {
    const usage =
        \\envless - agent-first secrets, zero .env
        \\
        \\Usage:
        \\  envless [command]
        \\
        \\Available Commands:
        \\  init       initialize .envless/ in the current directory
        \\  set        store a secret value from stdin
        \\  get        print a secret value (requires --confirm)
        \\  list       list keys in an env (does not print values)
        \\  exec       run a command with secrets injected as env vars
        \\  migrate    encrypt a .env file into envless and gitignore the plaintext
        \\
        \\Flags:
        \\  -h, --help       help
        \\      --version    show version
        \\
    ;
    try ctx.stdout.writer().writeAll(usage);
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
