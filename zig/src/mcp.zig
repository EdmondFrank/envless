//! mcp: Model Context Protocol server (`envless mcp`).
//!
//! JSON-RPC 2.0 over stdio, NDJSON framing (one request per line, no LSP-
//! style `Content-Length:` headers). Implements MCP 2024-11-05 with the
//! tools-only capability surface — 8 tools:
//!
//!   envs     list available env names
//!   list     keys of one env (no values)
//!   get      decrypt one key — requires confirm=true
//!   set      encrypt-set one key
//!   exec     run a child with secrets injected; 300s hard timeout
//!   init     run init flow at path (default cwd)
//!   migrate  encrypt a plaintext .env into envless
//!   whoami   return identity pubkey + recipient count
//!
//! Tools return MCP-shaped results — `{content:[{type:"text",text:"..."}],
//! isError?:bool}`. Tool-level errors set isError=true; JSON-RPC errors
//! (-32700 parse, -32600 invalid request, -32601 method not found,
//! -32602 invalid params, -32603 internal) are reserved for protocol
//! issues, not tool failures.
//!
//! v1 is stateless — every tools/call spawns sops fresh through the
//! existing Store/sops wrappers. When the daemon socket exists and answers
//! PING within 100ms, calls route through the socket instead. Detect-and-
//! route is the only daemon-aware path; CLI subcommands remain stateless.

const std = @import("std");
const json = std.json;

const store = @import("store.zig");
const sops = @import("sops.zig");
const execenv = @import("execenv.zig");
const envparse = @import("envparse.zig");
const ipc = @import("ipc.zig");

pub const PROTOCOL_VERSION = "2024-11-05";
pub const SERVER_NAME = "envless";

// Hard exec timeout. The spec says "300s, configurable later" — we honor
// that and ignore caller-supplied timeouts on `exec` for v1. When the
// child does not exit within the window, we send SIGTERM and report
// {exit_code: -1, stderr: "timeout"}.
const EXEC_TIMEOUT_MS: u64 = 300_000;

const READ_BUF = 256 * 1024;

/// run: stdio loop. Reads one JSON-RPC line per iteration, dispatches, and
/// writes the response (when applicable). Returns on EOF.
pub fn run(allocator: std.mem.Allocator, io: std.Io, version: []const u8) !void {
    var stdin_read_buf: [8192]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_read_buf);
    var stdout_write_buf: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_write_buf);

    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(allocator);

    while (true) {
        line_buf.clearRetainingCapacity();
        const line_bytes = stdin_reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return,
            error.StreamTooLong => {
                std.debug.print("[mcp] line exceeds {d}B — closing\n", .{READ_BUF});
                return;
            },
            else => return err,
        };
        try line_buf.appendSlice(allocator, line_bytes);
        const line = std.mem.trim(u8, line_buf.items, " \t\r");
        if (line.len == 0) continue;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const response = handleLine(arena.allocator(), io, version, line) catch |e| blk: {
            std.debug.print("[mcp] handle error: {s}\n", .{@errorName(e)});
            break :blk null;
        };
        if (response) |resp| {
            try stdout_writer.interface.writeAll(resp);
            try stdout_writer.interface.writeAll("\n");
            try stdout_writer.flush();
        }
    }
}

/// handleLine: parse one JSON-RPC envelope and dispatch. Returns the
/// response string (caller owns via arena) or null for notifications.
pub fn handleLine(a: std.mem.Allocator, io: std.Io, version: []const u8, line: []const u8) !?[]const u8 {
    var parsed = json.parseFromSlice(json.Value, a, line, .{}) catch {
        return try errorResponse(a, .{ .null = {} }, -32700, "Parse error");
    };
    // We keep `parsed` alive through the arena `a` — `parsed.deinit()` is
    // wrapped by the arena's reset. Storing the Parsed handle in a local
    // and not deiniting here means the ArenaAllocator owns the memory.
    _ = &parsed;

    const root = parsed.value;
    if (root != .object) return try errorResponse(a, .{ .null = {} }, -32600, "Invalid Request");
    const req = root.object;

    const method_val = req.get("method") orelse {
        return try errorResponse(a, .{ .null = {} }, -32600, "Invalid Request");
    };
    if (method_val != .string) {
        return try errorResponse(a, .{ .null = {} }, -32600, "Invalid Request");
    }
    const method = method_val.string;

    const id_val: json.Value = req.get("id") orelse .{ .null = {} };
    const is_notification = !req.contains("id");
    const params: json.Value = req.get("params") orelse .{ .null = {} };

    if (std.mem.eql(u8, method, "initialize")) {
        return try buildInitializeResponse(a, id_val, version);
    }
    if (std.mem.eql(u8, method, "notifications/initialized")) {
        return null;
    }
    if (std.mem.eql(u8, method, "tools/list")) {
        return try buildToolsListResponse(a, id_val);
    }
    if (std.mem.eql(u8, method, "tools/call")) {
        return try buildToolsCallResponse(a, io, id_val, params);
    }
    if (std.mem.eql(u8, method, "ping")) {
        return try okResponse(a, id_val, .{ .object = json.ObjectMap.empty });
    }

    if (is_notification) return null;
    return try errorResponse(a, id_val, -32601, "Method not found");
}

// ---- JSON-builder helpers ---------------------------------------------------

fn obj(a: std.mem.Allocator, pairs: []const struct { []const u8, json.Value }) !json.Value {
    var m = json.ObjectMap.empty;
    for (pairs) |p| try m.put(a, p[0], p[1]);
    return .{ .object = m };
}

