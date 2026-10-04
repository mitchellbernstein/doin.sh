const std = @import("std");
const platform = @import("platform.zig");
const A = std.mem.Allocator;
pub const Template = enum { simple, projects, areas };
pub const Folder = struct { id: []const u8, parent_id: ?[]const u8, name: []const u8, path: []const u8 };
pub const Metadata = struct { id: []const u8, parent_id: ?[]const u8, name: []const u8 };
const Identity = struct { id: []const u8 };
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn validName(name: []const u8) !void {
    if (std.mem.trim(u8, name, " \t\r\n").len == 0 or name.len > 120 or same(name, ".") or same(name, "..") or name[0] == '.') return error.InvalidFolderName;
    if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidFolderName;
    for (name) |c| if (c < 32 or c == 127 or c == '/' or c == '\\') return error.InvalidFolderName;
    if (name[name.len - 1] == '.' or name[name.len - 1] == ' ' or name[0] == ' ') return error.InvalidFolderName;
    for (name) |c| if (std.mem.indexOfScalar(u8, "<>:\"|?*", c) != null) return error.InvalidFolderName;
    const stem = name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len];
    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9" }) |reserved| if (std.ascii.eqlIgnoreCase(stem, reserved)) return error.InvalidFolderName;
}
fn metadataIndex(items: []const Metadata, id: []const u8) ?usize {
    for (items, 0..) |item, i| if (same(item.id, id)) return i;
    return null;
}
fn metadataPaths(a: A, root: []const u8, items: []const Metadata, root_id: []const u8) ![][]const u8 {
    if (items.len == 0 or items.len > 4096) return error.InvalidFolderTree;
    const paths = try a.alloc([]const u8, items.len);
    @memset(paths, "");
    const root_index = metadataIndex(items, root_id) orelse return error.InvalidFolderTree;
    if (items[root_index].parent_id != null) return error.InvalidFolderTree;
    paths[root_index] = root;
    for (items, 0..) |item, i| {
        if (item.id.len != 32) return error.InvalidFolderIdentity;
        for (item.id) |ch| if (!std.ascii.isHex(ch)) return error.InvalidFolderIdentity;
        for (items[0..i]) |prior| if (same(prior.id, item.id)) return error.DuplicateFolderIdentity;
        if (i == root_index) continue;
        try validName(item.name);
        const parent = item.parent_id orelse return error.InvalidFolderTree;
        if (metadataIndex(items, parent) == null) return error.InvalidFolderTree;
    }
    var count: usize = 1;
    while (count < items.len) {
        const before = count;
        for (items, 0..) |item, i| {
            if (paths[i].len > 0) continue;
            const parent = metadataIndex(items, item.parent_id.?) orelse return error.InvalidFolderTree;
            if (paths[parent].len == 0) continue;
            paths[i] = try std.fs.path.join(a, &.{ paths[parent], item.name });
            count += 1;
        }
        if (before == count) return error.FolderCycle;
    }
    return paths;
}
/// Import metadata only. No node deletion and no document replacement.
pub fn apply(a: A, root: []const u8, incoming: []const Metadata) !void {
    const canonical = try std.fs.cwd().realpathAlloc(a, root);
    if (!same(canonical, root)) return error.FolderSymlink;
    const lock = try lockRoot(a, root);
    defer lock.close();
    const before = try list(a, root);
    const target = try metadataPaths(a, root, incoming, before[0].id);
    for (before) |item| if (metadataIndex(incoming, item.id) == null) return error.RemoteTreeRemovedLocalFolder;
    // Probe the actual filesystem's case/Unicode equivalence before modifying managed nodes.
    var nonce: [8]u8 = undefined;
    std.crypto.random.bytes(&nonce);
    const probe = try std.fs.path.join(a, &.{ root, try std.fmt.allocPrint(a, ".doin-name-check-{x}", .{nonce}) });
    try std.fs.cwd().makeDir(probe);
    defer std.fs.cwd().deleteTree(probe) catch {};
    if (@import("builtin").os.tag == .windows) try platform.privateFile(a, probe) else {
        var private = try std.fs.cwd().openDir(probe, .{ .iterate = true });
        defer private.close();
        try private.chmod(0o700);
    }
    const probe_paths = try metadataPaths(a, probe, incoming, before[0].id);
    const made = try a.alloc(bool, incoming.len);
    @memset(made, false);
    made[metadataIndex(incoming, before[0].id).?] = true;
    var count: usize = 1;
    while (count < incoming.len) {
        for (incoming, 0..) |item, i| {
            if (made[i]) continue;
            if (!made[metadataIndex(incoming, item.parent_id.?).?]) continue;
            std.fs.cwd().makeDir(probe_paths[i]) catch return error.FolderPathCollision;
            made[i] = true;
            count += 1;
        }
    }
    for (incoming, 0..) |item, i| {
        if (item.parent_id == null) continue;
        const actual = std.fs.cwd().realpathAlloc(a, target[i]) catch |err| if (err == error.FileNotFound) continue else return err;
        var owned = false;
        for (before) |prior| if (same(prior.id, item.id) and same(prior.path, actual)) {
            owned = true;
            break;
        };
        if (!owned) return error.FolderPathCollision;
    }
    @memset(made, false);
    made[metadataIndex(incoming, before[0].id).?] = true;
    count = 1;
    while (count < incoming.len) {
        for (incoming, 0..) |item, i| {
            if (made[i] or !made[metadataIndex(incoming, item.parent_id.?).?]) continue;
            var scratch = std.heap.ArenaAllocator.init(a);
            defer scratch.deinit();
            const live = try list(scratch.allocator(), root);
            var existing: ?Folder = null;
            for (live) |folder| if (same(folder.id, item.id)) {
                existing = folder;
                break;
            };
            if (existing) |folder| {
                if (!same(folder.path, target[i])) try std.fs.cwd().rename(folder.path, target[i]);
            } else {
                try std.fs.cwd().makeDir(target[i]);
                const file_path = try std.fs.path.join(a, &.{ target[i], ".doin-folder.json" });
                const file = try std.fs.cwd().createFile(file_path, .{ .exclusive = true, .mode = 0o600 });
                defer file.close();
                try platform.privateFile(a, file_path);
                try file.writeAll(try std.json.Stringify.valueAlloc(a, Identity{ .id = item.id }, .{}));
                try file.sync();
            }
            made[i] = true;
            count += 1;
        }
    }
}
fn noFileLink(a: A, path: []const u8) !void {
    const actual = std.fs.cwd().realpathAlloc(a, path) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    if (!same(actual, path)) return error.FolderSymlink;
}
fn identity(a: A, path: []const u8, create_identity: bool) !?[]const u8 {
    const p = try std.fs.path.join(a, &.{ path, ".doin-folder.json" });
    try noFileLink(a, p);
    try noFileLink(a, try std.fs.path.join(a, &.{ path, "tasks.md" }));
    if (std.fs.cwd().readFileAlloc(a, p, 256)) |bytes| {
        const value = (try std.json.parseFromSlice(Identity, a, bytes, .{ .allocate = .alloc_always })).value;
        if (value.id.len != 32) return error.InvalidFolderIdentity;
        for (value.id) |c| if (!std.ascii.isHex(c)) return error.InvalidFolderIdentity;
        return value.id;
    } else |err| if (err != error.FileNotFound) return err;
    if (!create_identity) return null;
    var random: [16]u8 = undefined;
    std.crypto.random.bytes(&random);
    const id = try std.fmt.allocPrint(a, "{x}", .{random});
    const f = try std.fs.cwd().createFile(p, .{ .exclusive = true, .mode = 0o600 });
    defer f.close();
    try platform.privateFile(a, p);
    try f.writeAll(try std.json.Stringify.valueAlloc(a, Identity{ .id = id }, .{}));
    try f.sync();
    return id;
}
pub fn list(a: A, root: []const u8) ![]Folder {
    const canonical = try std.fs.cwd().realpathAlloc(a, root);
    var folders: std.ArrayList(Folder) = .empty;
    try folders.append(a, .{ .id = (try identity(a, canonical, true)).?, .parent_id = null, .name = "Home", .path = canonical });
    var cursor: usize = 0;
    while (cursor < folders.items.len) : (cursor += 1) {
        const parent = folders.items[cursor];
        var dir = try std.fs.cwd().openDir(parent.path, .{ .iterate = true, .no_follow = true });
        defer dir.close();
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .directory or entry.name[0] == '.') continue;
            const p = try std.fs.path.join(a, &.{ parent.path, entry.name });
            const id = (try identity(a, p, false)) orelse continue;
            if (folders.items.len >= 4096) return error.FolderLimit;
            for (folders.items) |prior| if (same(prior.id, id)) return error.DuplicateFolderIdentity;
            try folders.append(a, .{ .id = id, .parent_id = parent.id, .name = try a.dupe(u8, entry.name), .path = p });
        }
    }
    return folders.toOwnedSlice(a);
}
fn find(items: []const Folder, id: []const u8) !Folder {
    for (items) |f| if (same(f.id, id)) return f;
    return error.FolderNotFound;
}
fn create(a: A, parent: Folder, name: []const u8) !void {
    try validName(name);
    const p = try std.fs.path.join(a, &.{ parent.path, name });
    std.fs.cwd().makeDir(p) catch |err| if (err != error.PathAlreadyExists) return err;
    var dir = try std.fs.cwd().openDir(p, .{ .no_follow = true });
    dir.close();
    _ = try identity(a, p, true);
    const document = try std.fs.path.join(a, &.{ p, "tasks.md" });
    const f = std.fs.cwd().createFile(document, .{ .exclusive = true, .mode = 0o600 }) catch |err| {
        if (err == error.PathAlreadyExists) return;
        return err;
    };
    defer f.close();
    try platform.privateFile(a, document);
    try f.writeAll(try std.fmt.allocPrint(a, "# {s}\n\n", .{name}));
}
fn lockRoot(a: A, root: []const u8) !std.fs.File {
    const f = try std.fs.cwd().createFile(try std.fs.path.join(a, &.{ root, ".doin-folders.lock" }), .{ .truncate = false, .mode = 0o600 });
    errdefer f.close();
    if (!try platform.tryLockExclusive(f)) return error.StorageBusy;
    return f;
}
pub fn run(a: A, root: []const u8, selected: []const u8, args: []const []const u8) !?[]const u8 {
    const lock = try lockRoot(a, root);
    defer lock.close();
    const items = try list(a, root);
    const command = if (args.len == 0) "list" else args[0];
    if (same(command, "list")) {
        try std.fs.File.stdout().writeAll(try std.fmt.allocPrint(a, "{s}\n", .{try std.json.Stringify.valueAlloc(a, items, .{ .whitespace = .indent_2 })}));
        return null;
    }
    if (same(command, "select")) {
        if (args.len != 2) return error.FolderIdRequired;
        return (try find(items, args[1])).path;
    }
    if (same(command, "create")) {
        if (args.len != 3) return error.FolderParentAndNameRequired;
        if (items.len >= 4096) return error.FolderLimit;
        try create(a, try find(items, args[1]), args[2]);
        return null;
    }
    if (!same(command, "rename") and !same(command, "move")) return error.UnknownFolderCommand;
    if (args.len != 3) return error.FolderIdAndTargetRequired;
    const f = try find(items, args[1]);
    if (f.parent_id == null) return error.LibraryRootFixed;
    var parent = try find(items, f.parent_id.?);
    var name = f.name;
    if (same(command, "rename")) {
        try validName(args[2]);
        name = args[2];
    } else {
        parent = try find(items, args[2]);
        var ancestor = parent;
        while (true) {
            if (same(ancestor.id, f.id)) return error.FolderCycle;
            const parent_id = ancestor.parent_id orelse break;
            ancestor = try find(items, parent_id);
        }
    }
    const target = try std.fs.path.join(a, &.{ parent.path, name });
    if (same(target, f.path)) return null;
    if (std.fs.cwd().access(target, .{})) |_| return error.PathAlreadyExists else |err| if (err != error.FileNotFound) return err;
    var selected_id: ?[]const u8 = null;
    const selected_real = std.fs.cwd().realpathAlloc(a, selected) catch selected;
    for (items) |item| if (same(item.path, selected_real)) {
        selected_id = item.id;
        break;
    };
    try std.fs.cwd().rename(f.path, target);
    if (selected_id) |id| return (try find(try list(a, root), id)).path;
    return null;
}
pub fn seed(a: A, root: []const u8, template: Template) !void {
    try std.fs.cwd().makePath(root);
    const lock = try lockRoot(a, root);
    defer lock.close();
    const items = try list(a, root);
    const names: []const []const u8 = switch (template) {
        .simple => &.{},
        .projects => &.{ "Inbox", "Projects", "Archive" },
        .areas => &.{ "Personal", "Work", "Someday" },
    };
    for (names) |name| {
        try create(a, items[0], name);
    }
}
