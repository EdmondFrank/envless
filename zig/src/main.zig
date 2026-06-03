//! envless CLI entrypoint. Mirrors cmd/envless/main.go.

const std = @import("std");
const cli = @import("cli/root.zig");
const build_options = @import("build_options");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const code = cli.run(allocator, argv, build_options.version) catch |err| {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("envless: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.process.exit(code);
}
