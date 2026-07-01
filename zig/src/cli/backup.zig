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
    if (root.wantsHelp(args)) {
        try printHelp(ctx);
        return 0;
    }

    // Pop --output.
    var after_output: std.ArrayList([]const u8) = .empty;
    defer after_output.deinit(ctx.allocator);
    const output_opt = try root.popStringFlag(ctx.allocator, args, "--output", &after_output);

    // Pop --include-identity.
    var after_include: std.ArrayList([]const u8) = .empty;
    defer after_include.deinit(ctx.allocator);
    const include_identity = try root.popBoolFlag(ctx.allocator, after_output.items, "--include-identity", &after_include);

    // Pop --yes.
    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(ctx.allocator);
    const yes = try root.popBoolFlag(ctx.allocator, after_include.items, "--yes", &rest);

    if (rest.items.len != 0) {
        try ctx.errWriteAll("envless: backup takes no positional arguments\n");
        return 2;
    }

    // Resolve the repo root by walking up from cwd until .envless/identity.key
    // is found. This is what makes `envless backup` work from any subdirectory
    // of the repo.
    const repo_root = backup_mod.findRepoRoot(ctx.allocator, ctx.io, ctx.cwd) catch |err| switch (err) {
        backup_mod.Error.NoEnvlessRoot => {
            try ctx.errWriteAll(
                "envless: backup: no .envless/identity.key found in current directory or any parent\n",
            );
            return 64;
        },
        else => {
            try ctx.errPrint("envless: backup: {s}\n", .{@errorName(err)});
            return 74;
        },
    };
    defer ctx.allocator.free(repo_root);

    // --include-identity gating.
    if (include_identity) {
        if (yes) {
            // Script context: --yes was passed explicitly. Print the warning
            // to stderr for the audit trail but skip the prompt.
            try ctx.errWriteAll(IDENTITY_WARNING);
        } else if (!stdinIsTty(ctx)) {
            // Non-interactive without --yes: refuse.
            try ctx.errWriteAll(
                "envless: backup: refusing to include identity in non-interactive backup; pass --yes to override\n",
            );
            return 2;
        } else {
            // Interactive: prompt.
            try ctx.errWriteAll(IDENTITY_WARNING);
            const ok = readYes(ctx) catch false;
            if (!ok) {
                try ctx.errWriteAll("envless: backup: cancelled\n");
                return 1;
            }
        }
    }

    // Build options for the backup module.
    var version_buf: std.ArrayList(u8) = .empty;
    defer version_buf.deinit(ctx.allocator);
    // Prepend a "v" if the version doesn't already start with one. The CI
    // build feeds versions like "v0.1.0"; dev builds get "dev". Either is fine
    // verbatim — emit as-is.
    try version_buf.appendSlice(ctx.allocator, ctx.version);

    const opts = backup_mod.Options{
        .repo_root = repo_root,
        .version = version_buf.items,
        .output_path = output_opt,
        .include_identity = include_identity,
    };

    backup_mod.run(ctx.allocator, ctx.io, opts) catch |err| {
        try ctx.errPrint("envless: backup: {s}\n", .{@errorName(err)});
        return 74;
    };

    // Only print a confirmation line on stderr when writing to a real file —
    // when streaming to stdout, the user is piping the bytes onwards and any
    // chatter on stdout would corrupt the stream. (We pick stderr for the
    // ack, mirroring `git push`'s pattern.)
    if (opts.output_path) |p| {
        if (!std.mem.eql(u8, p, "-")) {
            try ctx.errPrint(
                "BACKUP  out={s} identity={s}\n",
                .{ p, if (include_identity) "included" else "excluded" },
            );
        }
    }
    return 0;
}

fn stdinIsTty(ctx: *root.Context) bool {
    return ctx.stdin.isTty(ctx.io) catch false;
}

