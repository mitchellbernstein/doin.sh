const std = @import("std");
const reminders = @import("reminders.zig");
const Allocator = std.mem.Allocator;
pub const Task = struct { number: usize, start: usize, end: usize, text: []const u8, completed: bool, group: []const u8 };
pub const Proposal = struct { markdown: []const u8, selected: usize, preview: []const u8 };
pub fn parse(a: Allocator, markdown: []const u8) ![]Task {
    var tasks: std.ArrayList(Task) = .empty;
    var lines = std.mem.splitScalar(u8, markdown, '\n');
    var offset: usize = 0;
    var fences: reminders.FenceTracker = .{};
    var group: []const u8 = "Ungrouped";
    while (lines.next()) |raw| {
        const end = @min(markdown.len, offset + raw.len + 1);
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!fences.feed(line)) {
            if (std.mem.startsWith(u8, line, "#")) {
                const title = std.mem.trimStart(u8, line, "# \t");
                if (title.len > 0) group = reminders.title(title);
            } else if (line.len >= 6 and (line[0] == '-' or line[0] == '*') and std.mem.eql(u8, line[1..3], " [") and line[4] == ']' and line[5] == ' ' and (line[3] == ' ' or line[3] == 'x' or line[3] == 'X')) {
                try tasks.append(a, .{ .number = tasks.items.len + 1, .start = offset, .end = end, .text = reminders.title(line[6..]), .completed = line[3] != ' ', .group = group });
            }
        }
        offset = end;
    }
    return tasks.toOwnedSlice(a);
}
pub fn delete(a: Allocator, markdown: []const u8, selector: []const u8) !Proposal {
    const tasks = try parse(a, markdown);
    defer a.free(tasks);
    const chosen = try a.alloc(bool, tasks.len);
    defer a.free(chosen);
    @memset(chosen, false);
    if (std.mem.eql(u8, selector, "all") or std.mem.eql(u8, selector, "done") or std.mem.eql(u8, selector, "open")) {
        for (tasks, 0..) |t, i| chosen[i] = std.mem.eql(u8, selector, "all") or (t.completed == std.mem.eql(u8, selector, "done"));
    } else if (std.mem.startsWith(u8, selector, "group:")) {
        const group = selector[6..];
        if (group.len == 0) return error.InvalidTaskSelector;
        for (tasks, 0..) |t, i| chosen[i] = std.mem.eql(u8, group, t.group);
    } else {
        var ids = std.mem.splitScalar(u8, selector, ',');
        while (ids.next()) |id| {
            const n = std.fmt.parseInt(usize, std.mem.trim(u8, id, " "), 10) catch return error.InvalidTaskSelector;
            if (n == 0 or n > tasks.len) return error.TaskNotFound;
            chosen[n - 1] = true;
        }
    }
    var result: std.ArrayList(u8) = .empty;
    var preview: std.ArrayList(u8) = .empty;
    var cursor: usize = 0;
    var count: usize = 0;
    for (tasks, chosen) |t, selected| if (selected) {
        try result.appendSlice(a, markdown[cursor..t.start]);
        cursor = t.end;
        const row = try std.fmt.allocPrint(a, "{d}. [{s}] {s} / {s}\n", .{ t.number, if (t.completed) "x" else " ", t.group, t.text });
        defer a.free(row);
        try preview.appendSlice(a, row);
        count += 1;
    };
    if (count == 0) return error.TaskNotFound;
    try result.appendSlice(a, markdown[cursor..]);
    return .{ .markdown = try result.toOwnedSlice(a), .selected = count, .preview = try preview.toOwnedSlice(a) };
}
fn field(text: []const u8, name: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, text, name) orelse return null;
    const rest = text[at + name.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ')') orelse return null;
    return rest[0..end];
}
fn priority(t: Task) u8 {
    const value = field(t.text, "@priority(") orelse return 3;
    return if (std.mem.eql(u8, value, "high")) 0 else if (std.mem.eql(u8, value, "medium")) 1 else if (std.mem.eql(u8, value, "low")) 2 else 3;
}
fn due(text: []const u8) []const u8 {
    const value = field(text, "@due(") orelse return "9999-99-99";
    if (value.len != 10 or value[4] != '-' or value[7] != '-') return "9999-99-99";
    for (value, 0..) |c, i| if (i != 4 and i != 7 and !std.ascii.isDigit(c)) {
        return "9999-99-99";
    };
    const year = std.fmt.parseInt(u16, value[0..4], 10) catch return "9999-99-99";
    const month = std.fmt.parseInt(u8, value[5..7], 10) catch return "9999-99-99";
    const day = std.fmt.parseInt(u8, value[8..10], 10) catch return "9999-99-99";
    if (year == 0 or month == 0 or month > 12) return "9999-99-99";
    const days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const leap = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
    const limit = days[month - 1] + @as(u8, if (month == 2 and leap) 1 else 0);
    return if (day > 0 and day <= limit) value else "9999-99-99";
}
fn before(_: void, l: Task, r: Task) bool {
    if (priority(l) != priority(r)) return priority(l) < priority(r);
    const ld = due(l.text);
    const rd = due(r.text);
    const order = std.mem.order(u8, ld, rd);
    return if (order == .eq) l.number < r.number else order == .lt;
}
pub fn report(a: Allocator, markdown: []const u8, kind: []const u8) ![]const u8 {
    const tasks = try parse(a, markdown);
    defer a.free(tasks);
    if (std.mem.eql(u8, kind, "prioritize")) std.mem.sort(Task, tasks, {}, before);
    var result: std.ArrayList(u8) = .empty;
    try result.appendSlice(a, if (std.mem.eql(u8, kind, "prioritize")) "Priority preview\nUse @priority(high|medium|low) and @due(YYYY-MM-DD) to set the order.\n" else "Open tasks\n");
    for (tasks) |t| if (!t.completed) {
        const row = try std.fmt.allocPrint(a, "{d}. [ ] {s} / {s}\n", .{ t.number, t.group, t.text });
        defer a.free(row);
        try result.appendSlice(a, row);
    };
    return result.toOwnedSlice(a);
}
pub fn groupCount(a: Allocator, markdown: []const u8) !usize {
    const tasks = try parse(a, markdown);
    defer a.free(tasks);
    var count: usize = 0;
    for (tasks, 0..) |t, i| {
        var seen = false;
        for (tasks[0..i]) |earlier| if (std.mem.eql(u8, t.group, earlier.group)) {
            seen = true;
            break;
        };
        if (!seen) count += 1;
    }
    return count;
}
pub fn chart(a: Allocator, markdown: []const u8, selected: usize) ![]const u8 {
    const tasks = try parse(a, markdown);
    defer a.free(tasks);
    var result: std.ArrayList(u8) = .empty;
    try result.appendSlice(a, "Completion by group\n");
    var group_index: usize = 0;
    for (tasks, 0..) |t, i| {
        var seen = false;
        for (tasks[0..i]) |earlier| if (std.mem.eql(u8, t.group, earlier.group)) {
            seen = true;
            break;
        };
        if (seen) continue;
        var done: usize = 0;
        var total: usize = 0;
        for (tasks) |item| if (std.mem.eql(u8, item.group, t.group)) {
            total += 1;
            done += @intFromBool(item.completed);
        };
        var bar: [20]u8 = undefined;
        const filled = done * bar.len / total;
        for (&bar, 0..) |*cell, j| cell.* = if (j < filled) '#' else '.';
        const row = try std.fmt.allocPrint(a, "{s} {s} [{s}] {d}/{d} ({d}%)\n", .{ if (group_index == selected) ">" else " ", t.group, &bar, done, total, done * 100 / total });
        defer a.free(row);
        try result.appendSlice(a, row);
        group_index += 1;
    }
    if (tasks.len == 0) try result.appendSlice(a, "No tasks yet.\n");
    return result.toOwnedSlice(a);
}

