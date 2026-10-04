const std = @import("std");
const productivity = @import("productivity.zig");
const reminders = @import("reminders.zig");
const A = std.mem.Allocator;
const V = std.json.Value;
pub const Kind = enum { text, number, date, single_select, multi_select, boolean, member };
pub const Option = struct { id: []const u8, name: []const u8 };
pub const Property = struct { id: []const u8, name: []const u8, kind: Kind, options: []Option = &.{}, members: []Member = &.{} };
pub const Member = struct { id: []const u8, name: []const u8 };
const schema_prefix = "<!-- doin:properties=";
const value_prefix = "<!-- doin:values=";
const Span = struct { start: usize, end: usize, json: []const u8 };
fn span(line: []const u8, prefix: []const u8) !?Span {
    const start = std.mem.indexOf(u8, line, prefix) orelse return null;
    const close = std.mem.indexOfPos(u8, line, start + prefix.len, " -->") orelse return error.InvalidPropertyMetadata;
    if (std.mem.indexOfPos(u8, line, close + 4, prefix) != null) return error.DuplicatePropertyMetadata;
    return .{ .start = start, .end = close + 4, .json = line[start + prefix.len .. close] };
}
fn label(value: []const u8) !void {
    if (value.len == 0 or value.len > 120 or !std.unicode.utf8ValidateSlice(value) or !std.mem.eql(u8, value, std.mem.trim(u8, value, " \t\r\n"))) return error.InvalidPropertyName;
    for (value) |c| if (c < 32 or c == 127) return error.InvalidPropertyName;
}
fn identity(value: []const u8) bool {
    if (value.len != 32) return false;
    for (value) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}