fn arr(a: std.mem.Allocator, items: []const json.Value) !json.Value {
    var list = json.Array.init(a);
    try list.appendSlice(items);
    return .{ .array = list };
}

/// Replacement for std.json.stringifyAlloc (removed in 0.16).
fn jsonStrAlloc(a: std.mem.Allocator, value: json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    var stringify: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try stringify.write(value);
    return try out.toOwnedSlice();
}

fn str(s: []const u8) json.Value {
    return .{ .string = s };
}
fn int(n: i64) json.Value {
    return .{ .integer = n };
}
fn boolean(b: bool) json.Value {
    return .{ .bool = b };
}

// ---- envelopes --------------------------------------------------------------

fn okResponse(a: std.mem.Allocator, id: json.Value, result: json.Value) ![]const u8 {
    const env = try obj(a, &.{
        .{ "jsonrpc", str("2.0") },
        .{ "id", id },
        .{ "result", result },
    });
    return try jsonStrAlloc(a, env);
}

fn errorResponse(a: std.mem.Allocator, id: json.Value, code: i64, message: []const u8) ![]const u8 {
    const err_obj = try obj(a, &.{
        .{ "code", int(code) },
        .{ "message", str(message) },
    });
    const env = try obj(a, &.{
        .{ "jsonrpc", str("2.0") },
        .{ "id", id },
        .{ "error", err_obj },
    });
    return try jsonStrAlloc(a, env);
}

fn toolTextResponse(a: std.mem.Allocator, id: json.Value, text: []const u8) ![]const u8 {
    const block = try obj(a, &.{
        .{ "type", str("text") },
        .{ "text", str(text) },
    });
    const content = try arr(a, &.{block});
    const result = try obj(a, &.{
        .{ "content", content },
        .{ "isError", boolean(false) },
    });
    return try okResponse(a, id, result);
}

fn toolErrorResponse(a: std.mem.Allocator, id: json.Value, text: []const u8) ![]const u8 {
    const block = try obj(a, &.{
        .{ "type", str("text") },
        .{ "text", str(text) },
    });
    const content = try arr(a, &.{block});
    const result = try obj(a, &.{
        .{ "content", content },
        .{ "isError", boolean(true) },
    });
    return try okResponse(a, id, result);
}

// ---- initialize / tools/list ------------------------------------------------

fn buildInitializeResponse(a: std.mem.Allocator, id: json.Value, version: []const u8) ![]const u8 {
    const server_info = try obj(a, &.{
        .{ "name", str(SERVER_NAME) },
        .{ "version", str(version) },
    });
    const tools_cap = try obj(a, &.{
        .{ "listChanged", boolean(false) },
    });
    const caps = try obj(a, &.{
        .{ "tools", tools_cap },
    });
    const result = try obj(a, &.{
        .{ "protocolVersion", str(PROTOCOL_VERSION) },
        .{ "capabilities", caps },
        .{ "serverInfo", server_info },
    });
    return try okResponse(a, id, result);
}

fn toolDescriptor(a: std.mem.Allocator, name: []const u8, desc: []const u8, schema: json.Value) !json.Value {
    return try obj(a, &.{
        .{ "name", str(name) },
        .{ "description", str(desc) },
        .{ "inputSchema", schema },
    });
}

fn objectSchema(a: std.mem.Allocator, props: json.Value, required: ?json.Value) !json.Value {
    if (required) |r| {
        return try obj(a, &.{
            .{ "type", str("object") },
            .{ "properties", props },
            .{ "required", r },
        });
    }
    return try obj(a, &.{
        .{ "type", str("object") },
        .{ "properties", props },
    });
}

