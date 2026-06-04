//! `envless mcp` — JSON-RPC 2.0 stdio MCP server.
//!
//! Boots the JSON-RPC loop in `mcp.zig`. No flags in v1; reads NDJSON from
//! stdin and writes responses to stdout. Returns 0 on clean EOF.

const std = @import("std");
const mcp = @import("../mcp.zig");
const root = @import("root.zig");

pub fn run(ctx: *root.Context, args: []const []const u8) !u8 {
    if (args.len != 0) {
        try ctx.stderr.writer().writeAll("envless: mcp takes no arguments\n");
        return 1;
    }
    mcp.run(ctx.allocator, ctx.version) catch |err| {
        try ctx.stderr.writer().print("envless: mcp: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}
