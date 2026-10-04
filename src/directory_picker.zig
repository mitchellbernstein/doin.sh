const std = @import("std");
const terminal = @import("terminal.zig");
const A = std.mem.Allocator;
const Entry = struct { path: []const u8, label: []const u8 };
pub fn valid(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    var folder = std.fs.openDirAbsolute(path, .{}) catch return false;
    folder.close();
    return true;
}
fn less(_: void, lhs: Entry, rhs: Entry) bool {
    return std.ascii.lessThanIgnoreCase(lhs.label, rhs.label);
}
fn entriesIn(a: A, path: []const u8) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    var folder = try std.fs.openDirAbsolute(path, .{ .iterate = true });
    defer folder.close();
    var iterator = folder.iterate();
    while (try iterator.next()) |entry| {
        const child = try std.fs.path.join(a, &.{ path, entry.name });
        if (valid(child)) try entries.append(a, .{ .path = child, .label = try a.dupe(u8, entry.name) });
    }
    std.mem.sort(Entry, entries.items, {}, less);
    return entries.toOwnedSlice(a);
}
pub fn browser(a: A, start: []const u8) !?[]const u8 {
    var history: std.ArrayList([]const u8) = .empty;
    defer {
        for (history.items) |path| a.free(path);
        history.deinit(a);
    }
    try history.append(a, try a.dupe(u8, start));
    var index: usize = 0;
    var state: terminal.DirectoryState = .{ .allocator = a };
    defer state.query.deinit(a);
    while (true) {
        const current = history.items[index];
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const scratch = arena.allocator();
        const entries = entriesIn(scratch, current) catch |err| {
            if (err == error.OutOfMemory) return err;
            try terminal.output("Cannot open this folder.\n");
            if (index > 0) {
                index -= 1;
                continue;
            }
            return null;
        };
        var options: std.ArrayList(terminal.ModelOption) = .empty;
        try options.append(scratch, .{ .value = "select", .label = "Use this folder", .detail = current });
        if (std.fs.path.dirname(current)) |parent| try options.append(scratch, .{ .value = parent, .label = "..", .detail = "Parent folder" });
        for (entries) |entry| try options.append(scratch, .{ .value = entry.path, .label = entry.label, .detail = "Folder" });
        const result = terminal.modelPick(scratch, .{ .name = current, .prefix = "", .suffix = "", .placeholder = "Type to filter folders", .options = options.items, .explanation = "↑↓ move · →/Enter open · ← parent · Alt+←/→ history · Esc cancel", .selection_only = true, .directory_mode = true, .directory_state = &state }) catch |err| {
            if (err == error.PickerResized or err == error.InvalidModelChoice) continue;
            if (err == error.PickerCancelled) return null;
            return err;
        };
        if (result.navigation == .back or result.navigation == .forward) {
            const next = if (result.navigation == .back) index -| 1 else @min(index + 1, history.items.len - 1);
            if (next != index) {
                index = next;
                state.query.clearRetainingCapacity();
                state.selected = 0;
            }
            continue;
        }
        if (std.mem.eql(u8, result.value, "select")) {
            if (result.navigation == .open) continue;
            if (!valid(current)) {
                try terminal.output("Cannot open this folder.\n");
                continue;
            }
            return try a.dupe(u8, current);
        }
        const destination = if (result.navigation == .parent) std.fs.path.dirname(current) orelse continue else result.value;
        _ = entriesIn(scratch, destination) catch |err| {
            if (err == error.OutOfMemory) return err;
            try terminal.output("Cannot open this folder.\n");
            continue;
        };
        const copied = try a.dupe(u8, destination);
        errdefer a.free(copied);
        for (history.items[index + 1 ..]) |path| a.free(path);
        history.shrinkRetainingCapacity(index + 1);
        try history.append(a, copied);
        index += 1;
        state.query.clearRetainingCapacity();
        state.selected = 0;
    }
}
pub fn select(a: A, start: []const u8) !?[]const u8 {
    if (!valid(start)) return error.InvalidDirectorySelection;
    return browser(a, start);
}
