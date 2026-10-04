//! Explicit local stdio MCP client; servers retain the user's ordinary process permissions.
const std = @import("std");
const platform = @import("platform.zig");
const terminal = @import("terminal.zig");
const A = std.mem.Allocator;
const Value = std.json.Value;
const max_bytes = 1024 * 1024;
pub const Connection = struct { name: []const u8, argv: []const []const u8 };
const Config = struct { servers: []const Connection = &.{} };
var interrupted = std.atomic.Value(bool).init(false);
fn signal(_: c_int) callconv(.c) void {
    interrupted.store(true, .seq_cst);
    terminal.cancelSession();
}
fn noop(_: c_int) callconv(.c) void {}
fn path(a: A, dir: []const u8, name: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ dir, name });
}
fn validName(name: []const u8, max: usize) bool {
    if (name.len == 0 or name.len > max) return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_' and ch != '.') return false;
    return true;
}
fn load(a: A, dir: []const u8) !Config {
    const p = try path(a, dir, "mcp-servers.json");
    const f = std.fs.cwd().openFile(p, .{}) catch |err| {
        if (err == error.FileNotFound) return .{};
        return err;
    };
    defer f.close();
    platform.requirePrivateFile(a, p) catch return error.McpPrivateConfigRequired;
    const bytes = try f.readToEndAlloc(a, max_bytes);
    const config = (std.json.parseFromSlice(Config, a, bytes, .{ .allocate = .alloc_always }) catch return error.InvalidMcpConfig).value;
    if (config.servers.len > 32) return error.InvalidMcpConfig;
    for (config.servers, 0..) |server, i| {
        if (!validName(server.name, 64) or server.argv.len == 0 or server.argv.len > 64) return error.InvalidMcpConfig;
        for (server.argv) |arg| if (arg.len > 8192 or std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidMcpConfig;
        if (server.argv[0].len == 0) return error.InvalidMcpConfig;
        for (config.servers[0..i]) |prior| if (std.mem.eql(u8, prior.name, server.name)) return error.InvalidMcpConfig;
    }
    return config;
}
fn save(a: A, dir: []const u8, config: Config) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, config, .{});
    if (bytes.len > max_bytes) return error.InvalidMcpConfig;
    var nonce: [8]u8 = undefined;
    std.crypto.random.bytes(&nonce);
    const target = try path(a, dir, "mcp-servers.json");
    const tmp = try std.fmt.allocPrint(a, "{s}.tmp-{x}", .{ target, nonce });
    defer std.fs.cwd().deleteFile(tmp) catch {};
    const f = try std.fs.cwd().createFile(tmp, .{ .exclusive = true, .mode = 0o600 });
    defer f.close();
    try platform.privateFile(a, tmp);
    try f.writeAll(bytes);
    try f.sync();
    try std.fs.cwd().rename(tmp, target);
}
fn valueField(v: Value, key: []const u8) !Value {
    if (v != .object) return error.McpProtocolError;
    return v.object.get(key) orelse error.McpProtocolError;
}
fn valueString(v: Value) ![]const u8 {
    if (v != .string) return error.McpProtocolError;
    return v.string;
}
fn encode(a: A, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, value, .{ .emit_null_optional_fields = false });
}
fn timeout() !i64 {
    const raw = platform.getenv("DOIN_MCP_TIMEOUT_MS") orelse return 10000;
    const n = std.fmt.parseInt(i64, raw, 10) catch return error.InvalidMcpArguments;
    if (n < 100 or n > 30000) return error.InvalidMcpArguments;
    return n;
}
const Session = struct {
    allocator: A,
    child: std.process.Child,
    group: platform.ChildGroup,
    output: std.ArrayList(u8) = .empty,
    logs: std.ArrayList(u8) = .empty,
    consumed: usize = 0,
    total: usize = 0,
    frames: usize = 0,
    next_id: i64 = 0,
    deadline: i64,
    eof: bool = false,
    done: bool = false,
    fn start(a: A, argv: []const []const u8, limit: ?i64) !Session {
        const duration = try timeout();
        const deadline = @min(std.time.milliTimestamp() + duration, limit orelse std.math.maxInt(i64));
        if (deadline <= std.time.milliTimestamp()) return error.McpTimedOut;
        if (terminal.cancelled() or interrupted.load(.seq_cst)) return error.McpCancelled;
        var child = std.process.Child.init(argv, a);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        const group = try platform.ChildGroup.spawn(&child);
        var session: Session = .{ .allocator = a, .child = child, .group = group, .deadline = deadline };
        errdefer _ = session.finish() catch {};
        try session.child.waitForSpawn();
        try platform.pipeNonblocking(session.child.stdin.?, true);
        try platform.pipeNonblocking(session.child.stdout.?, false);
        try platform.pipeNonblocking(session.child.stderr.?, false);
        return session;
    }
    fn check(self: *Session) !void {
        if (interrupted.load(.seq_cst) or terminal.cancelled()) return error.McpCancelled;
        if (std.time.milliTimestamp() >= self.deadline) return error.McpTimedOut;
    }
    fn drain(self: *Session, f: std.fs.File, stderr_stream: bool) !void {
        var buffer: [8192]u8 = undefined;
        for (0..4) |_| {
            const n = (try platform.pipeReadAvailable(f, &buffer)) orelse return;
            if (n == 0) {
                if (!stderr_stream) self.eof = true;
                return;
            }
            if (stderr_stream) {
                const keep = @min(n, 4096 -| self.logs.items.len);
                try self.logs.appendSlice(self.allocator, buffer[0..keep]);
            } else {
                self.total += n;
                if (self.total > max_bytes) return error.McpOutputTooLarge;
                try self.output.appendSlice(self.allocator, buffer[0..n]);
            }
            try self.check();
        }
    }
    fn pump(self: *Session, writable: bool) !void {
        try self.check();
        if (platform.windows) {
            try self.drain(self.child.stdout.?, false);
            try self.drain(self.child.stderr.?, true);
            std.Thread.sleep(10 * std.time.ns_per_ms);
        } else {
            var fds = [_]std.posix.pollfd{
                .{ .fd = self.child.stdout.?.handle, .events = std.posix.POLL.IN, .revents = 0 },
                .{ .fd = self.child.stderr.?.handle, .events = std.posix.POLL.IN, .revents = 0 },
                .{ .fd = self.child.stdin.?.handle, .events = if (writable) std.posix.POLL.OUT else 0, .revents = 0 },
            };
            _ = try std.posix.poll(&fds, 50);
            if (fds[0].revents != 0) try self.drain(self.child.stdout.?, false);
            if (fds[1].revents != 0) try self.drain(self.child.stderr.?, true);
        }
    }

    fn send(self: *Session, value: anytype) !void {
        const bytes = try encode(self.allocator, value);
        defer self.allocator.free(bytes);
        if (bytes.len > max_bytes) return error.McpOutputTooLarge;
        var written: usize = 0;
        while (written < bytes.len) {
            try self.check();
            const n = platform.pipeWriteAvailable(self.child.stdin.?, bytes[written..]) catch |err| {
                if (err == error.WouldBlock) {
                    try self.pump(true);
                    continue;
                }
                return error.McpServerClosed;
            };
            written += n;
        }
        while (true) {
            _ = platform.pipeWriteAvailable(self.child.stdin.?, "\n") catch |err| {
                if (err == error.WouldBlock) {
                    try self.pump(true);
                    continue;
                }
                return error.McpServerClosed;
            };
            break;
        }
    }
    fn response(self: *Session, id: i64) !Value {
        while (true) {
            try self.check();
            if (std.mem.indexOfScalarPos(u8, self.output.items, self.consumed, '\n')) |end| {
                const line = std.mem.trimEnd(u8, self.output.items[self.consumed..end], "\r");
                self.consumed = end + 1;
                self.frames += 1;
                if (self.frames > 256) return error.McpOutputTooLarge;
                const message = (std.json.parseFromSlice(Value, self.allocator, line, .{ .allocate = .alloc_always }) catch return error.McpProtocolError).value;
                if (!std.mem.eql(u8, try valueString(try valueField(message, "jsonrpc")), "2.0")) return error.McpProtocolError;
                if (message.object.get("method")) |method| {
                    const name = try valueString(method);
                    if (message.object.get("id")) |request_id| {
                        if (std.mem.eql(u8, name, "ping")) try self.send(.{ .jsonrpc = "2.0", .id = request_id, .result = Value{ .object = std.json.ObjectMap.init(self.allocator) } }) else try self.send(.{ .jsonrpc = "2.0", .id = request_id, .@"error" = .{ .code = @as(i32, -32601), .message = "Client capability not enabled" } });
                    }
                    continue;
                }
                const result_id = try valueField(message, "id");
                if (result_id != .integer or result_id.integer != id) return error.McpProtocolError;
                if (message.object.get("error")) |err| {
                    try terminal.line(self.allocator, "MCP server error: ", try valueString(try valueField(err, "message")));
                    return error.McpRequestFailed;
                }
                return valueField(message, "result");
            }
            if (self.eof) return error.McpServerClosed;
            try self.pump(false);
        }
    }
    fn request(self: *Session, method: []const u8, params: anytype) !Value {
        self.next_id += 1;
        try self.send(.{ .jsonrpc = "2.0", .id = self.next_id, .method = method, .params = params });
        return self.response(self.next_id) catch |err| {
            if ((err == error.McpTimedOut or err == error.McpCancelled) and !std.mem.eql(u8, method, "initialize")) {
                const note = encode(self.allocator, .{ .jsonrpc = "2.0", .method = "notifications/cancelled", .params = .{ .requestId = self.next_id, .reason = "Client stopped waiting" } }) catch return err;
                const frame = std.fmt.allocPrint(self.allocator, "{s}\n", .{note}) catch return err;
                defer self.allocator.free(note);
                defer self.allocator.free(frame);
                // Under PIPE_BUF, nonblocking pipe write is atomic or would-block.
                _ = platform.pipeWriteAvailable(self.child.stdin.?, frame) catch 0;
            }
            return err;
        };
    }
    fn finish(self: *Session) !void {
        if (self.done) return;
        self.done = true;
        if (self.child.stdin) |f| {
            f.close();
            self.child.stdin = null;
        }
        var success = false;
        const grace = std.time.milliTimestamp() + 200;
        if (platform.windows) {
            while (std.time.milliTimestamp() < grace and !self.group.done(&self.child)) std.Thread.sleep(10 * std.time.ns_per_ms);
            self.group.terminate(&self.child);
            const term = try self.child.wait();
            success = term == .Exited and term.Exited == 0;
            self.group.close();
        } else {
            var status: ?u32 = null;
            while (std.time.milliTimestamp() < grace) {
                const result = std.posix.waitpid(self.child.id, std.posix.W.NOHANG);
                if (result.pid != 0) {
                    status = result.status;
                    break;
                }
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }
            self.group.terminate(&self.child);
            if (status == null) status = std.posix.waitpid(self.child.id, 0).status;
            if (self.child.stdout) |f| f.close();
            if (self.child.stderr) |f| f.close();
            success = std.posix.W.IFEXITED(status.?) and std.posix.W.EXITSTATUS(status.?) == 0;
        }
        if (self.logs.items.len > 0) {
            const clean = terminal.clean(self.allocator, self.logs.items, true) catch "Server logs unavailable";
            std.fs.File.stderr().writeAll("MCP server logs (capped):\n") catch {};
            std.fs.File.stderr().writeAll(clean) catch {};
            std.fs.File.stderr().writeAll("\n") catch {};
        }
        self.output.deinit(self.allocator);
        self.logs.deinit(self.allocator);
        if (!success) return error.McpServerExit;
    }
};
fn toolCatalog(a: A, session: *Session) ![]const Value {
    var tools: std.ArrayList(Value) = .empty;
    var cursor: ?[]const u8 = null;
    for (0..32) |_| {
        const result = try session.request("tools/list", .{ .cursor = cursor });
        const listed = try valueField(result, "tools");
        if (listed != .array) return error.McpProtocolError;
        for (listed.array.items) |tool| {
            const name = try valueString(try valueField(tool, "name"));
            if (!validName(name, 128) or try valueField(tool, "inputSchema") != .object or tools.items.len == 512) return error.McpProtocolError;
            for (tools.items) |prior| if (std.mem.eql(u8, try valueString(try valueField(prior, "name")), name)) return error.McpProtocolError;
            try tools.append(a, tool);
        }
        if (result.object.get("nextCursor")) |next_cursor| {
            const next = try valueString(next_cursor);
            if (next.len == 0 or next.len > 4096 or (cursor != null and std.mem.eql(u8, cursor.?, next))) return error.McpProtocolError;
            cursor = next;
        } else return tools.toOwnedSlice(a);
    }
    return error.McpOutputTooLarge;
}
pub fn run(a: A, args: []const []const u8, config_dir: []const u8) !void {
    const cmd = if (args.len == 0) "list" else args[0];
    if (std.mem.eql(u8, cmd, "add") or std.mem.eql(u8, cmd, "remove")) {
        if (args.len < 2 or !validName(args[1], 64)) return error.InvalidMcpArguments;
        if (std.mem.eql(u8, cmd, "add") and (args.len < 4 or !std.mem.eql(u8, args[2], "--"))) return error.InvalidMcpArguments;
        if (std.mem.eql(u8, cmd, "remove") and args.len != 2) return error.InvalidMcpArguments;
        try std.fs.cwd().makePath(config_dir);
        const lock = try std.fs.cwd().createFile(try path(a, config_dir, ".mcp-servers.lock"), .{ .truncate = false, .mode = 0o600 });
        defer lock.close();
        if (!try platform.tryLockExclusive(lock)) return error.McpConfigBusy;
        const old = try load(a, config_dir);
        var servers: std.ArrayList(Connection) = .empty;
        var found = false;
        for (old.servers) |server| if (std.mem.eql(u8, server.name, args[1])) {
            found = true;
        } else {
            try servers.append(a, server);
        };
        if (std.mem.eql(u8, cmd, "add")) {
            if (found) return error.McpNameExists;
            if (args.len - 3 > 64 or servers.items.len == 32) return error.InvalidMcpArguments;
            for (args[3..]) |arg| if (arg.len > 8192 or std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidMcpArguments;
            if (args[3].len == 0) return error.InvalidMcpArguments;
            try servers.append(a, .{ .name = args[1], .argv = args[3..] });
        } else if (!found) return error.McpServerNotFound;
        try save(a, config_dir, .{ .servers = servers.items });
        return terminal.systemLine(a, "", if (std.mem.eql(u8, cmd, "add")) "MCP server saved. No process started." else "MCP server removed.");
    }
    const config = try load(a, config_dir);
    if (std.mem.eql(u8, cmd, "list")) {
        if (args.len > 1) return error.InvalidMcpArguments;
        if (config.servers.len == 0) return terminal.systemLine(a, "", "No local MCP servers. Use /mcp add NAME -- COMMAND ARG...");
        for (config.servers) |server| try terminal.line(a, "  ", server.name);
        return;
    }
    const calling = std.mem.eql(u8, cmd, "call");
    if ((!calling and !std.mem.eql(u8, cmd, "tools")) or args.len != (if (calling) @as(usize, 4) else 2)) return error.InvalidMcpArguments;
    var arguments: Value = .null;
    if (calling) {
        if (!validName(args[2], 128) or args[3].len > max_bytes) return error.InvalidMcpArguments;
        arguments = (std.json.parseFromSlice(Value, a, args[3], .{}) catch return error.InvalidMcpArguments).value;
        if (arguments != .object) return error.InvalidMcpArguments;
    }
    var selected: ?Connection = null;
    for (config.servers) |server| if (std.mem.eql(u8, server.name, args[1])) {
        selected = server;
        break;
    };
    const server = selected orelse return error.McpServerNotFound;
    const result = if (calling) try invoke(a, config_dir, server.name, args[2], arguments, null) else try discover(a, config_dir, server.name, null);
    if (!calling) {
        for (result.array.items) |tool| {
            try terminal.heading(a, try valueString(try valueField(tool, "name")));
            if (tool.object.get("description")) |description| try terminal.line(a, "  ", try valueString(description));
            try terminal.line(a, "  Arguments: ", try encode(a, try valueField(tool, "inputSchema")));
        }
        return;
    }
    const text = try terminal.clean(a, try encode(a, result), true);
    try std.fs.File.stdout().writeAll(text);
    try std.fs.File.stdout().writeAll("\n");
    if (result.object.get("isError")) |is_error| {
        if (is_error != .bool) return error.McpProtocolError;
        if (is_error.bool) return error.McpToolFailed;
    }
}
pub fn connections(a: A, config_dir: []const u8) ![]const Connection {
    return (try load(a, config_dir)).servers;
}
pub fn discover(a: A, config_dir: []const u8, name: []const u8, deadline_ms: ?i64) !Value {
    return operate(a, config_dir, name, null, .null, deadline_ms);
}
pub fn invoke(a: A, config_dir: []const u8, name: []const u8, tool: []const u8, arguments: Value, deadline_ms: ?i64) !Value {
    if (!validName(tool, 128) or arguments != .object) return error.InvalidMcpArguments;
    return operate(a, config_dir, name, tool, arguments, deadline_ms);
}
fn operate(a: A, config_dir: []const u8, name: []const u8, tool_name: ?[]const u8, arguments: Value, deadline_ms: ?i64) !Value {
    var found: ?Connection = null;
    for (try connections(a, config_dir)) |item| if (std.mem.eql(u8, item.name, name)) {
        found = item;
        break;
    };
    const selected = found orelse return error.McpServerNotFound;
    const signals = try platform.SignalGuard.install(signal);
    defer signals.restore();
    var old_pipe: if (platform.windows) void else std.posix.Sigaction = undefined;
    if (!platform.windows) {
        const action: std.posix.Sigaction = .{ .handler = .{ .handler = noop }, .mask = std.posix.sigemptyset(), .flags = 0 };
        std.posix.sigaction(std.posix.SIG.PIPE, &action, &old_pipe);
    }
    defer if (!platform.windows) std.posix.sigaction(std.posix.SIG.PIPE, &old_pipe, null);
    var session = try Session.start(a, selected.argv, deadline_ms);
    defer _ = session.finish() catch {};
    const initialized = try session.request("initialize", .{ .protocolVersion = "2025-11-25", .capabilities = Value{ .object = std.json.ObjectMap.init(a) }, .clientInfo = .{ .name = "doin", .version = "0.3.0" } });
    if (!std.mem.eql(u8, try valueString(try valueField(initialized, "protocolVersion")), "2025-11-25")) return error.McpUnsupportedVersion;
    if (try valueField(try valueField(initialized, "capabilities"), "tools") != .object) return error.McpToolsUnavailable;
    try session.send(.{ .jsonrpc = "2.0", .method = "notifications/initialized" });
    const catalog = try toolCatalog(a, &session);
    if (tool_name == null) {
        try session.finish();
        var array = std.array_list.Managed(Value).init(a);
        try array.appendSlice(catalog);
        return .{ .array = array };
    }
    var exists = false;
    for (catalog) |item| if (std.mem.eql(u8, try valueString(try valueField(item, "name")), tool_name.?)) {
        exists = true;
        break;
    };
    if (!exists) return error.McpToolNotFound;
    const result = try session.request("tools/call", .{ .name = tool_name.?, .arguments = arguments });
    if (try valueField(result, "content") != .array) return error.McpProtocolError;
    try session.finish();
    return result;
}
