//! `envless mcp` — JSON-RPC 2.0 stdio MCP server.
//!
//! Boots the JSON-RPC loop in `mcp.zig`. No flags in v1; reads NDJSON from
//! stdin and writes responses to stdout. Returns 0 on clean EOF.

const std = @import("std");
const mcp = @import("../mcp.zig");
const root = @import("root.zig");

pub fn run(ctx: *root.Context, args: []const []const u8) !u8 {
    if (root.wantsHelp(args)) {
        try printHelp(ctx);
        return 0;
    }
    if (args.len != 0) {
        try ctx.stderr.writer().writeAll("envless: mcp takes no arguments\n");
        try ctx.stderr.writer().writeAll("Run `envless mcp -h` for help.\n");
        return 2;
    }
    mcp.run(ctx.allocator, ctx.version) catch |err| {
        try ctx.stderr.writer().print("envless: mcp: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn printHelp(ctx: *root.Context) !void {
    const w = ctx.stdout.writer();
    const s = root.Style.fromFile(ctx.stdout);
    const b = s.bold();
    const d = s.dim();
    const r = s.reset();

    try w.print("envless mcp {s}— JSON-RPC 2.0 stdio MCP server for agents{s}\n\n", .{ d, r });

    try w.print("{s}Usage:{s}\n", .{ b, r });
    try w.writeAll("  envless mcp\n\n");

    try w.print("{s}Description:{s}\n", .{ b, r });
    try w.writeAll("  Reads newline-delimited JSON-RPC 2.0 requests from stdin and writes\n");
    try w.writeAll("  responses to stdout. Implements MCP 2024-11-05, tools-only.\n");
    try w.writeAll("  Eight tools: envs, list, get, set, exec, init, migrate, whoami.\n");
    try w.writeAll("  Stateless — each tools/call is independent. When the optional\n");
    try w.writeAll("  daemon socket is present, calls route through it for low-latency\n");
    try w.writeAll("  repeated reads.\n\n");

    try w.print("{s}Flags:{s}\n", .{ b, r });
    try w.writeAll("  -h, --help        show this help\n\n");

    try w.print("{s}Examples:{s}\n", .{ b, r });
    try w.print("  {s}# Drive the server from a shell pipe{s}\n", .{ d, r });
    try w.writeAll("  printf '%s\\n' \\\n");
    try w.writeAll("    '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"cli\",\"version\":\"1\"}}}' \\\n");
    try w.writeAll("    '{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}' \\\n");
    try w.writeAll("    | envless mcp\n\n");
    try w.print("  {s}# Wire into Claude Code / Cursor / Codex via their MCP config{s}\n", .{ d, r });
    try w.writeAll("  envless mcp\n\n");

    try w.print("{s}Exit codes:{s}\n", .{ b, r });
    try w.writeAll("  0   clean EOF\n");
    try w.writeAll("  1   stdio error\n");
    try w.writeAll("  2   usage error (mcp takes no args)\n\n");

    try w.print("{s}See also:{s}\n", .{ b, r });
    try w.writeAll("  envless daemon -h    optional decrypt-cache daemon\n");
    try w.writeAll("  Docs:                https://biliboss.github.io/envless/agents/\n");
}