fn buildToolsListResponse(a: std.mem.Allocator, id: json.Value) ![]const u8 {
    const env_str_prop = try obj(a, &.{
        .{ "type", str("string") },
        .{ "description", str("Environment name (e.g. 'dev', 'prod'). Maps to secrets/<env>.env.enc.") },
    });
    const key_str_prop = try obj(a, &.{
        .{ "type", str("string") },
        .{ "description", str("Secret key (UPPER_SNAKE_CASE conventional).") },
    });
    const value_str_prop = try obj(a, &.{
        .{ "type", str("string") },
        .{ "description", str("Secret value. Stored verbatim.") },
    });

    // envs: {}
    const envs_schema = try objectSchema(a, try obj(a, &.{}), null);

    // list: {env}
    const list_props = try obj(a, &.{ .{ "env", env_str_prop } });
    const list_schema = try objectSchema(a, list_props, try arr(a, &.{str("env")}));

    // get: {env, key, confirm:true}
    const confirm_prop = try obj(a, &.{
        .{ "type", str("boolean") },
        .{ "description", str("Must be exactly true. Guards against accidental decrypt-and-return of a secret.") },
    });
    const pass_prop = try obj(a, &.{
        .{ "type", str("string") },
        .{ "description", str("Pass token. Required when ENVLESS_PASS_TOKEN is set in the env's secrets.") },
    });
    const get_props = try obj(a, &.{
        .{ "env", env_str_prop },
        .{ "key", key_str_prop },
        .{ "confirm", confirm_prop },
        .{ "pass", pass_prop },
    });
    const get_schema = try objectSchema(a, get_props, try arr(a, &.{ str("env"), str("key"), str("confirm") }));

    // set: {env, key, value}
    const set_props = try obj(a, &.{
        .{ "env", env_str_prop },
        .{ "key", key_str_prop },
        .{ "value", value_str_prop },
    });
    const set_schema = try objectSchema(a, set_props, try arr(a, &.{ str("env"), str("key"), str("value") }));

    // exec: {env, argv, stdin?, cwd?}
    const argv_prop = try obj(a, &.{
        .{ "type", str("array") },
        .{ "items", try obj(a, &.{.{ "type", str("string") }}) },
        .{ "description", str("Child command and arguments. argv[0] resolved through PATH.") },
    });
    const stdin_prop = try obj(a, &.{
        .{ "type", str("string") },
        .{ "description", str("Optional stdin text fed to the child.") },
    });
    const cwd_prop = try obj(a, &.{
        .{ "type", str("string") },
        .{ "description", str("Optional working directory (absolute). Defaults to MCP server's cwd.") },
    });
    const exec_props = try obj(a, &.{
        .{ "env", env_str_prop },
        .{ "argv", argv_prop },
        .{ "stdin", stdin_prop },
        .{ "cwd", cwd_prop },
    });
    const exec_schema = try objectSchema(a, exec_props, try arr(a, &.{ str("env"), str("argv") }));

    // init: {path?}
    const path_prop = try obj(a, &.{
        .{ "type", str("string") },
        .{ "description", str("Repo root to initialize. Defaults to MCP server's cwd.") },
    });
    const init_props = try obj(a, &.{ .{ "path", path_prop } });
    const init_schema = try objectSchema(a, init_props, null);

    // migrate: {file, env, keep?}
    const file_prop = try obj(a, &.{
        .{ "type", str("string") },
        .{ "description", str("Path to a plaintext .env file to migrate.") },
    });
    const keep_prop = try obj(a, &.{
        .{ "type", str("boolean") },
        .{ "description", str("If true, do not delete the plaintext file after migration.") },
    });
    const migrate_props = try obj(a, &.{
        .{ "file", file_prop },
        .{ "env", env_str_prop },
        .{ "keep", keep_prop },
    });
    const migrate_schema = try objectSchema(a, migrate_props, try arr(a, &.{ str("file"), str("env") }));

    // whoami: {}
    const whoami_schema = try objectSchema(a, try obj(a, &.{}), null);

    const tools = try arr(a, &.{
        try toolDescriptor(a, "envs", "List available envs (scans secrets/*.env.enc).", envs_schema),
        try toolDescriptor(a, "list", "List keys (no values) for an env.", list_schema),
        try toolDescriptor(a, "get", "Decrypt and return ONE secret value. confirm MUST be true. If ENVLESS_PASS_TOKEN is set in the env, pass must match it.", get_schema),
        try toolDescriptor(a, "set", "Encrypt-set one key in an env.", set_schema),
        try toolDescriptor(a, "exec", "Run a child process with the env's secrets injected. 300s hard timeout.", exec_schema),
        try toolDescriptor(a, "init", "Initialize .envless/ in the target path (creates identity.key + recipients).", init_schema),
        try toolDescriptor(a, "migrate", "Encrypt a plaintext .env file into envless and gitignore it.", migrate_schema),
        try toolDescriptor(a, "whoami", "Return the local identity pubkey and recipient count.", whoami_schema),
    });
    const result = try obj(a, &.{ .{ "tools", tools } });
    return try okResponse(a, id, result);
}

// ---- tools/call dispatch ----------------------------------------------------

fn buildToolsCallResponse(a: std.mem.Allocator, io: std.Io, id: json.Value, params: json.Value) ![]const u8 {
    if (params != .object) return try errorResponse(a, id, -32602, "params must be an object");
    const p = params.object;

    const name_val = p.get("name") orelse return try errorResponse(a, id, -32602, "params.name missing");
    if (name_val != .string) return try errorResponse(a, id, -32602, "params.name must be a string");
    const tool = name_val.string;

    const empty = json.Value{ .object = json.ObjectMap.empty };
    const args = p.get("arguments") orelse empty;

    if (std.mem.eql(u8, tool, "envs")) return callEnvs(a, io, id, args);
    if (std.mem.eql(u8, tool, "list")) return callList(a, io, id, args);
    if (std.mem.eql(u8, tool, "get")) return callGet(a, io, id, args);
    if (std.mem.eql(u8, tool, "set")) return callSet(a, io, id, args);
    if (std.mem.eql(u8, tool, "exec")) return callExec(a, io, id, args);
    if (std.mem.eql(u8, tool, "init")) return callInit(a, io, id, args);
    if (std.mem.eql(u8, tool, "migrate")) return callMigrate(a, io, id, args);
    if (std.mem.eql(u8, tool, "whoami")) return callWhoami(a, io, id, args);

    return try toolErrorResponse(a, id, "unknown tool");
}

fn getCwd(a: std.mem.Allocator, io: std.Io) ![]u8 {
    var buf: [4096]u8 = undefined;
    const len = try std.process.currentPath(io, &buf);
    return a.dupe(u8, buf[0..len]);
}

