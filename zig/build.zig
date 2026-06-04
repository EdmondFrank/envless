const std = @import("std");

pub fn build(b: *std.Build) void {
    // Use whatever target the user passed (`-Dtarget=...`) — but if none is
    // given and we're on macOS, drop the OS version tag so Zig 0.13 stops
    // probing the host SDK for symbols it doesn't ship (a known mismatch on
    // recent macOS releases vs. Zig 0.13's bundled stubs).
    var raw_target = b.standardTargetOptions(.{});
    if (raw_target.result.os.tag == .macos and raw_target.query.os_version_min == null) {
        raw_target.query.os_version_min = .{ .none = {} };
        raw_target.query.os_version_max = .{ .none = {} };
        // Re-resolve with the cleared version constraints.
        raw_target = b.resolveTargetQuery(raw_target.query);
    }
    const target = raw_target;

    const optimize = b.standardOptimizeOption(.{});

    const version = b.option([]const u8, "version", "Version string embedded in the binary") orelse "dev";

    // ---- build options module (compile-time constants) ----
    const opts = b.addOptions();
    opts.addOption([]const u8, "version", version);

    // ---- main executable ----
    // Built only when src/main.zig exists; during the incremental port we may
    // not yet have it on disk, in which case we install nothing.
    const main_path = "src/main.zig";
    const have_main = blk: {
        std.fs.cwd().access(b.pathFromRoot(main_path), .{}) catch break :blk false;
        break :blk true;
    };
    if (have_main) {
        const exe = b.addExecutable(.{
            .name = "envless",
            .root_source_file = b.path(main_path),
            .target = target,
            .optimize = optimize,
        });
        exe.linkLibC();
        exe.root_module.addOptions("build_options", opts);
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_cmd.addArgs(args);
        const run_step = b.step("run", "Run the envless binary");
        run_step.dependOn(&run_cmd.step);
    }

    // ---- unit tests ----
    const test_step = b.step("test", "Run unit tests");

    const all_test_files = [_][]const u8{
        "src/envparse.zig",
        "src/execenv.zig",
        "src/sops.zig",
        "src/store.zig",
        "src/backup.zig",
        "src/cli/root.zig",
        "src/cli/migrate.zig",
        "src/ipc.zig",
        "src/mcp.zig",
        "src/daemon.zig",
        "src/launchd.zig",
        "src/systemd.zig",
    };
    var test_files: [all_test_files.len][]const u8 = undefined;
    var n_tests: usize = 0;
    for (all_test_files) |path| {
        std.fs.cwd().access(b.pathFromRoot(path), .{}) catch continue;
        test_files[n_tests] = path;
        n_tests += 1;
    }
    for (test_files[0..n_tests]) |path| {
        const t = b.addTest(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        t.linkLibC();
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
    }

    // ---- e2e tests ----
    // The e2e suite shells out to the installed envless binary. It depends
    // on `b.getInstallStep()` so `zig build e2e` always builds the binary
    // first and points the harness at zig-out/bin/envless via the BIN env
    // var (absolute path; the test runner's cwd is the zig-cache, not the
    // project root, so a relative fallback wouldn't resolve).
    if (have_main) {
        const e2e_step = b.step("e2e", "Run end-to-end tests against the built binary");
        const e2e_t = b.addTest(.{
            .root_source_file = b.path("src/e2e.zig"),
            .target = target,
            .optimize = optimize,
        });
        e2e_t.linkLibC();
        const run_e2e = b.addRunArtifact(e2e_t);
        run_e2e.step.dependOn(b.getInstallStep());
        // Compute an absolute path to zig-out/bin/envless via the install
        // prefix so the harness can spawn it regardless of cwd.
        const bin_path = b.getInstallPath(.bin, "envless");
        run_e2e.setEnvironmentVariable("BIN", bin_path);
        e2e_step.dependOn(&run_e2e.step);
    }

    // ---- release: cross-compiled tarballs + sha256 checksums ----
    // Produces ../dist/envless_<version>_<target>.tar.gz for each release
    // target, then writes ../dist/checksums.txt with one `<sha256>  <file>`
    // line per tarball. The build runner's cwd is the dir containing
    // build.zig (i.e. zig/), so ../dist lands at the repo root.
    //
    // Replaces the Go .goreleaser.yaml pipeline. Triggered with:
    //   zig build release -Dversion=vX.Y.Z
    const release_step = b.step("release", "Cross-build release tarballs into ../dist/");

    const RelTarget = struct {
        triple: []const u8,
        query: std.Target.Query,
    };
    const rel_targets = [_]RelTarget{
        .{ .triple = "x86_64-linux-gnu", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu } },
        .{ .triple = "aarch64-linux-gnu", .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu } },
        .{ .triple = "x86_64-macos", .query = .{ .cpu_arch = .x86_64, .os_tag = .macos } },
        .{ .triple = "aarch64-macos", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
    };

    // Ensure the dist dir exists. addSystemCommand runs once per build, but
    // mkdir -p is idempotent, so we just attach it as a prereq for every
    // tar invocation.
    const mkdir_dist = b.addSystemCommand(&.{ "mkdir", "-p", "../dist" });

    // Collect tarball basenames (used by the final checksums step).
    var tar_names = std.ArrayList([]const u8).init(b.allocator);
    // Each tar step is a dependency of the final checksum step so we know
    // every tarball exists by the time we shasum.
    var tar_steps = std.ArrayList(*std.Build.Step).init(b.allocator);

    for (rel_targets) |rt| {
        const rel_target = b.resolveTargetQuery(rt.query);

        const rel_exe = b.addExecutable(.{
            .name = "envless",
            .root_source_file = b.path(main_path),
            .target = rel_target,
            .optimize = .ReleaseSmall,
        });
        rel_exe.linkLibC();
        rel_exe.root_module.addOptions("build_options", opts);

        // Stage the binary into a per-target dir
        // `envless_<version>_<triple>/envless` via WriteFiles. The
        // staging dir's LazyPath is then handed to `tar -C <parent>
        // <stage-dir-name>` so the tarball entries are
        // envless_<version>_<triple>/envless (not absolute paths).
        const stage_dir_name = b.fmt("envless_{s}_{s}", .{ version, rt.triple });
        const stage = b.addWriteFiles();
        _ = stage.addCopyFile(rel_exe.getEmittedBin(), b.fmt("{s}/envless", .{stage_dir_name}));

        const tar_name = b.fmt("{s}.tar.gz", .{stage_dir_name});
        const tar_out_rel = b.fmt("../dist/{s}", .{tar_name});

        // tar --format=ustar -czf ../dist/<name>.tar.gz -C <staging> <dir>
        const tar_cmd = b.addSystemCommand(&.{ "tar", "--format=ustar", "-czf" });
        tar_cmd.addArg(tar_out_rel);
        tar_cmd.addArg("-C");
        tar_cmd.addDirectoryArg(stage.getDirectory());
        tar_cmd.addArg(stage_dir_name);
        tar_cmd.step.dependOn(&mkdir_dist.step);
        release_step.dependOn(&tar_cmd.step);

        tar_names.append(tar_name) catch @panic("OOM");
        tar_steps.append(&tar_cmd.step) catch @panic("OOM");
    }

    // Write ../dist/checksums.txt with `<sha256>  <basename>` lines. We use
    // a single `sh -c` invocation because we need: (1) to read the tarballs
    // back from the dist/ dir after tar has written them, (2) to format
    // each line consistently across macOS (shasum) and Linux (sha256sum or
    // shasum — both ship shasum via Perl).
    const checksum_cmd = b.addSystemCommand(&.{ "sh", "-c" });
    // Compose: cd ../dist && for each name, append "<hex>  <name>" to
    // checksums.txt. Truncate first to make the step idempotent.
    var script = std.ArrayList(u8).init(b.allocator);
    script.appendSlice("cd ../dist && : > checksums.txt && ") catch @panic("OOM");
    for (tar_names.items, 0..) |name, i| {
        if (i != 0) script.appendSlice(" && ") catch @panic("OOM");
        // Prefer sha256sum (Linux coreutils); fall back to shasum (macOS / Perl).
        script.writer().print("{{ sha256sum '{s}' 2>/dev/null || shasum -a 256 '{s}'; }} | awk '{{print $1\"  \"\"{s}\"}}' >> checksums.txt", .{ name, name, name }) catch @panic("OOM");
    }
    checksum_cmd.addArg(script.items);
    for (tar_steps.items) |s| checksum_cmd.step.dependOn(s);
    release_step.dependOn(&checksum_cmd.step);
}
