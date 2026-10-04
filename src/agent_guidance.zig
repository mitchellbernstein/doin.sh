const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform.zig");
const reminders = @import("reminders.zig");
const A = std.mem.Allocator;
const begin = "<!-- doin:guidance:begin -->";
const end = "<!-- doin:guidance:end -->";
pub const Change = struct { path: []const u8, before: ?[]const u8, after: []const u8, preview: []const u8 };
pub fn protocol(a: A) ![]const u8 {
    return (try std.json.parseFromSlice(struct { instructions: []const u8 }, a, @embedFile("agent_protocol.json"), .{ .allocate = .alloc_always })).value.instructions;
}

fn same(left: []const u8, right: []const u8) bool {
    return if (builtin.os.tag == .windows) std.ascii.eqlIgnoreCase(left, right) else std.mem.eql(u8, left, right);
}
fn directory(a: A, path: []const u8) ![]const u8 {
    const real = try std.fs.cwd().realpathAlloc(a, path);
    if (!same(real, path)) return error.GuidanceStorageChanged;
    return real;
}
fn within(a: A, root: []const u8, folder: []const u8) !void {
    _ = try directory(a, root);
    _ = try directory(a, folder);
    const relative = try std.fs.path.relative(a, root, folder);
    if (std.fs.path.isAbsolute(relative) or same(relative, "..") or std.mem.startsWith(u8, relative, "../") or std.mem.startsWith(u8, relative, "..\\")) return error.GuidanceOutsideLibrary;
}
fn read(a: A, path: []const u8) !?[]const u8 {
    const real = std.fs.cwd().realpathAlloc(a, path) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    if (!same(real, path)) return error.GuidanceFileLink;
    return try std.fs.cwd().readFileAlloc(a, path, 65536);
}
fn merged(a: A, before: ?[]const u8, body: []const u8) ![]const u8 {
    const block = try std.fmt.allocPrint(a, "{s}\n{s}\n{s}\n", .{ begin, body, end });
    const original = before orelse return block;
    var lines = std.mem.splitScalar(u8, original, '\n');
    var fence: reminders.FenceTracker = .{};
    var offset: usize = 0;
    var start: ?usize = null;
    var finish: ?usize = null;
    while (lines.next()) |line| {
        defer offset += line.len + 1;
        if (fence.feed(std.mem.trim(u8, line, " \t\r"))) continue;
        const clean = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, clean, begin)) {
            if (start != null or finish != null) return error.InvalidGuidanceMarkers;
            start = offset;
        } else if (std.mem.eql(u8, clean, end)) {
            if (start == null or finish != null) return error.InvalidGuidanceMarkers;
            finish = @min(original.len, offset + line.len + 1);
        }
    }
    if ((start == null) != (finish == null)) return error.InvalidGuidanceMarkers;
    if (start) |from| return std.fmt.allocPrint(a, "{s}{s}{s}", .{ original[0..from], block, original[finish.?..] });
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ original, if (original.len == 0 or std.mem.endsWith(u8, original, "\n")) "" else "\n", block });
}
fn add(a: A, changes: *std.ArrayList(Change), folder: []const u8, filename: []const u8, body: []const u8) !void {
    const path = try std.fs.path.join(a, &.{ folder, filename });
    const before = try read(a, path);
    const after = try merged(a, before, body);
    if (after.len > 65536) return error.GuidanceTooLarge;
    try changes.append(a, .{ .path = path, .before = before, .after = after, .preview = try std.fmt.allocPrint(a, "{s}: {s} doin guidance block; user text outside markers stays.\n{s}\n", .{ filename, if (before == null) "Create" else "Update", after }) });
}
pub fn plan(a: A, root: []const u8, folder: []const u8, claude: bool) ![]Change {
    try within(a, root, folder);
    var changes: std.ArrayList(Change) = .empty;
    try add(a, &changes, root, "AGENTS.md", try protocol(a));
    if (claude) try add(a, &changes, root, "CLAUDE.md", "@AGENTS.md\n");
    if (!same(root, folder)) {
        try add(a, &changes, folder, "AGENTS.md", try protocol(a));
        if (claude) try add(a, &changes, folder, "CLAUDE.md", "@AGENTS.md\n");
    }
    return changes.toOwnedSlice(a);
}
fn current(a: A, change: Change) !void {
    const actual = try read(a, change.path);
    if ((actual == null) != (change.before == null)) return error.GuidanceChanged;
    if (actual) |bytes| if (!std.mem.eql(u8, bytes, change.before.?)) return error.GuidanceChanged;
}
pub fn commit(a: A, root: []const u8, changes: []const Change) !void {
    _ = try directory(a, root);
    const lock = try std.fs.cwd().createFile(try std.fs.path.join(a, &.{ root, ".doin-guidance.lock" }), .{ .truncate = false, .mode = 0o600 });
    defer lock.close();
    if (!try platform.tryLockExclusive(lock)) return error.GuidanceBusy;
    for (changes) |change| {
        try within(a, root, std.fs.path.dirname(change.path) orelse return error.GuidanceOutsideLibrary);
        try current(a, change);
    }
    for (changes) |change| {
        try within(a, root, std.fs.path.dirname(change.path).?);
        if (change.before == null) {
            const file = try std.fs.cwd().createFile(change.path, .{ .exclusive = true, .mode = 0o600 });
            defer file.close();
            try file.writeAll(change.after);
            try file.sync();
        } else {
            var random: [8]u8 = undefined;
            std.crypto.random.bytes(&random);
            const temp = try std.fmt.allocPrint(a, "{s}.{x}.tmp", .{ change.path, random });
            defer std.fs.cwd().deleteFile(temp) catch {};
            const mode = (try std.fs.cwd().statFile(change.path)).mode;
            const file = try std.fs.cwd().createFile(temp, .{ .exclusive = true, .mode = mode });
            defer file.close();
            try file.writeAll(change.after);
            try file.sync();
            try within(a, root, std.fs.path.dirname(change.path).?);
            try current(a, change);
            try std.fs.cwd().rename(temp, change.path);
        }
    }
}
pub fn ensure(a: A, root: []const u8, folder: []const u8) !void {
    try within(a, root, folder);
    const dirs: []const []const u8 = if (same(root, folder)) &[_][]const u8{root} else &[_][]const u8{ root, folder };
    for (dirs) |dir| {
        const path = try std.fs.path.join(a, &.{ dir, "AGENTS.md" });
        const file = std.fs.cwd().createFile(path, .{ .exclusive = true, .mode = 0o600 }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        defer file.close();
        try file.writeAll(try merged(a, null, try protocol(a)));
        try file.sync();
    }
}
pub fn status(a: A, root: []const u8, folder: []const u8) ![]const u8 {
    try within(a, root, folder);
    var out: std.ArrayList(u8) = .empty;
    const dirs: []const []const u8 = if (same(root, folder)) &[_][]const u8{root} else &[_][]const u8{ root, folder };
    for (dirs) |dir| for ([_][]const u8{ "AGENTS.md", "CLAUDE.md" }) |name| {
        const bytes = try read(a, try std.fs.path.join(a, &.{ dir, name }));
        try out.appendSlice(a, try std.fmt.allocPrint(a, "{s}: {s}\n", .{ name, if (bytes == null) "missing" else if (std.mem.indexOf(u8, bytes.?, begin) != null) "doin block + user-owned guidance" else "user-owned guidance" }));
    };
    return out.toOwnedSlice(a);
}