/// Read a line from stdin; return true iff the trimmed answer is "y" or "Y".
/// EOF, empty line, anything else → false.
fn readYes(ctx: *root.Context) !bool {
    var reader_buf: [256]u8 = undefined;
    var stdin_reader = ctx.stdin.reader(ctx.io, &reader_buf);
    var buf: [256]u8 = undefined;
    const r = try stdin_reader.interface.readSliceShort(&buf);
    if (r == 0) return false;
    const line = std.mem.trim(u8, buf[0..r], " \t\r\n");
    return std.mem.eql(u8, line, "y") or std.mem.eql(u8, line, "Y");
}

fn printHelp(ctx: *root.Context) !void {
    var w = ctx.stdoutWriter();
    const s = try root.Style.fromFile(ctx.io, ctx.stdout);
    const b = s.bold();
    const d = s.dim();
    const r = s.reset();

    try w.interface.print("envless backup {s}— emit tar.gz of encrypted artefacts (identity excluded){s}\n\n", .{ d, r });

    try w.interface.print("{s}Usage:{s}\n", .{ b, r });
    try w.interface.writeAll("  envless backup [--output PATH] [--include-identity] [--yes]\n\n");

    try w.interface.print("{s}Description:{s}\n", .{ b, r });
    try w.interface.writeAll("  Bundles .envless/recipients + secrets/*.env.enc + MANIFEST.json into\n");
    try w.interface.writeAll("  a single tar.gz. The age secret key (.envless/identity.key) is\n");
    try w.interface.writeAll("  EXCLUDED by default so the resulting tarball is safe to upload to\n");
    try w.interface.writeAll("  any storage destination. --include-identity opts in to including\n");
    try w.interface.writeAll("  the secret key; requires interactive confirmation, or --yes in a\n");
    try w.interface.writeAll("  non-TTY context.\n\n");
    try w.interface.writeAll("  envless backup walks up from cwd looking for .envless/identity.key\n");
    try w.interface.writeAll("  to resolve the repo root, so it works from any subdirectory.\n\n");

    try w.interface.print("{s}Flags:{s}\n", .{ b, r });
    try w.interface.writeAll("  --output PATH         write tarball to PATH ('-' or omitted = stdout)\n");
    try w.interface.writeAll("  --include-identity    also include .envless/identity.key (DANGER)\n");
    try w.interface.writeAll("  --yes                 bypass interactive confirm (required in non-TTY)\n");
    try w.interface.writeAll("  -h, --help            show this help\n\n");

    try w.interface.print("{s}Examples:{s}\n", .{ b, r });
    try w.interface.print("  {s}# Safe default — recipients + encrypted envs + manifest{s}\n", .{ d, r });
    try w.interface.writeAll("  envless backup --output backup-$(date -u +%Y%m%d).tar.gz\n\n");
    try w.interface.print("  {s}# Stream to a cloud sync without a local tempfile{s}\n", .{ d, r });
    try w.interface.writeAll("  envless backup | rclone rcat gdrive:envless-backups/$(date -u +%Y%m%d).tar.gz\n\n");
    try w.interface.print("  {s}# Identity-included backup, GPG-wrapped before any storage{s}\n", .{ d, r });
    try w.interface.writeAll("  envless backup --include-identity --yes --output - \\\n");
    try w.interface.writeAll("    | gpg --symmetric --cipher-algo AES256 --output backup.tar.gz.gpg\n\n");

    try w.interface.print("{s}Exit codes:{s}\n", .{ b, r });
    try w.interface.writeAll("  0    success\n");
    try w.interface.writeAll("  1    user cancelled the --include-identity prompt\n");
    try w.interface.writeAll("  2    usage error (e.g. --include-identity without --yes in non-TTY)\n");
    try w.interface.writeAll("  64   no .envless/identity.key found in cwd or any parent\n");
    try w.interface.writeAll("  74   IO / tar / manifest error\n\n");

    try w.interface.print("{s}See also:{s}\n", .{ b, r });
    try w.interface.writeAll("  Operations → Backup & restore — https://biliboss.github.io/envless/operations/#backup--restore\n");
    try w.flush();
}
