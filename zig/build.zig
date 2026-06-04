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
        "src/cli/root.zig",
        "src/cli/migrate.zig",
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

}