pub fn status(t: Task) []const u8 {
    if (t.completed) return "done";
    const value = field(t.text, "@status(") orelse return "todo";
    return if (std.mem.eql(u8, value, "done") or std.mem.eql(u8, value, "todo")) "todo" else value;
}
pub fn find(a: Allocator, markdown: []const u8, number: usize) !Task {
    const tasks = try parse(a, markdown);
    defer a.free(tasks);
    if (number == 0 or number > tasks.len) return error.TaskNotFound;
    return tasks[number - 1];
}
pub fn mark(a: Allocator, markdown: []const u8, number: usize, value: []const u8) !Proposal {
    if (!try hasStatus(a, markdown, value)) return error.InvalidTaskStatus;
    const t = try find(a, markdown, number);
    const raw = markdown[t.start..t.end];
    const newline = if (std.mem.endsWith(u8, raw, "\r\n")) "\r\n" else if (std.mem.endsWith(u8, raw, "\n")) "\n" else "";
    const line = raw[0 .. raw.len - newline.len];
    const trimmed = std.mem.trimStart(u8, line, " \t");
    const checkbox = line.len - trimmed.len + 3;
    const visible = reminders.title(line);
    var edited: std.ArrayList(u8) = .empty;
    defer edited.deinit(a);
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, visible, cursor, "@status(")) |start| {
        const end = std.mem.indexOfScalarPos(u8, visible, start, ')') orelse break;
        const tag = visible[start + 8 .. end];
        if (validStatus(tag)) {
            try edited.appendSlice(a, visible[cursor..start]);
            cursor = end + 1;
        } else {
            try edited.appendSlice(a, visible[cursor .. end + 1]);
            cursor = end + 1;
        }
    }
    try edited.appendSlice(a, visible[cursor..]);
    edited.items[checkbox] = if (std.mem.eql(u8, value, "done")) 'x' else ' ';
    while (edited.items.len > 0 and edited.items[edited.items.len - 1] == ' ') _ = edited.pop();
    if (!std.mem.eql(u8, value, "todo") and !std.mem.eql(u8, value, "done")) {
        const tag = try std.fmt.allocPrint(a, " @status({s})", .{value});
        defer a.free(tag);
        try edited.appendSlice(a, tag);
    }
    try edited.appendSlice(a, line[visible.len..]);
    try edited.appendSlice(a, newline);
    const after = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ markdown[0..t.start], edited.items, markdown[t.end..] });
    return .{ .markdown = after, .selected = 1, .preview = try std.fmt.allocPrint(a, "{d}. {s} → {s}\n", .{ number, t.text, value }) };
}
fn dateLimit(a: Allocator, scope: []const u8) ![]const u8 {
    return @import("calendar.zig").dateLimit(a, scope);
}
pub fn today(a: Allocator) ![]const u8 {
    return dateLimit(a, "today");
}
pub fn filter(a: Allocator, markdown: []const u8, property: []const u8, value: []const u8) ![]const u8 {
    const tasks = try parse(a, markdown);
    defer a.free(tasks);
    const prop = std.meta.stringToEnum(enum { due, status, priority, group, text }, property) orelse return error.InvalidTaskFilter;
    if (value.len == 0) return error.InvalidTaskFilter;
    var limit: ?[]const u8 = null;
    if (prop == .due) limit = try dateLimit(a, value);
    defer if (limit) |v| a.free(v);
    if (prop == .status and !try hasStatus(a, markdown, value)) return error.InvalidTaskStatus;
    if (prop == .priority and !std.mem.eql(u8, value, "high") and !std.mem.eql(u8, value, "medium") and !std.mem.eql(u8, value, "low")) return error.InvalidTaskFilter;
    var result: std.ArrayList(u8) = .empty;
    const heading = if (limit) |v| try std.fmt.allocPrint(a, "Due {s} — overdue through {s} (local calendar)\n", .{ value, v }) else try std.fmt.allocPrint(a, "Tasks — {s}: {s}\n", .{ property, value });
    defer a.free(heading);
    try result.appendSlice(a, heading);
    var count: usize = 0;
    for (tasks) |t| {
        const matches = switch (prop) {
            .due => !t.completed and std.mem.order(u8, due(t.text), limit.?) != .gt,
            .status => std.mem.eql(u8, status(t), value),
            .priority => std.mem.eql(u8, field(t.text, "@priority(") orelse "", value),
            .group => std.mem.eql(u8, t.group, value),
            .text => std.mem.indexOf(u8, t.text, value) != null,
        };
        if (!matches) continue;
        const row = try std.fmt.allocPrint(a, "{d}. [{s}] {s} / {s}\n", .{ t.number, if (t.completed) "x" else " ", t.group, t.text });
        defer a.free(row);
        try result.appendSlice(a, row);
        count += 1;
    }
    if (count == 0) {
        try result.appendSlice(a, "No matching tasks.\n");
        if (prop == .due) {
            const example = try today(a);
            defer a.free(example);
            const hint = try std.fmt.allocPrint(a, "Add @due({s}) to a task to give it a date.\n", .{example});
            defer a.free(hint);
            try result.appendSlice(a, hint);
        }
    }
    return result.toOwnedSlice(a);
}