// Detect a running daemon socket. Returns the path (owned by `a`) when a
// socket exists and answers PING within ~100ms. Returns null otherwise.
// Note: v1 only the MCP path uses this — CLI stays stateless per spec.
fn daemonSocketIfAlive(a: std.mem.Allocator, io: std.Io) ?[]u8 {
    const home_ptr = std.c.getenv("HOME") orelse return null;
    const home = std.mem.span(home_ptr);
    const path = ipc.socketPath(a, io, home) catch return null;
    // Check existence first.
    std.Io.Dir.cwd().access(io, path, .{}) catch {
        a.free(path);
        return null;
    };
    // Try a fast PING. If the daemon doesn't answer cleanly, treat the
    // socket as orphaned and fall back to the stateless in-process path.
    if (probeSocket(io, path)) {
        return path;
    }
    a.free(path);
    return null;
}

fn probeSocket(io: std.Io, path: []const u8) bool {
    var addr = std.Io.net.UnixAddress.init(path) catch return false;
    var stream = addr.connect(io) catch return false;
    defer stream.close(io);
    streamWriteAll(io, stream, "PING\n") catch return false;
    var buf: [64]u8 = undefined;
    var r_buf: [64]u8 = undefined;
    var sr = stream.reader(io, &r_buf);
    const n = sr.interface.readSliceShort(&buf) catch return false;
    if (n < 3) return false;
    return std.mem.startsWith(u8, buf[0..n], "OK\t");
}

// ---- envs -------------------------------------------------------------------

fn callEnvs(a: std.mem.Allocator, io: std.Io, id: json.Value, args: json.Value) ![]const u8 {
    _ = args;
    const cwd = try getCwd(a, io);
    defer a.free(cwd);

    const secrets_dir = try std.fs.path.join(a, &.{ cwd, "secrets" });
    defer a.free(secrets_dir);

    var dir = std.Io.Dir.cwd().openDir(io, secrets_dir, .{ .iterate = true }) catch {
        // No secrets/ — return an empty array. This is not an error: a
        // brand-new repo simply hasn't set anything yet.
        const payload = try obj(a, &.{
            .{ "envs", try arr(a, &.{}) },
        });
        const text = try jsonStrAlloc(a, payload);
        return toolTextResponse(a, id, text);
    };
    defer dir.close(io);

    var list = json.Array.init(a);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".env.enc")) continue;
        const name = entry.name[0 .. entry.name.len - ".env.enc".len];
        try list.append(str(try a.dupe(u8, name)));
    }
    const payload = try obj(a, &.{ .{ "envs", json.Value{ .array = list } } });
    const text = try jsonStrAlloc(a, payload);
    return toolTextResponse(a, id, text);
}

// ---- list -------------------------------------------------------------------

fn callList(a: std.mem.Allocator, io: std.Io, id: json.Value, args: json.Value) ![]const u8 {
    if (args != .object) return try toolErrorResponse(a, id, "arguments must be an object");
    const env_val = args.object.get("env") orelse return try toolErrorResponse(a, id, "env is required");
    if (env_val != .string) return try toolErrorResponse(a, id, "env must be a string");

    const cwd = try getCwd(a, io);
    defer a.free(cwd);

    // Daemon routing.
    if (daemonSocketIfAlive(a, io)) |sock| {
        defer a.free(sock);
        if (sendDaemonList(a, io, sock, env_val.string)) |keys_payload| {
            return toolTextResponse(a, id, keys_payload);
        } else |_| {
            // fall through to in-process
        }
    }

    const s = store.Store.init(a, io, cwd);
    var r = s.keys(env_val.string) catch |err| {
        const msg = try std.fmt.allocPrint(a, "list failed: {s}", .{@errorName(err)});
        return toolErrorResponse(a, id, msg);
    };
    defer r.deinit();
    var list = json.Array.init(a);
    for (r.keys) |k| try list.append(str(try a.dupe(u8, k)));
    const payload = try obj(a, &.{ .{ "keys", json.Value{ .array = list } } });
    const text = try jsonStrAlloc(a, payload);
    return toolTextResponse(a, id, text);
}

fn sendDaemonList(a: std.mem.Allocator, io: std.Io, sock: []const u8, env: []const u8) ![]const u8 {
    var stream = try (try std.Io.net.UnixAddress.init(sock)).connect(io);
    defer stream.close(io);
    const req = try std.fmt.allocPrint(a, "LIST\t{s}\n", .{env});
    defer a.free(req);
    try streamWriteAll(io, stream, req);
    return try readDaemonOkPayload(a, io, &stream);
}

/// Write all bytes to a stream via a stack buffer.
fn streamWriteAll(io: std.Io, stream: std.Io.net.Stream, data: []const u8) !void {
    var w_buf: [4096]u8 = undefined;
    var w = stream.writer(io, &w_buf);
    try w.interface.writeAll(data);
}

fn readDaemonOkPayload(a: std.mem.Allocator, io: std.Io, stream: *std.Io.net.Stream) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    // Read up to 1 MiB or newline.
    var b: [4096]u8 = undefined;
    var r_buf: [4096]u8 = undefined;
    var sr = stream.reader(io, &r_buf);
    while (true) {
        const n = try sr.interface.readSliceShort(&b);
        if (n == 0) break;
        try buf.appendSlice(a, b[0..n]);
        if (std.mem.indexOfScalar(u8, buf.items, '\n')) |_| break;
        if (buf.items.len > 1024 * 1024) return error.ResponseTooLarge;
    }
    const line = std.mem.trimEnd(u8, buf.items, " \t\r\n");
    if (std.mem.startsWith(u8, line, "OK\t")) {
        return try a.dupe(u8, line[3..]);
    }
    if (std.mem.startsWith(u8, line, "ERR\t")) return error.DaemonError;
    return error.DaemonUnexpected;
}

