//! envless CLI entrypoint. Mirrors cmd/envless/main.go.

const std = @import("std");
const cli = @import("cli/root.zig");
const build_options = @import("build_options");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // toSlice returns [:0]const u8; convert to []const u8 for the CLI.
    const argv_z = try init.minimal.args.toSlice(init.arena.allocator());
    var argv = try allocator.alloc([]const u8, argv_z.len);
    defer allocator.free(argv);
    for (argv_z, 0..) |a, i| argv[i] = a[0..a.len];

    const code = cli.run(allocator, io, argv, build_options.version) catch |err| {
        var err_buf: [4096]u8 = undefined;
        var stderr_w = std.Io.File.stderr().writer(io, &err_buf);
        stderr_w.interface.print("envless: {s}\n", .{@errorName(err)}) catch {};
        std.process.exit(1);
    };
    std.process.exit(code);
}