const registry_prefix = "<!-- doin:statuses=";
const Registry = struct { names: []const u8 = "doing,blocked", start: usize = 0, end: usize = 0 };
fn validStatus(name: []const u8) bool {
    if (name.len == 0 or name.len > 32 or name[0] < 'a' or name[0] > 'z') return false;
    for (name) |c| if (!(c >= 'a' and c <= 'z') and !(c >= '0' and c <= '9') and c != '-') return false;
    return true;
}
fn registry(markdown: []const u8) !Registry {
    var result: Registry = .{};
    var lines = std.mem.splitScalar(u8, markdown, '\n');
    var fences: reminders.FenceTracker = .{};
    var offset: usize = 0;
    var found = false;
    while (lines.next()) |raw| {
        const text = std.mem.trim(u8, raw, " \t\r");
        if (!fences.feed(text) and std.mem.startsWith(u8, text, registry_prefix)) {
            if (found or !std.mem.endsWith(u8, text, " -->")) return error.InvalidStatusRegistry;
            result = .{ .names = text[registry_prefix.len .. text.len - 4], .start = offset, .end = @min(markdown.len, offset + raw.len + 1) };
            var names = std.mem.splitScalar(u8, result.names, ',');
            var position: usize = 0;
            while (names.next()) |name| {
                if (result.names.len == 0) break;
                if (!validStatus(name) or std.mem.eql(u8, name, "todo") or std.mem.eql(u8, name, "done")) return error.InvalidStatusRegistry;
                var previous = std.mem.splitScalar(u8, result.names[0..position], ',');
                while (previous.next()) |earlier| if (std.mem.eql(u8, earlier, name)) return error.InvalidStatusRegistry;
                position += name.len + 1;
            }
            found = true;
        }
        offset = @min(markdown.len, offset + raw.len + 1);
    }
    return result;
}
pub fn hasStatus(a: Allocator, markdown: []const u8, name: []const u8) !bool {
    _ = a;
    if (!validStatus(name)) return false;
    const r = try registry(markdown);
    if (std.mem.eql(u8, name, "todo") or std.mem.eql(u8, name, "done")) return true;
    var names = std.mem.splitScalar(u8, r.names, ',');
    while (names.next()) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}