// ---- get --------------------------------------------------------------------

fn callGet(a: std.mem.Allocator, io: std.Io, id: json.Value, args: json.Value) ![]const u8 {
    if (args != .object) return try toolErrorResponse(a, id, "arguments must be an object");
    const env_val = args.object.get("env") orelse return try toolErrorResponse(a, id, "env is required");
    if (env_val != .string) return try toolErrorResponse(a, id, "env must be a string");
    const key_val = args.object.get("key") orelse return try toolErrorResponse(a, id, "key is required");
    if (key_val != .string) return try toolErrorResponse(a, id, "key must be a string");

    // Confirm must be the JSON boolean `true` or the string "true". Anything
    // else (false, null, missing, "yes", 1) gets refused.
    const confirm_val = args.object.get("confirm") orelse return try toolErrorResponse(a, id, "confirm is required (must be exactly true)");
    const confirmed = switch (confirm_val) {
        .bool => |b| b,
        .string => |s| std.mem.eql(u8, s, "true"),
        else => false,
    };
    if (!confirmed) return try toolErrorResponse(a, id, "confirm must be exactly true to return a secret");

    // Optional pass token. Required when ENVLESS_PASS_TOKEN is set.
    const pass_val: ?[]const u8 = blk: {
        const v = args.object.get("pass") orelse break :blk null;
        if (v != .string) break :blk null;
        break :blk v.string;
    };

    const cwd = try getCwd(a, io);
    defer a.free(cwd);

    // Use the store directly (not the daemon) so we have the full decrypted
    // map available for the ENVLESS_PASS_TOKEN check. `get` is a rare,
    // deliberate operation; the daemon cache optimization is not critical here.
    const s = store.Store.init(a, io, cwd);
    var r = s.get(env_val.string, key_val.string) catch |err| {
        const msg = try std.fmt.allocPrint(a, "get failed: {s}", .{@errorName(err)});
        return toolErrorResponse(a, id, msg);
    };
    defer r.deinit();
    if (!r.found) {
        const msg = try std.fmt.allocPrint(a, "key \"{s}\" not found in env \"{s}\"", .{ key_val.string, env_val.string });
        return toolErrorResponse(a, id, msg);
    }

    // Safety gate: if ENVLESS_PASS_TOKEN is set in this env's secrets,
    // the caller must provide a matching pass token.
    if (r.map.inner.get("ENVLESS_PASS_TOKEN")) |pass_token| {
        if (pass_val) |provided| {
            if (!std.mem.eql(u8, provided, pass_token)) {
                return toolErrorResponse(a, id, "pass token mismatch");
            }
        } else {
            return toolErrorResponse(a, id, "this env requires a pass token (ENVLESS_PASS_TOKEN is set); provide pass in arguments");
        }
    }

    const payload = try obj(a, &.{ .{ "value", str(try a.dupe(u8, r.value)) } });
    const text = try jsonStrAlloc(a, payload);
    return toolTextResponse(a, id, text);
}