fn newId(a: A) ![]const u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    return a.dupe(u8, &std.fmt.bytesToHex(bytes, .lower));
}
pub fn schema(a: A, markdown: []const u8) ![]Property {
    var lines = std.mem.splitScalar(u8, markdown, '\n');
    var fence: reminders.FenceTracker = .{};
    var found: ?[]Property = null;
    while (lines.next()) |line| {
        if (fence.feed(std.mem.trim(u8, line, " \t\r"))) continue;
        if (try span(line, schema_prefix)) |s| {
            if (found != null or !std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), line[s.start..s.end])) return error.DuplicatePropertyMetadata;
            found = (try std.json.parseFromSlice([]Property, a, s.json, .{ .allocate = .alloc_always })).value;
        }
    }
    const items = found orelse return a.alloc(Property, 0);
    if (items.len > 64) return error.PropertyLimit;
    for (items, 0..) |p, i| {
        try label(p.name);
        if (!identity(p.id) or p.options.len > 128) return error.InvalidPropertyMetadata;
        for (items[0..i]) |earlier| if (std.mem.eql(u8, p.id, earlier.id) or std.mem.eql(u8, p.name, earlier.name)) return error.DuplicateProperty;
        for (p.options, 0..) |o, j| {
            try label(o.name);
            if (!identity(o.id)) return error.InvalidPropertyMetadata;
            for (p.options[0..j]) |earlier| if (std.mem.eql(u8, o.id, earlier.id) or std.mem.eql(u8, o.name, earlier.name)) return error.DuplicatePropertyOption;
        }
        if (p.members.len > 128 or (p.kind != .member and p.members.len != 0)) return error.InvalidPropertyMetadata;
        for (p.members, 0..) |m, mi| {
            try label(m.name);
            if (m.id.len == 0 or m.id.len > 80) return error.InvalidPropertyMetadata;
            for (m.id) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return error.InvalidPropertyMetadata;
            for (p.members[0..mi]) |prior| if (std.mem.eql(u8, prior.id, m.id)) return error.InvalidPropertyMetadata;
        }
        if (p.kind != .single_select and p.kind != .multi_select and p.options.len != 0) return error.InvalidPropertyMetadata;
    }
    return items;
}
fn json(a: A, value: anytype) ![]const u8 {
    const raw = try std.json.Stringify.valueAlloc(a, value, .{});
    var result: std.ArrayList(u8) = .empty;
    for (raw) |c| try result.appendSlice(a, switch (c) {
        '<' => "\\u003c",
        '>' => "\\u003e",
        else => &.{c},
    });
    return result.toOwnedSlice(a);
}
fn values(a: A, line: []const u8) !V {
    const s = try span(line, value_prefix) orelse return .{ .object = std.json.ObjectMap.init(a) };
    const v = (try std.json.parseFromSlice(V, a, s.json, .{ .allocate = .alloc_always })).value;
    if (v != .object or v.object.count() > 64) return error.InvalidPropertyMetadata;
    return v;
}
fn findProperty(items: []Property, key: []const u8) !usize {
    for (items, 0..) |p, i| if (std.mem.eql(u8, key, p.id) or std.mem.eql(u8, key, p.name)) return i;
    return error.PropertyNotFound;
}
fn option(p: Property, key: []const u8) ![]const u8 {
    for (p.options) |o| if (std.mem.eql(u8, key, o.id) or std.mem.eql(u8, key, o.name)) return o.id;
    return error.PropertyOptionNotFound;
}
fn validDate(value: []const u8) bool {
    if (value.len != 10 or value[4] != '-' or value[7] != '-') return false;
    for (value, 0..) |c, i| if (i != 4 and i != 7 and !std.ascii.isDigit(c)) return false;
    const year = std.fmt.parseInt(u16, value[0..4], 10) catch return false;
    const month = std.fmt.parseInt(u8, value[5..7], 10) catch return false;
    const day = std.fmt.parseInt(u8, value[8..10], 10) catch return false;
    if (year == 0 or month == 0 or month > 12 or day == 0) return false;
    const days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return day <= days[month - 1] + @as(u8, if (month == 2 and year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)) 1 else 0);
}
fn typed(a: A, p: Property, input: []const u8) !V {
    switch (p.kind) {
        .text => {
            if (input.len > 4096 or !std.unicode.utf8ValidateSlice(input)) return error.InvalidPropertyValue;
            for (input) |c| if (c < 32 or c == 127) return error.InvalidPropertyValue;
            return .{ .string = input };
        },
        .number => {
            const n = std.fmt.parseFloat(f64, input) catch return error.InvalidPropertyValue;
            if (!std.math.isFinite(n) or input.len == 0 or !std.mem.eql(u8, input, std.mem.trim(u8, input, " \t\r\n"))) return error.InvalidPropertyValue;
            return .{ .float = n };
        },
        .date => {
            if (!validDate(input)) return error.InvalidPropertyValue;
            return .{ .string = input };
        },
        .boolean => {
            if (std.mem.eql(u8, input, "true")) return .{ .bool = true };
            if (std.mem.eql(u8, input, "false")) return .{ .bool = false };
            return error.InvalidPropertyValue;
        },
        .single_select => return .{ .string = try option(p, input) },
        .multi_select => {
            var result: V = .{ .array = std.array_list.Managed(V).init(a) };
            var parts = std.mem.splitScalar(u8, input, ',');
            while (parts.next()) |raw| {
                const id = try option(p, std.mem.trim(u8, raw, " "));
                for (result.array.items) |v| if (std.mem.eql(u8, v.string, id)) return error.DuplicatePropertyOption;
                try result.array.append(.{ .string = id });
            }
            return result;
        },
        .member => return error.TeamMemberCatalogRequired,
    }
}
fn lineValues(a: A, line: []const u8, v: V) ![]const u8 {
    const s = try span(line, value_prefix);
    const end = if (std.mem.endsWith(u8, line, "\r\n")) line.len - 2 else if (std.mem.endsWith(u8, line, "\n")) line.len - 1 else line.len;
    const comment = if (v.object.count() == 0) "" else try std.fmt.allocPrint(a, "{s}{s} -->", .{ value_prefix, try json(a, v) });
    if (s) |old| return std.fmt.allocPrint(a, "{s}{s}{s}", .{ line[0..old.start], comment, line[old.end..] });
    const insert = std.mem.indexOf(u8, line[0..end], "<!-- doin:id=") orelse end;
    return std.fmt.allocPrint(a, "{s}{s}{s}{s}{s}", .{ line[0..insert], if (comment.len == 0) "" else " ", comment, if (insert < end and comment.len > 0) " " else "", line[insert..] });
}
fn proposal(a: A, markdown: []const u8, task: usize, p: Property, value: ?V) !productivity.Proposal {
    const t = try productivity.find(a, markdown, task);
    var v = try values(a, markdown[t.start..t.end]);
    if (value) |item| try v.object.put(p.id, item) else _ = v.object.swapRemove(p.id);
    const edited = try lineValues(a, markdown[t.start..t.end], v);
    return .{ .markdown = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ markdown[0..t.start], edited, markdown[t.end..] }), .selected = 1, .preview = try std.fmt.allocPrint(a, "Task {d} / {s}: {s}\n", .{ task, p.name, if (value) |item| try json(a, item) else "unset" }) };
}
pub fn set(a: A, markdown: []const u8, task: usize, key: []const u8, input: []const u8) !productivity.Proposal {
    const items = try schema(a, markdown);
    const p = items[try findProperty(items, key)];
    return proposal(a, markdown, task, p, try typed(a, p, input));
}
pub fn unset(a: A, markdown: []const u8, task: usize, key: []const u8) !productivity.Proposal {
    const items = try schema(a, markdown);
    return proposal(a, markdown, task, items[try findProperty(items, key)], null);
}
pub fn setMember(a: A, markdown: []const u8, task: usize, key: []const u8, accountId: []const u8, catalog: []const Member) !productivity.Proposal {
    const items = try schema(a, markdown);
    const p = items[try findProperty(items, key)];
    if (p.kind != .member) return error.InvalidPropertyType;
    for (catalog) |member| if (std.mem.eql(u8, member.id, accountId)) return proposal(a, markdown, task, p, .{ .string = member.id });
    return error.InvalidTeamAssignee;
}
pub fn list(a: A, markdown: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}\n", .{try std.json.Stringify.valueAlloc(a, try schema(a, markdown), .{ .whitespace = .indent_2 })});
}
fn kind(input: []const u8) !Kind {
    if (std.mem.eql(u8, input, "string")) return .text;
    const k = std.meta.stringToEnum(Kind, input) orelse return error.InvalidPropertyType;
    if (k == .member) return error.TeamMemberCatalogRequired;
    return k;
}
fn replaceSchema(a: A, markdown: []const u8, items: []Property) ![]const u8 {
    const comment = try std.fmt.allocPrint(a, "{s}{s} -->", .{ schema_prefix, try json(a, items) });
    var lines = std.mem.splitScalar(u8, markdown, '\n');
    var fence: reminders.FenceTracker = .{};
    var offset: usize = 0;
    while (lines.next()) |line| {
        if (!fence.feed(std.mem.trim(u8, line, " \t\r"))) {
            if (try span(line, schema_prefix)) |s| return std.fmt.allocPrint(a, "{s}{s}{s}", .{ markdown[0 .. offset + s.start], comment, markdown[offset + s.end ..] });
        }
        offset += line.len + 1;
    }
    return std.fmt.allocPrint(a, "{s}\n{s}", .{ comment, markdown });
}
fn clearValues(a: A, markdown: []const u8, propertyId: []const u8, allow: bool, optionId: ?[]const u8) !struct { markdown: []const u8, count: usize } {
    const tasks = try productivity.parse(a, markdown);
    var result: std.ArrayList(u8) = .empty;
    var cursor: usize = 0;
    var count: usize = 0;
    for (tasks) |t| {
        var v = try values(a, markdown[t.start..t.end]);
        if (v.object.get(propertyId)) |old| {
            if (optionId) |oid| {
                var affected = false;
                if (old == .string) affected = std.mem.eql(u8, old.string, oid) else if (old == .array) for (old.array.items) |item| {
                    if (item == .string and std.mem.eql(u8, item.string, oid)) affected = true;
                };
                if (!affected) continue;
            }
            if (!allow) return error.PopulatedPropertyRequiresClear;
            if (optionId != null and old == .array) {
                var remaining: V = .{ .array = std.array_list.Managed(V).init(a) };
                for (old.array.items) |item| if (item != .string or !std.mem.eql(u8, item.string, optionId.?)) try remaining.array.append(item);
                try v.object.put(propertyId, remaining);
            } else _ = v.object.swapRemove(propertyId);
            try result.appendSlice(a, markdown[cursor..t.start]);
            try result.appendSlice(a, try lineValues(a, markdown[t.start..t.end], v));
            cursor = t.end;
            count += 1;
        }
    }
    try result.appendSlice(a, markdown[cursor..]);
    return .{ .markdown = try result.toOwnedSlice(a), .count = count };
}
pub fn change(a: A, markdown: []const u8, args: []const []const u8) !productivity.Proposal {
    if (args.len < 2) return error.InvalidPropertyCommand;
    var items = try schema(a, markdown);
    var cleared: usize = 0;
    var body = markdown;
    if (std.mem.eql(u8, args[0], "add")) {
        if (args.len < 3 or args.len > 4) return error.InvalidPropertyCommand;
        try label(args[1]);
        for (items) |p| if (std.mem.eql(u8, p.name, args[1])) return error.DuplicateProperty;
        const k = try kind(args[2]);
        var opts: std.ArrayList(Option) = .empty;
        if (args.len == 4) {
            if (k != .single_select and k != .multi_select) return error.InvalidPropertyType;
            var names = std.mem.splitScalar(u8, args[3], ',');
            while (names.next()) |raw| {
                const n = std.mem.trim(u8, raw, " ");
                try label(n);
                for (opts.items) |o| if (std.mem.eql(u8, n, o.name)) return error.DuplicatePropertyOption;
                try opts.append(a, .{ .id = try newId(a), .name = n });
            }
        }
        const bigger = try a.alloc(Property, items.len + 1);
        @memcpy(bigger[0..items.len], items);
        bigger[items.len] = .{ .id = try newId(a), .name = args[1], .kind = k, .options = try opts.toOwnedSlice(a) };
        items = bigger;
    } else {
        const i = try findProperty(items, args[1]);
        const p = &items[i];
        if (p.kind == .member) return error.TeamMemberCatalogRequired;
        if (std.mem.eql(u8, args[0], "rename")) {
            if (args.len != 3) return error.InvalidPropertyCommand;
            try label(args[2]);
            for (items, 0..) |other, j| if (j != i and std.mem.eql(u8, other.name, args[2])) return error.DuplicateProperty;
            p.name = args[2];
        } else if (std.mem.eql(u8, args[0], "remove")) {
            if (args.len != 2) return error.InvalidPropertyCommand;
            const c = try clearValues(a, body, p.id, true, null);
            body = c.markdown;
            cleared = c.count;
            const smaller = try a.alloc(Property, items.len - 1);
            @memcpy(smaller[0..i], items[0..i]);
            @memcpy(smaller[i..], items[i + 1 ..]);
            items = smaller;
        } else if (std.mem.eql(u8, args[0], "type")) {
            if (args.len < 3 or args.len > 4) return error.InvalidPropertyCommand;
            const k = try kind(args[2]);
            if (k != p.kind) {
                const c = try clearValues(a, body, p.id, args.len == 4 and std.mem.eql(u8, args[3], "clear"), null);
                body = c.markdown;
                cleared = c.count;
                p.kind = k;
                p.options = &.{};
            }
        } else if (std.mem.eql(u8, args[0], "options")) {
            if (args.len < 4 or args.len > 6 or (p.kind != .single_select and p.kind != .multi_select)) return error.InvalidPropertyCommand;
            if (std.mem.eql(u8, args[2], "add")) {
                if (args.len != 4) return error.InvalidPropertyCommand;
                try label(args[3]);
                for (p.options) |o| if (std.mem.eql(u8, o.name, args[3])) return error.DuplicatePropertyOption;
                const bigger = try a.alloc(Option, p.options.len + 1);
                @memcpy(bigger[0..p.options.len], p.options);
                bigger[p.options.len] = .{ .id = try newId(a), .name = args[3] };
                p.options = bigger;
            } else {
                const oid = try option(p.*, args[3]);
                var oi: usize = 0;
                while (!std.mem.eql(u8, p.options[oi].id, oid)) oi += 1;
                if (std.mem.eql(u8, args[2], "rename")) {
                    if (args.len != 5) return error.InvalidPropertyCommand;
                    try label(args[4]);
                    for (p.options, 0..) |o, j| if (j != oi and std.mem.eql(u8, o.name, args[4])) return error.DuplicatePropertyOption;
                    p.options[oi].name = args[4];
                } else if (std.mem.eql(u8, args[2], "remove")) {
                    if (args.len > 5) return error.InvalidPropertyCommand;
                    const c = try clearValues(a, body, p.id, args.len == 5 and std.mem.eql(u8, args[4], "clear"), oid);
                    body = c.markdown;
                    cleared = c.count;
                    const smaller = try a.alloc(Option, p.options.len - 1);
                    @memcpy(smaller[0..oi], p.options[0..oi]);
                    @memcpy(smaller[oi..], p.options[oi + 1 ..]);
                    p.options = smaller;
                } else return error.InvalidPropertyCommand;
            }
        } else return error.InvalidPropertyCommand;
    }
    const after = try replaceSchema(a, body, items);
    _ = try schema(a, after);
    return .{ .markdown = after, .selected = cleared, .preview = try std.fmt.allocPrint(a, "Properties update; {d} task values cleared.\n{s}\n", .{ cleared, try json(a, items) }) };
}
fn matches(a: A, p: Property, wanted: V, found: V) !bool {
    if (p.kind == .number) {
        const l: f64 = switch (wanted) {
            .integer => @floatFromInt(wanted.integer),
            .float => wanted.float,
            else => return false,
        };
        const r: f64 = switch (found) {
            .integer => @floatFromInt(found.integer),
            .float => found.float,
            else => return false,
        };
        return l == r;
    }
    if (p.kind == .multi_select) {
        if (wanted != .array or found != .array) return false;
        for (wanted.array.items) |w| {
            var matched = false;
            for (found.array.items) |v| if (v == .string and w == .string and std.mem.eql(u8, v.string, w.string)) {
                matched = true;
                break;
            };
            if (!matched) return false;
        }
        return true;
    }
    return std.mem.eql(u8, try json(a, wanted), try json(a, found));
}
pub fn filter(a: A, markdown: []const u8, key: []const u8, input: []const u8) ![]const u8 {
    const items = try schema(a, markdown);
    const p = items[try findProperty(items, key)];
    const wanted = try typed(a, p, input);
    const tasks = try productivity.parse(a, markdown);
    var out: std.ArrayList(u8) = .empty;
    for (tasks) |t| {
        const v = try values(a, markdown[t.start..t.end]);
        if (v.object.get(p.id)) |found| if (try matches(a, p, wanted, found)) try out.appendSlice(a, try std.fmt.allocPrint(a, "{d}. [{s}] {s} / {s}\n", .{ t.number, if (t.completed) "x" else " ", t.group, try title(a, t.text) }));
    }
    return out.toOwnedSlice(a);
}

