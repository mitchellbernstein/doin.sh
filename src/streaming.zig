const std = @import("std");
const A = std.mem.Allocator;
const Value = std.json.Value;
const max_bytes = 4 * 1024 * 1024;
pub const Sink = struct {
    context: *anyopaque,
    write: *const fn (*anyopaque, []const u8) anyerror!void,
};
pub const Response = struct { text: []const u8, response: Value };
pub const Parser = struct {
    allocator: A,
    sink: ?Sink,
    line: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,
    text: std.ArrayList(u8) = .empty,
    total: usize = 0,
    completed: ?Value = null,
    failed: bool = false,

    pub fn init(a: A, sink: ?Sink) Parser {
        return .{ .allocator = a, .sink = sink };
    }
    pub fn deinit(self: *Parser) void {
        self.line.deinit(self.allocator);
        self.data.deinit(self.allocator);
        self.text.deinit(self.allocator);
    }
    pub fn feed(self: *Parser, bytes: []const u8) !void {
        if (self.failed) return error.IncompleteResponse;
        errdefer self.failed = true;
        if (bytes.len > max_bytes - self.total) return error.ProviderResponseTooLarge;
        self.total += bytes.len;
        for (bytes) |byte| {
            if (byte == '\n') {
                try self.processLine(std.mem.trimEnd(u8, self.line.items, "\r"));
                self.line.clearRetainingCapacity();
            } else {
                if (self.line.items.len >= 1024 * 1024) return error.ProviderResponseTooLarge;
                try self.line.append(self.allocator, byte);
            }
        }
    }
    fn processLine(self: *Parser, line: []const u8) !void {
        if (line.len == 0) {
            try self.event();
            self.data.clearRetainingCapacity();
            return;
        }
        if (line[0] == ':') return;
        if (std.mem.eql(u8, line, "data") or std.mem.startsWith(u8, line, "data:")) {
            var bytes = if (line.len == 4) "" else line[5..];
            if (bytes.len > 0 and bytes[0] == ' ') bytes = bytes[1..];
            if (self.data.items.len > 0) {
                if (self.data.items.len >= 1024 * 1024) return error.ProviderResponseTooLarge;
                try self.data.append(self.allocator, '\n');
            }
            if (bytes.len > 1024 * 1024 - self.data.items.len) return error.ProviderResponseTooLarge;
            try self.data.appendSlice(self.allocator, bytes);
        }
    }
    fn event(self: *Parser) !void {
        if (self.data.items.len == 0 or std.mem.eql(u8, self.data.items, "[DONE]")) return;
        if (!std.unicode.utf8ValidateSlice(self.data.items)) return error.InvalidProviderResponse;
        const parsed = try std.json.parseFromSlice(Value, self.allocator, self.data.items, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        const v = parsed.value;
        const typ = try string(try field(v, "type"));
        if (std.mem.eql(u8, typ, "error") or std.mem.eql(u8, typ, "response.failed") or std.mem.eql(u8, typ, "response.incomplete") or std.mem.startsWith(u8, typ, "response.refusal.")) return error.ProviderRefusedOrIncomplete;
        if (self.completed != null) return error.InvalidProviderResponse;
        if (std.mem.eql(u8, typ, "response.output_text.delta")) {
            const delta = try string(try field(v, "delta"));
            if (delta.len > 1024 * 1024 - self.text.items.len) return error.ProviderResponseTooLarge;
            try self.text.appendSlice(self.allocator, delta);
            if (self.sink) |sink| try sink.write(sink.context, delta);
        } else if (std.mem.eql(u8, typ, "response.completed")) {
            const response = try field(v, "response");
            if (!std.mem.eql(u8, try string(try field(response, "status")), "completed")) return error.IncompleteResponse;
            const output = try field(response, "output");
            if (output != .array) return error.InvalidProviderResponse;
            var final: std.ArrayList(u8) = .empty;
            defer final.deinit(self.allocator);
            for (output.array.items) |item| {
                if (!std.mem.eql(u8, try string(try field(item, "type")), "message")) continue;
                const content = try field(item, "content");
                if (content != .array) return error.InvalidProviderResponse;
                for (content.array.items) |part| {
                    const kind = try string(try field(part, "type"));
                    if (std.mem.eql(u8, kind, "refusal")) return error.ProviderRefusedOrIncomplete;
                    if (std.mem.eql(u8, kind, "output_text")) try final.appendSlice(self.allocator, try string(try field(part, "text")));
                }
            }
            if (!std.mem.eql(u8, final.items, self.text.items)) return error.IncompleteResponse;
            const encoded = try std.json.Stringify.valueAlloc(self.allocator, response, .{});
            defer self.allocator.free(encoded);
            self.completed = (try std.json.parseFromSlice(Value, self.allocator, encoded, .{ .allocate = .alloc_always })).value;
        }
    }
    pub fn finish(self: *Parser) !Response {
        if (self.failed or self.line.items.len != 0 or self.data.items.len != 0) return error.IncompleteResponse;
        const response = self.completed orelse return error.IncompleteResponse;
        return .{ .text = try self.allocator.dupe(u8, self.text.items), .response = response };
    }
};
fn field(v: Value, key: []const u8) !Value {
    if (v != .object) return error.InvalidProviderResponse;
    return v.object.get(key) orelse error.InvalidProviderResponse;
}
fn string(v: Value) ![]const u8 {
    if (v != .string) return error.InvalidProviderResponse;
    return v.string;
}