pub fn statuses(a: Allocator, markdown: []const u8) ![]const u8 {
    const r = try registry(markdown);
    var result: std.ArrayList(u8) = .empty;
    try result.appendSlice(a, "Task statuses\n  todo\n  done\n");
    var names = std.mem.splitScalar(u8, r.names, ',');
    while (names.next()) |name| if (name.len > 0) {
        const row = try std.fmt.allocPrint(a, "  {s}\n", .{name});
        defer a.free(row);
        try result.appendSlice(a, row);
    };
    return result.toOwnedSlice(a);
}
pub fn changeStatus(a: Allocator, markdown: []const u8, action: []const u8, name: []const u8, replacement: []const u8) !Proposal {
    const add = std.mem.eql(u8, action, "add");
    const rename = std.mem.eql(u8, action, "rename");
    const remove = std.mem.eql(u8, action, "remove");
    if ((add and replacement.len > 0) or (!add and !rename and !remove) or !validStatus(name)) return error.InvalidTaskStatus;
    if (std.mem.eql(u8, name, "todo") or std.mem.eql(u8, name, "done")) return error.ProtectedTaskStatus;
    const exists = try hasStatus(a, markdown, name);
    if ((add and exists) or (!add and !exists)) return error.InvalidTaskStatus;
    if (rename and (!validStatus(replacement) or try hasStatus(a, markdown, replacement))) return error.InvalidTaskStatus;
    if (remove and replacement.len > 0 and (!try hasStatus(a, markdown, replacement) or std.mem.eql(u8, name, replacement))) return error.InvalidTaskStatus;
    const tasks = try parse(a, markdown);
    defer a.free(tasks);
    var after: []const u8 = markdown;
    var changed: usize = 0;
    var i = tasks.len;
    while (i > 0) {
        i -= 1;
        const t = tasks[i];
        const old_tag = try std.fmt.allocPrint(a, "@status({s})", .{name});
        defer a.free(old_tag);
        const raw = after[t.start..t.end];
        if (std.mem.indexOf(u8, raw, old_tag) == null) continue;
        if (remove and replacement.len == 0) return error.TaskStatusInUse;
        if (add) continue;
        const destination = replacement;
        const tag = if (std.mem.eql(u8, destination, "todo") or std.mem.eql(u8, destination, "done")) "" else try std.fmt.allocPrint(a, "@status({s})", .{destination});
        var replaced: std.ArrayList(u8) = .empty;
        defer replaced.deinit(a);
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, raw, cursor, old_tag)) |at| {
            try replaced.appendSlice(a, raw[cursor..at]);
            try replaced.appendSlice(a, tag);
            cursor = at + old_tag.len;
        }
        try replaced.appendSlice(a, raw[cursor..]);
        if (std.mem.eql(u8, destination, "done")) {
            const checkbox = raw.len - std.mem.trimStart(u8, raw, " \t").len + 3;
            replaced.items[checkbox] = 'x';
        }
        after = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ after[0..t.start], replaced.items, after[t.end..] });
        changed += 1;
    }
    const r = try registry(after);
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(a);
    var existing = std.mem.splitScalar(u8, r.names, ',');
    while (existing.next()) |item| {
        if (item.len == 0 or (remove and std.mem.eql(u8, item, name))) continue;
        if (names.items.len > 0) try names.append(a, ',');
        try names.appendSlice(a, if (rename and std.mem.eql(u8, item, name)) replacement else item);
    }
    if (add) {
        if (names.items.len > 0) try names.append(a, ',');
        try names.appendSlice(a, name);
    }
    const newline = if (std.mem.indexOf(u8, markdown, "\r\n") != null) "\r\n" else "\n";
    const declaration = try std.fmt.allocPrint(a, "{s}{s} -->{s}", .{ registry_prefix, names.items, newline });
    const final_doc = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ after[0..r.start], declaration, after[r.end..] });
    return .{ .markdown = final_doc, .selected = changed, .preview = try std.fmt.allocPrint(a, "{s} status {s}{s}{s}; {d} task(s) updated.\n", .{ action, name, if (replacement.len > 0) " → " else "", replacement, changed }) };
}