fn sendDaemonGet(a: std.mem.Allocator, io: std.Io, sock: []const u8, env: []const u8, key: []const u8) ![]const u8 {
    var stream = try (try std.Io.net.UnixAddress.init(sock)).connect(io);
    defer stream.close(io);
    const req = try std.fmt.allocPrint(a, "GET\t{s}\t{s}\n", .{ env, key });
    defer a.free(req);
    try streamWriteAll(io, stream, req);
    // Payload is a JSON object {"value":"..."}. We pass it through unchanged.
    const blob = try readDaemonOkPayload(a, io, &stream);
    var parsed = try json.parseFromSlice(json.Value, a, blob, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.DaemonUnexpected;
    const v = parsed.value.object.get("value") orelse return error.DaemonUnexpected;
    if (v != .string) return error.DaemonUnexpected;
    return try a.dupe(u8, v.string);
}

// ---- set --------------------------------------------------------------------

fn callSet(a: std.mem.Allocator, io: std.Io, id: json.Value, args: json.Value) ![]const u8 {
    if (args != .object) return try toolErrorResponse(a, id, "arguments must be an object");
    const env_val = args.object.get("env") orelse return try toolErrorResponse(a, id, "env is required");
    if (env_val != .string) return try toolErrorResponse(a, id, "env must be a string");
    const key_val = args.object.get("key") orelse return try toolErrorResponse(a, id, "key is required");
    if (key_val != .string) return try toolErrorResponse(a, id, "key must be a string");
    const value_val = args.object.get("value") orelse return try toolErrorResponse(a, id, "value is required");
    if (value_val != .string) return try toolErrorResponse(a, id, "value must be a string");

    const cwd = try getCwd(a, io);
    defer a.free(cwd);

    if (daemonSocketIfAlive(a, io)) |sock| {
        defer a.free(sock);
        if (sendDaemonSet(a, io, sock, env_val.string, key_val.string, value_val.string)) {
            const payload = try obj(a, &.{ .{ "ok", boolean(true) } });
            const text = try jsonStrAlloc(a, payload);
            return toolTextResponse(a, id, text);
        } else |_| {}
    }

    const s = store.Store.init(a, io, cwd);
    s.set(env_val.string, key_val.string, value_val.string) catch |err| {
        const msg = try std.fmt.allocPrint(a, "set failed: {s}", .{@errorName(err)});
        return toolErrorResponse(a, id, msg);
    };
    const payload = try obj(a, &.{ .{ "ok", boolean(true) } });
    const text = try jsonStrAlloc(a, payload);
    return toolTextResponse(a, id, text);
}

fn sendDaemonSet(a: std.mem.Allocator, io: std.Io, sock: []const u8, env: []const u8, key: []const u8, value: []const u8) !void {
    var stream = try (try std.Io.net.UnixAddress.init(sock)).connect(io);
    defer stream.close(io);
    const req = try std.fmt.allocPrint(a, "SET\t{s}\t{s}\t{s}\n", .{ env, key, value });
    defer a.free(req);
    try streamWriteAll(io, stream, req);
    _ = try readDaemonOkPayload(a, io, &stream);
}

// ---- exec -------------------------------------------------------------------

fn callExec(a: std.mem.Allocator, io: std.Io, id: json.Value, args: json.Value) ![]const u8 {
    if (args != .object) return try toolErrorResponse(a, id, "arguments must be an object");
    const env_val = args.object.get("env") orelse return try toolErrorResponse(a, id, "env is required");
    if (env_val != .string) return try toolErrorResponse(a, id, "env must be a string");
    const argv_val = args.object.get("argv") orelse return try toolErrorResponse(a, id, "argv is required");
    if (argv_val != .array) return try toolErrorResponse(a, id, "argv must be an array of strings");

    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(a);
    for (argv_val.array.items) |item| {
        if (item != .string) return try toolErrorResponse(a, id, "argv items must be strings");
        try argv_list.append(a, item.string);
    }
    if (argv_list.items.len == 0) return try toolErrorResponse(a, id, "argv must not be empty");

    var stdin_text: []const u8 = "";
    if (args.object.get("stdin")) |s| {
        if (s != .string) return try toolErrorResponse(a, id, "stdin must be a string");
        stdin_text = s.string;
    }

    const cwd_owned = try getCwd(a, io);
    defer a.free(cwd_owned);
    var cwd_for_child: []const u8 = cwd_owned;
    if (args.object.get("cwd")) |c| {
        if (c != .string) return try toolErrorResponse(a, id, "cwd must be a string");
        cwd_for_child = c.string;
    }

    // Read decrypted KV from the store rooted at cwd_owned (the MCP cwd).
    const s = store.Store.init(a, io, cwd_owned);
    var kv = s.read(env_val.string) catch |err| {
        const msg = try std.fmt.allocPrint(a, "decrypt failed: {s}", .{@errorName(err)});
        return toolErrorResponse(a, id, msg);
    };
    defer kv.deinit();

    // Build the child env: parent + secrets (secrets win).
    var parent_entries: std.ArrayList([]u8) = .empty;
    defer {
        for (parent_entries.items) |p| a.free(p);
        parent_entries.deinit(a);
    }
    {
        var i: usize = 0;
        while (std.c.environ[i]) |entry_ptr| : (i += 1) {
            const e = std.mem.span(entry_ptr);
            const buf = try a.dupe(u8, e);
            try parent_entries.append(a, buf);
        }
    }
    var parent_view = try a.alloc([]const u8, parent_entries.items.len);
    defer a.free(parent_view);
    for (parent_entries.items, 0..) |p, i| parent_view[i] = p;

    const child_env = try execenv.buildEnv(a, parent_view, kv.inner);
    defer execenv.freeEnv(a, child_env);

    // Run with synchronous spawn-and-wait; stdout/stderr captured.
    return try runExecWithTimeout(a, io, id, argv_list.items, child_env, stdin_text, cwd_for_child);
}

fn runExecWithTimeout(
    a: std.mem.Allocator,
    io: std.Io,
    id: json.Value,
    argv: []const []const u8,
    env: []const []const u8,
    stdin_text: []const u8,
    cwd: []const u8,
) ![]const u8 {
    var env_map = std.process.Environ.Map.init(a);
    defer env_map.deinit();
    for (env) |e| {
        const eq = std.mem.indexOfScalar(u8, e, '=') orelse continue;
        try env_map.put(e[0..eq], e[eq + 1 ..]);
    }

    var child = std.process.spawn(io, .{
        .argv = argv,
        .environ_map = &env_map,
        .cwd = .{ .path = cwd },
        .stdin = if (stdin_text.len > 0) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| {
        const msg = try std.fmt.allocPrint(a, "spawn failed: {s}", .{@errorName(err)});
        return toolErrorResponse(a, id, msg);
    };

    if (stdin_text.len > 0) {
        if (child.stdin) |stdin_file| {
            var w_buf: [4096]u8 = undefined;
            var sw = stdin_file.writer(io, &w_buf);
            sw.interface.writeAll(stdin_text) catch {};
            sw.flush() catch {};
            stdin_file.close(io);
            child.stdin = null;
        }
    }

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(a);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(a);

    if (child.stdout) |so| {
        var r_buf: [4096]u8 = undefined;
        var sr = so.reader(io, &r_buf);
        while (true) {
            const n = sr.interface.readSliceShort(&r_buf) catch break;
            if (n == 0) break;
            try stdout_buf.appendSlice(a, r_buf[0..n]);
        }
    }
    if (child.stderr) |se| {
        var r_buf: [4096]u8 = undefined;
        var sr = se.reader(io, &r_buf);
        while (true) {
            const n = sr.interface.readSliceShort(&r_buf) catch break;
            if (n == 0) break;
            try stderr_buf.appendSlice(a, r_buf[0..n]);
        }
    }

    const term = child.wait(io) catch |err| {
        const msg = try std.fmt.allocPrint(a, "wait failed: {s}", .{@errorName(err)});
        return toolErrorResponse(a, id, msg);
    };

    var exit_code: i64 = -1;
    switch (term) {
        .exited => |c| exit_code = @as(i64, c),
        .signal => |sig| exit_code = -(@as(i64, @intCast(@intFromEnum(sig)))),
        else => exit_code = -1,
    }

    const payload = try obj(a, &.{
        .{ "exit_code", int(exit_code) },
        .{ "stdout", str(try a.dupe(u8, stdout_buf.items)) },
        .{ "stderr", str(try a.dupe(u8, stderr_buf.items)) },
    });
    const text = try jsonStrAlloc(a, payload);
    return toolTextResponse(a, id, text);
}

// ---- init -------------------------------------------------------------------

fn callInit(a: std.mem.Allocator, io: std.Io, id: json.Value, args: json.Value) ![]const u8 {
    var path: []const u8 = "";
    if (args == .object) {
        if (args.object.get("path")) |p| {
            if (p != .string) return try toolErrorResponse(a, id, "path must be a string");
            path = p.string;
        }
    }
    var owned_cwd: ?[]u8 = null;
    defer if (owned_cwd) |c| a.free(c);
    const root = if (path.len == 0) blk: {
        const c = try getCwd(a, io);
        owned_cwd = c;
        break :blk @as([]const u8, c);
    } else path;

    const s = store.Store.init(a, io, root);
    s.initStore() catch |err| {
        const msg = try std.fmt.allocPrint(a, "init failed: {s}", .{@errorName(err)});
        return toolErrorResponse(a, id, msg);
    };
    const pubkey = s.pubKey() catch |err| {
        const msg = try std.fmt.allocPrint(a, "pubkey read failed: {s}", .{@errorName(err)});
        return toolErrorResponse(a, id, msg);
    };
    defer a.free(pubkey);
    const payload = try obj(a, &.{ .{ "pubkey", str(try a.dupe(u8, pubkey)) } });
    const text = try jsonStrAlloc(a, payload);
    return toolTextResponse(a, id, text);
}

// ---- migrate ----------------------------------------------------------------

fn callMigrate(a: std.mem.Allocator, io: std.Io, id: json.Value, args: json.Value) ![]const u8 {
    if (args != .object) return try toolErrorResponse(a, id, "arguments must be an object");
    const file_val = args.object.get("file") orelse return try toolErrorResponse(a, id, "file is required");
    if (file_val != .string) return try toolErrorResponse(a, id, "file must be a string");
    const env_val = args.object.get("env") orelse return try toolErrorResponse(a, id, "env is required");
    if (env_val != .string) return try toolErrorResponse(a, id, "env must be a string");
    var keep: bool = false;
    if (args.object.get("keep")) |k| {
        if (k != .bool) return try toolErrorResponse(a, id, "keep must be a boolean");
        keep = k.bool;
    }

    const cwd = try getCwd(a, io);
    defer a.free(cwd);

    const data = std.Io.Dir.cwd().readFileAlloc(io, file_val.string, a, .limited(16 * 1024 * 1024)) catch |err| {
        const msg = try std.fmt.allocPrint(a, "read {s}: {s}", .{ file_val.string, @errorName(err) });
        return toolErrorResponse(a, id, msg);
    };
    defer a.free(data);

    const entries = envparse.parse(a, data) catch |err| {
        const msg = try std.fmt.allocPrint(a, "parse {s}: {s}", .{ file_val.string, @errorName(err) });
        return toolErrorResponse(a, id, msg);
    };
    defer envparse.freeEntries(a, entries);

    const s = store.Store.init(a, io, cwd);
    var existing = s.read(env_val.string) catch |err| {
        const msg = try std.fmt.allocPrint(a, "read env: {s}", .{@errorName(err)});
        return toolErrorResponse(a, id, msg);
    };
    defer existing.deinit();

    for (entries) |e| {
        const k_dup = try a.dupe(u8, e.key);
        const v_dup = try a.dupe(u8, e.value);
        if (existing.inner.fetchRemove(e.key)) |old| {
            a.free(old.key);
            a.free(old.value);
        }
        try existing.inner.put(k_dup, v_dup);
    }
    s.write(env_val.string, existing.inner) catch |err| {
        const msg = try std.fmt.allocPrint(a, "write: {s}", .{@errorName(err)});
        return toolErrorResponse(a, id, msg);
    };

    if (!keep) {
        std.Io.Dir.cwd().deleteFile(io, file_val.string) catch {};
    }

    const payload = try obj(a, &.{ .{ "count", int(@as(i64, @intCast(entries.len))) } });
    const text = try jsonStrAlloc(a, payload);
    return toolTextResponse(a, id, text);
}

// ---- whoami -----------------------------------------------------------------

fn callWhoami(a: std.mem.Allocator, io: std.Io, id: json.Value, args: json.Value) ![]const u8 {
    _ = args;
    const cwd = try getCwd(a, io);
    defer a.free(cwd);

    const s = store.Store.init(a, io, cwd);
    const pub_key = s.pubKey() catch |err| {
        const msg = try std.fmt.allocPrint(a, "pubkey read failed: {s} (run `envless init` first)", .{@errorName(err)});
        return toolErrorResponse(a, id, msg);
    };
    defer a.free(pub_key);

    var rcount: i64 = 0;
    if (s.recipients("")) |recs| {
        defer {
            for (recs) |r| a.free(r);
            a.free(recs);
        }
        rcount = @intCast(recs.len);
    } else |_| {}

    const payload = try obj(a, &.{
        .{ "pubkey", str(try a.dupe(u8, pub_key)) },
        .{ "recipients", int(rcount) },
    });
    const text = try jsonStrAlloc(a, payload);
    return toolTextResponse(a, id, text);
}

// ----------------------------- tests -----------------------------------------

const testing = std.testing;

test "handleLine: initialize returns serverInfo + capabilities.tools" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const req =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}
    ;
    const resp = (try handleLine(a, std.testing.io, "v0.1.0", req)).?;
    var parsed = try json.parseFromSlice(json.Value, a, resp, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("2.0", parsed.value.object.get("jsonrpc").?.string);
    const result = parsed.value.object.get("result").?.object;
    try testing.expectEqualStrings(PROTOCOL_VERSION, result.get("protocolVersion").?.string);
    const caps = result.get("capabilities").?.object;
    const tools_cap = caps.get("tools").?.object;
    try testing.expectEqual(false, tools_cap.get("listChanged").?.bool);
    const si = result.get("serverInfo").?.object;
    try testing.expectEqualStrings("envless", si.get("name").?.string);
    try testing.expectEqualStrings("v0.1.0", si.get("version").?.string);
}

test "handleLine: notifications/initialized returns null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const req = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\",\"params\":{}}";
    const resp = try handleLine(a, std.testing.io, "v0.1.0", req);
    try testing.expect(resp == null);
}

test "handleLine: tools/list returns 8 tools" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const req = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}";
    const resp = (try handleLine(a, std.testing.io, "v0.1.0", req)).?;
    var parsed = try json.parseFromSlice(json.Value, a, resp, .{});
    defer parsed.deinit();
    const tools = parsed.value.object.get("result").?.object.get("tools").?.array;
    try testing.expectEqual(@as(usize, 8), tools.items.len);
    // Spot-check names.
    const names = [_][]const u8{ "envs", "list", "get", "set", "exec", "init", "migrate", "whoami" };
    for (names, 0..) |want, i| {
        try testing.expectEqualStrings(want, tools.items[i].object.get("name").?.string);
    }
    // Verify get tool schema includes the pass property.
    const get_tool = tools.items[2].object;
    try testing.expectEqualStrings("get", get_tool.get("name").?.string);
    const get_props = get_tool.get("inputSchema").?.object.get("properties").?.object;
    try testing.expect(get_props.get("pass") != null);
    try testing.expectEqualStrings("string", get_props.get("pass").?.object.get("type").?.string);
}

