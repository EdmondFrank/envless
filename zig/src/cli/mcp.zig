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
        try ctx.errWriteAll("envless: mcp takes no arguments\n");
        try ctx.errWriteAll("Run `envless mcp -h` for help.\n");
        return 2;
    }
    mcp.run(ctx.allocator, ctx.io, ctx.version) catch |err| {
        try ctx.errPrint("envless: mcp: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn printHelp(ctx: *root.Context) !void {
    var w = ctx.stdoutWriter();
    const s = try root.Style.fromFile(ctx.io, ctx.stdout);
    const b = s.bold();
    const d = s.dim();
    const r = s.reset();

    try w.interface.print("envless mcp {s}— JSON-RPC 2.0 stdio MCP server for agents{s}\n\n", .{ d, r });

    try w.interface.print("{s}Usage:{s}\n", .{ b, r });
    try w.interface.writeAll("  envless mcp\n\n");

    try w.interface.print("{s}Description:{s}\n", .{ b, r });
    try w.interface.writeAll("  Reads newline-delimited JSON-RPC 2.0 requests from stdin and writes\n");
    try w.interface.writeAll("  responses to stdout. Implements MCP 2024-11-05, tools-only.\n");
    try w.interface.writeAll("  Eight tools: envs, list, get, set, exec, init, migrate, whoami.\n");
    try w.interface.writeAll("  Stateless — each tools/call is independent. When the optional\n");
    try w.interface.writeAll("  daemon socket is present, calls route through it for low-latency\n");
    try w.interface.writeAll("  repeated reads.\n\n");

    try w.interface.print("{s}Flags:{s}\n", .{ b, r });
    try w.interface.writeAll("  -h, --help        show this help\n\n");

    try w.interface.print("{s}Examples:{s}\n", .{ b, r });
    try w.interface.print("  {s}# Drive the server from a shell pipe{s}\n", .{ d, r });
    try w.interface.writeAll("  printf '%s\\n' \\\n");
    try w.interface.writeAll("    '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"cli\",\"version\":\"1\"}}}' \\\n");
    try w.interface.writeAll("    '{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}' \\\n");
    try w.interface.writeAll("    | envless mcp\n\n");
    try w.interface.print("  {s}# Wire into Claude Code / Cursor / Codex via their MCP config{s}\n", .{ d, r });
    try w.interface.writeAll("  envless mcp\n\n");

    try w.interface.print("{s}Exit codes:{s}\n", .{ b, r });
    try w.interface.writeAll("  0   clean EOF\n");
    try w.interface.writeAll("  1   stdio error\n");
    try w.interface.writeAll("  2   usage error (mcp takes no args)\n\n");

    try w.interface.print("{s}See also:{s}\n", .{ b, r });
    try w.interface.writeAll("  envless daemon -h    optional decrypt-cache daemon\n");
    try w.interface.writeAll("  Docs:                https://biliboss.github.io/envless/agents/\n");
    try w.flush();
}
