//! `envless backup [--output PATH] [--include-identity] [--yes]` — emit a
//! tar.gz of envless state.
//!
//! Default behaviour is "safe to upload anywhere": `.envless/recipients` and
//! every `secrets/<env>.env.enc` plus a `MANIFEST.json`. The identity key is
//! NEVER bundled unless `--include-identity` is set, and even then a
//! multi-line warning is printed to stderr and an interactive confirmation
//! is required (or `--yes` for scripts).
//!
//! Exit codes:
//!   0  — success
//!   1  — user cancelled the identity prompt
//!   2  — usage error (e.g. --include-identity without --yes in non-TTY)
//!   64 — no .envless/identity.key found by walking up from cwd
//!   74 — IO / tar / manifest failure

const std = @import("std");
const backup_mod = @import("../backup.zig");
const root = @import("root.zig");

const IDENTITY_WARNING =
    "WARNING: --include-identity will write your age secret key into the\n" ++
    "backup tarball. Anyone who obtains this tarball can decrypt every\n" ++
    "secret you have access to.\n" ++
    "\n" ++
    "Do NOT upload this tarball to a cloud provider you do not fully\n" ++
    "trust. Acceptable destinations:\n" ++
    "  - encrypted local backup (FileVault / LUKS volume)\n" ++
    "  - password manager (1Password / Bitwarden) as a single attachment\n" ++
    "  - GPG-encrypted before any cloud upload\n" ++
    "\n" ++
    "Unacceptable destinations:\n" ++
    "  - plain Google Drive / iCloud / Dropbox\n" ++
    "  - unencrypted external drives\n" ++
    "  - email\n" ++
    "  - Slack / Teams / Discord\n" ++
    "\n" ++
    "Continue? [y/N]\n";

pub fn run(ctx: *root.Context, args: []const []const u8) !u8 {
    // Pop --output.
    var after_output = std.ArrayList([]const u8).init(ctx.allocator);
    defer after_output.deinit();
    const output_opt = try root.popStringFlag(args, "--output", &after_output);

    // Pop --include-identity.
    var after_include = std.ArrayList([]const u8).init(ctx.allocator);
    defer after_include.deinit();
    const include_identity = try root.popBoolFlag(after_output.items, "--include-identity", &after_include);

    // Pop --yes.
    var rest = std.ArrayList([]const u8).init(ctx.allocator);
    defer rest.deinit();
    const yes = try root.popBoolFlag(after_include.items, "--yes", &rest);

    if (rest.items.len != 0) {
        try ctx.stderr.writer().writeAll("envless: backup takes no positional arguments\n");
        return 2;
    }

    // Resolve the repo root by walking up from cwd until .envless/identity.key
    // is found. This is what makes `envless backup` work from any subdirectory
    // of the repo.
    const repo_root = backup_mod.findRepoRoot(ctx.allocator, ctx.cwd) catch |err| switch (err) {
        backup_mod.Error.NoEnvlessRoot => {
            try ctx.stderr.writer().writeAll(
                "envless: backup: no .envless/identity.key found in current directory or any parent\n",
            );
            return 64;
        },
        else => {
            try ctx.stderr.writer().print("envless: backup: {s}\n", .{@errorName(err)});
            return 74;
        },
    };
    defer ctx.allocator.free(repo_root);

    // --include-identity gating.
    if (include_identity) {
        if (yes) {
            // Script context: --yes was passed explicitly. Print the warning
            // to stderr for the audit trail but skip the prompt.
            try ctx.stderr.writer().writeAll(IDENTITY_WARNING);
        } else if (!stdinIsTty(ctx)) {
            // Non-interactive without --yes: refuse.
            try ctx.stderr.writer().writeAll(
                "envless: backup: refusing to include identity in non-interactive backup; pass --yes to override\n",
            );
            return 2;
        } else {
            // Interactive: prompt.
            try ctx.stderr.writer().writeAll(IDENTITY_WARNING);
            const ok = readYes(ctx) catch false;
            if (!ok) {
                try ctx.stderr.writer().writeAll("envless: backup: cancelled\n");
                return 1;
            }
        }
    }

    // Build options for the backup module.
    var version_buf = std.ArrayList(u8).init(ctx.allocator);
    defer version_buf.deinit();
    // Prepend a "v" if the version doesn't already start with one. The CI
    // build feeds versions like "v0.1.0"; dev builds get "dev". Either is fine
    // verbatim — emit as-is.
    try version_buf.appendSlice(ctx.version);

    const opts = backup_mod.Options{
        .repo_root = repo_root,
        .version = version_buf.items,
        .output_path = output_opt,
        .include_identity = include_identity,
    };

    backup_mod.run(ctx.allocator, opts) catch |err| {
        try ctx.stderr.writer().print("envless: backup: {s}\n", .{@errorName(err)});
        return 74;
    };

    // Only print a confirmation line on stderr when writing to a real file —
    // when streaming to stdout, the user is piping the bytes onwards and any
    // chatter on stdout would corrupt the stream. (We pick stderr for the
    // ack, mirroring `git push`'s pattern.)
    if (opts.output_path) |p| {
        if (!std.mem.eql(u8, p, "-")) {
            try ctx.stderr.writer().print(
                "BACKUP  out={s} identity={s}\n",
                .{ p, if (include_identity) "included" else "excluded" },
            );
        }
    }
    return 0;
}

fn stdinIsTty(ctx: *root.Context) bool {
    return std.posix.isatty(ctx.stdin.handle);
}

/// Read a line from stdin; return true iff the trimmed answer is "y" or "Y".
/// EOF, empty line, anything else → false.
fn readYes(ctx: *root.Context) !bool {
    var buf: [256]u8 = undefined;
    const r = try ctx.stdin.read(&buf);
    if (r == 0) return false;
    const line = std.mem.trim(u8, buf[0..r], " \t\r\n");
    return std.mem.eql(u8, line, "y") or std.mem.eql(u8, line, "Y");
}