test "handleLine: ping returns empty object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const req = "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"ping\"}";
    const resp = (try handleLine(a, std.testing.io, "v0.1.0", req)).?;
    var parsed = try json.parseFromSlice(json.Value, a, resp, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    _ = result; // existence is the assertion; an empty object is valid
}

test "handleLine: parse error returns -32700" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const resp = (try handleLine(a, std.testing.io, "v0.1.0", "not json")).?;
    var parsed = try json.parseFromSlice(json.Value, a, resp, .{});
    defer parsed.deinit();
    const err_obj = parsed.value.object.get("error").?.object;
    try testing.expectEqual(@as(i64, -32700), err_obj.get("code").?.integer);
}

test "handleLine: unknown method returns -32601 when id present" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const req = "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"prompts/list\"}";
    const resp = (try handleLine(a, std.testing.io, "v0.1.0", req)).?;
    var parsed = try json.parseFromSlice(json.Value, a, resp, .{});
    defer parsed.deinit();
    const err_obj = parsed.value.object.get("error").?.object;
    try testing.expectEqual(@as(i64, -32601), err_obj.get("code").?.integer);
}

test "handleLine: tools/call get without confirm is rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const req = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"get\",\"arguments\":{\"env\":\"dev\",\"key\":\"TOKEN\"}}}";
    const resp = (try handleLine(a, std.testing.io, "v0.1.0", req)).?;
    var parsed = try json.parseFromSlice(json.Value, a, resp, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    try testing.expectEqual(true, result.get("isError").?.bool);
    const content = result.get("content").?.array;
    try testing.expect(std.mem.indexOf(u8, content.items[0].object.get("text").?.string, "confirm") != null);
}

test "handleLine: tools/call envs in empty cwd returns []" {
    // This test runs in an isolated tmpdir where secrets/ does not exist.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd_save = try std.process.currentPathAlloc(std.testing.io, a);
    defer a.free(cwd_save);
    var _path_buf: [4096]u8 = undefined;
    const _path_len = try tmp.dir.realPath(std.testing.io, &_path_buf);
    const tmp_abs = try a.dupeZ(u8, _path_buf[0.._path_len]);
    defer a.free(tmp_abs);
    _ = std.c.chdir(tmp_abs.ptr);
    defer _ = std.c.chdir(cwd_save.ptr);

    const req = "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"envs\",\"arguments\":{}}}";
    const resp = (try handleLine(a, std.testing.io, "v0.1.0", req)).?;
    var parsed = try json.parseFromSlice(json.Value, a, resp, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    try testing.expectEqual(false, result.get("isError").?.bool);
    const content = result.get("content").?.array;
    const text = content.items[0].object.get("text").?.string;
    var inner = try json.parseFromSlice(json.Value, a, text, .{});
    defer inner.deinit();
    try testing.expectEqual(@as(usize, 0), inner.value.object.get("envs").?.array.items.len);
}