pub fn taskValues(a: A, markdown: []const u8, task: usize) !V {
    const t = try productivity.find(a, markdown, task);
    return values(a, markdown[t.start..t.end]);
}
pub fn title(a: A, text: []const u8) ![]const u8 {
    const s = try span(text, value_prefix);
    const clean = if (s) |old| try std.fmt.allocPrint(a, "{s}{s}", .{ text[0..old.start], text[old.end..] }) else text;
    const task_span = try span(clean, "<!-- doin:task=");
    const visible = if (task_span) |old| try std.fmt.allocPrint(a, "{s}{s}", .{ clean[0..old.start], clean[old.end..] }) else clean;
    return std.mem.trim(u8, reminders.title(visible), " \t\r\n");
}
pub fn summary(a: A, markdown: []const u8, task: usize) !?[]const u8 {
    const items = try schema(a, markdown);
    const v = try taskValues(a, markdown, task);
    var out: std.ArrayList(u8) = .empty;
    for (items) |p| if (v.object.get(p.id)) |value| {
        if (out.items.len > 0) try out.appendSlice(a, " · ");
        try out.appendSlice(a, p.name);
        try out.appendSlice(a, ": ");
        if (p.kind == .single_select and value == .string) {
            var found = false;
            for (p.options) |o| if (std.mem.eql(u8, o.id, value.string)) {
                try out.appendSlice(a, o.name);
                found = true;
                break;
            };
            if (!found) try out.appendSlice(a, "Unknown option");
        } else if (p.kind == .multi_select and value == .array) {
            for (value.array.items, 0..) |selected, n| {
                if (n > 0) try out.appendSlice(a, ", ");
                var found = false;
                if (selected == .string) for (p.options) |o| {
                    if (std.mem.eql(u8, o.id, selected.string)) {
                        try out.appendSlice(a, o.name);
                        found = true;
                        break;
                    }
                };
                if (!found) try out.appendSlice(a, "Unknown option");
            }
        } else if (p.kind == .member and value == .string) {
            var matched = false;
            for (p.members) |m| if (std.mem.eql(u8, m.id, value.string)) {
                try out.appendSlice(a, m.name);
                matched = true;
                break;
            };
            if (!matched) try out.appendSlice(a, "Former member");
        } else if (value == .string) try out.appendSlice(a, value.string) else try out.appendSlice(a, try json(a, value));
    };
    return if (out.items.len == 0) null else try out.toOwnedSlice(a);
}
pub fn setAssignee(a: A, markdown: []const u8, task: usize, accountId: []const u8, catalog: []const Member) !productivity.Proposal {
    const reserved = "00000000000000000000000000000001";
    var items = try schema(a, markdown);
    var found = false;
    for (items) |p| {
        if (std.mem.eql(u8, p.id, reserved)) {
            if (p.kind != .member or !std.mem.eql(u8, p.name, "Assignee")) return error.ReservedPropertyConflict;
            found = true;
        } else if (std.mem.eql(u8, p.name, "Assignee")) return error.ReservedPropertyConflict;
    }
    var body = markdown;
    if (!found) {
        const bigger = try a.alloc(Property, items.len + 1);
        @memcpy(bigger[0..items.len], items);
        bigger[items.len] = .{ .id = reserved, .name = "Assignee", .kind = .member };
        items = bigger;
        body = try replaceSchema(a, body, items);
    }
    var selected: ?Member = null;
    for (catalog) |m| if (std.mem.eql(u8, m.id, accountId)) {
        selected = m;
        break;
    };
    const member = selected orelse return error.InvalidTeamAssignee;
    for (items) |*p| if (std.mem.eql(u8, p.id, reserved)) {
        var cached = false;
        for (p.members) |*m| if (std.mem.eql(u8, m.id, accountId)) {
            m.name = member.name;
            cached = true;
            break;
        };
        if (!cached) {
            const bigger = try a.alloc(Member, p.members.len + 1);
            @memcpy(bigger[0..p.members.len], p.members);
            bigger[p.members.len] = member;
            p.members = bigger;
        }
        break;
    };
    body = try replaceSchema(a, body, items);
    _ = try schema(a, body);
    const chosen = try productivity.find(a, body, task);
    const raw = body[chosen.start..chosen.end];
    const task_prefix = "<!-- doin:task=";
    if (std.mem.indexOf(u8, raw, task_prefix)) |start| {
        const end = std.mem.indexOfPos(u8, raw, start + task_prefix.len, " -->") orelse return error.InvalidPropertyMetadata;
        if (!identity(raw[start + task_prefix.len .. end]) or std.mem.indexOfPos(u8, raw, end + 4, task_prefix) != null) return error.InvalidPropertyMetadata;
    } else {
        const end = if (std.mem.endsWith(u8, raw, "\r\n")) raw.len - 2 else if (std.mem.endsWith(u8, raw, "\n")) raw.len - 1 else raw.len;
        const insert = std.mem.indexOf(u8, raw[0..end], "<!-- doin:id=") orelse end;
        body = try std.fmt.allocPrint(a, "{s}{s} <!-- doin:task={s} --> {s}{s}", .{ body[0..chosen.start], raw[0..insert], try newId(a), raw[insert..], body[chosen.end..] });
    }
    return setMember(a, body, task, reserved, accountId, catalog);
}
