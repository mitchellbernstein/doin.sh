//! Whole-library sync: metadata CAS, independent Markdown CAS, no implicit deletion.
const std = @import("std");
const folders = @import("folders.zig");
const platform = @import("platform.zig");
const background = @import("sync_background.zig");
const A = std.mem.Allocator;
pub const Response = struct { code: u16, body: []const u8 };
pub const Adapter = struct {
    request: *const fn (A, []const u8, []const u8, []const u8, ?[]const u8) anyerror!Response,
    identity: *const fn (A, []const u8) anyerror![]const u8,
    selected: *const fn (A, []const u8) anyerror!?[]const u8,
    select: *const fn (A, []const u8, []const u8) anyerror!void,
};
const Node = struct { id: []const u8, parent_id: ?[]const u8, name: []const u8, revision: i64 = 0 };
const Tree = struct { tree_revision: i64, folders: []Node, tombstones: []Node = &.{} };
const Doc = struct { revision: i64, content: []const u8, updated_at: i64 = 0 };
const ExportDoc = struct { id: []const u8, revision: i64, content: []const u8, updated_at: i64 };
const Base = struct { id: []const u8, revision: i64, hash: []const u8 };
const State = struct { identity: []const u8, root_id: []const u8, tree_revision: i64, tree_hash: []const u8, docs: []Base = &.{} };
const Local = struct { items: []folders.Folder, nodes: []Node, contents: [][]const u8 };
const Mode = enum { push, pull, auto };
fn same(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}
fn path(a: A, root: []const u8, name: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ root, name });
}
fn hash(a: A, bytes: []const u8) ![]const u8 {
    var sum: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &sum, .{});
    return std.fmt.allocPrint(a, "{x}", .{sum});
}
fn output(a: A, comptime text: []const u8, args: anytype) !void {
    try std.fs.File.stdout().writeAll(try std.fmt.allocPrint(a, text, args));
}
fn atomic(a: A, p: []const u8, bytes: []const u8) !void {
    var nonce: [8]u8 = undefined;
    std.crypto.random.bytes(&nonce);
    const temp = try std.fmt.allocPrint(a, "{s}.{x}.tmp", .{ p, nonce });
    defer std.fs.cwd().deleteFile(temp) catch {};
    const f = try std.fs.cwd().createFile(temp, .{ .exclusive = true, .mode = 0o600 });
    defer f.close();
    try platform.privateFile(a, temp);
    try f.writeAll(bytes);
    try f.sync();
    try std.fs.cwd().rename(temp, p);
}
fn lock(a: A, root: []const u8, name: []const u8) !std.fs.File {
    const f = try std.fs.cwd().createFile(try path(a, root, name), .{ .truncate = false, .mode = 0o600 });
    errdefer f.close();
    if (!try platform.tryLockExclusive(f)) return error.StorageBusy;
    return f;
}
fn checkedRoot(a: A, root: []const u8) !void {
    const actual = try std.fs.cwd().realpathAlloc(a, root);
    const equal = if (platform.windows) std.ascii.eqlIgnoreCase(actual, root) else same(actual, root);
    if (!equal) return error.LibraryRootMappingChanged;
}
fn content(bytes: []const u8) !void {
    if (bytes.len > 524288 or !std.unicode.utf8ValidateSlice(bytes) or std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidSyncDocument;
}
fn read(a: A, p: []const u8) ![]const u8 {
    const bytes = std.fs.cwd().readFileAlloc(a, p, 524288) catch |err| if (err == error.FileNotFound) "" else return err;
    try content(bytes);
    return bytes;
}
fn local(a: A, root: []const u8) !Local {
    try checkedRoot(a, root);
    const items = try folders.list(a, root);
    const nodes = try a.alloc(Node, items.len);
    const contents = try a.alloc([]const u8, items.len);
    var total: usize = 0;
    for (items, 0..) |item, i| {
        nodes[i] = .{ .id = if (item.parent_id == null) "root" else item.id, .parent_id = if (item.parent_id) |p| if (same(p, items[0].id)) "root" else p else null, .name = if (item.parent_id == null) "Home" else item.name };
        contents[i] = try read(a, try path(a, item.path, "tasks.md"));
        total += contents[i].len;
        if (total > 32 * 1024 * 1024) return error.LibraryTooLarge;
    }
    return .{ .items = items, .nodes = nodes, .contents = contents };
}
fn nodeIndex(nodes: []const Node, id: []const u8) ?usize {
    for (nodes, 0..) |node, i| if (same(node.id, id)) return i;
    return null;
}
fn validate(tree: Tree) !void {
    if (tree.tree_revision < 0 or tree.tree_revision >= 9007199254740991 or tree.folders.len == 0 or tree.folders.len > 4096 or tree.tombstones.len > 4096) return error.InvalidLibraryTree;
    const root = nodeIndex(tree.folders, "root") orelse return error.InvalidLibraryTree;
    if (tree.folders[root].parent_id != null) return error.InvalidLibraryTree;
    for (tree.folders, 0..) |node, i| {
        if (node.revision < 0 or node.revision >= 9007199254740991) return error.InvalidLibraryTree;
        if (!same(node.id, "root")) {
            if (node.id.len != 32) return error.InvalidLibraryTree;
            for (node.id) |ch| if (!std.ascii.isHex(ch)) return error.InvalidLibraryTree;
            if (node.parent_id == null) return error.InvalidLibraryTree;
        }
        for (tree.folders[0..i]) |prior| if (same(prior.id, node.id)) return error.InvalidLibraryTree;
        if (node.name.len == 0 or node.name.len > 120 or !std.unicode.utf8ValidateSlice(node.name)) return error.InvalidLibraryTree;
        var cursor = node;
        var steps: usize = 0;
        while (cursor.parent_id) |p| {
            steps += 1;
            if (steps >= tree.folders.len) return error.InvalidLibraryTree;
            cursor = tree.folders[nodeIndex(tree.folders, p) orelse return error.InvalidLibraryTree];
        }
    }
    for (tree.tombstones) |node| {
        if (node.id.len != 32 or nodeIndex(tree.folders, node.id) != null) return error.InvalidLibraryTree;
        for (node.id) |ch| if (!std.ascii.isHex(ch)) return error.InvalidLibraryTree;
    }
}
fn less(_: void, x: Node, y: Node) bool {
    return std.mem.lessThan(u8, x.id, y.id);
}
fn metadata(a: A, nodes: []const Node) ![]folders.Metadata {
    const copy = try a.dupe(Node, nodes);
    std.mem.sort(Node, copy, {}, less);
    const result = try a.alloc(folders.Metadata, copy.len);
    for (copy, 0..) |n, i| result[i] = .{ .id = n.id, .parent_id = n.parent_id, .name = if (same(n.id, "root")) "Home" else n.name };
    return result;
}
fn treeHash(a: A, nodes: []const Node) ![]const u8 {
    return hash(a, try std.json.Stringify.valueAlloc(a, try metadata(a, nodes), .{}));
}
fn request(a: A, config: []const u8, io: Adapter, method: []const u8, request_path: []const u8, data: ?[]const u8) !Response {
    return io.request(a, config, method, request_path, data);
}
fn decode(comptime T: type, a: A, response: Response) !T {
    if (response.code != 200) {
        try std.fs.File.stderr().writeAll(try std.fmt.allocPrint(a, "Library service returned HTTP {d}.\n", .{response.code}));
        return error.SyncRequestFailed;
    }
    return (try std.json.parseFromSlice(T, a, response.body, .{ .allocate = .alloc_always, .ignore_unknown_fields = true })).value;
}
fn fetchTree(a: A, config: []const u8, io: Adapter) !Tree {
    const tree = try decode(Tree, a, try request(a, config, io, "GET", "/v1/folders", null));
    try validate(tree);
    return tree;
}
fn route(a: A, id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "/v1/folders/{s}/document", .{id});
}
fn fetchDocs(a: A, config: []const u8, io: Adapter, nodes: []const Node) ![]Doc {
    const docs = try a.alloc(Doc, nodes.len);
    var total: usize = 0;
    for (nodes, 0..) |node, i| {
        docs[i] = try decode(Doc, a, try request(a, config, io, "GET", try route(a, node.id), null));
        if (docs[i].revision < 0 or docs[i].revision >= 9007199254740991) return error.InvalidSyncDocument;
        try content(docs[i].content);
        total += docs[i].content.len;
        if (total > 32 * 1024 * 1024) return error.LibraryTooLarge;
    }
    return docs;
}
fn baseline(a: A, root: []const u8) !?State {
    const p = try path(a, root, ".doin-library-sync.json");
    const bytes = std.fs.cwd().readFileAlloc(a, p, 1048576) catch |err| if (err == error.FileNotFound) return null else return err;
    try platform.requirePrivateFile(a, p);
    return (try std.json.parseFromSlice(State, a, bytes, .{ .allocate = .alloc_always })).value;
}
fn save(a: A, root: []const u8, state: State) !void {
    try atomic(a, try path(a, root, ".doin-library-sync.json"), try std.json.Stringify.valueAlloc(a, state, .{}));
}
fn placeholder(a: A, node: Node, bytes: []const u8) !bool {
    return std.mem.trim(u8, bytes, " \t\r\n").len == 0 or (same(node.id, "root") and same(bytes, "# Tasks\n\n")) or same(bytes, try std.fmt.allocPrint(a, "# {s}\n\n", .{node.name}));
}
fn conflict(a: A, root: []const u8, left: Local, right: Tree, docs: []const Doc) !void {
    const lm = try std.json.Stringify.valueAlloc(a, left.nodes, .{});
    const rm = try std.json.Stringify.valueAlloc(a, right, .{});
    var digest: std.crypto.hash.sha2.Sha256 = .init(.{});
    digest.update(lm);
    digest.update(rm);
    for (left.contents) |bytes| digest.update(bytes);
    for (docs) |d| digest.update(d.content);
    var sum: [32]u8 = undefined;
    digest.final(&sum);
    const dir = try path(a, root, try std.fmt.allocPrint(a, ".doin-library-conflict-{x}", .{sum[0..12]}));
    std.fs.cwd().makeDir(dir) catch |err| if (err != error.PathAlreadyExists) return err;
    const actual = try std.fs.cwd().realpathAlloc(a, dir);
    if (!same(actual, dir)) return error.LibraryRootMappingChanged;
    if (platform.windows) try platform.privateFile(a, dir) else {
        var private = try std.fs.cwd().openDir(dir, .{ .iterate = true });
        defer private.close();
        try private.chmod(0o700);
    }
    try atomic(a, try path(a, dir, "local-tree.json"), lm);
    try atomic(a, try path(a, dir, "cloud-tree.json"), rm);
    for (left.nodes, 0..) |node, i| try atomic(a, try path(a, dir, try std.fmt.allocPrint(a, "{s}-local.md", .{node.id})), left.contents[i]);
    for (right.folders, 0..) |node, i| try atomic(a, try path(a, dir, try std.fmt.allocPrint(a, "{s}-cloud.md", .{node.id})), docs[i].content);
}
fn accepted(a: A, records: *std.ArrayList(Base), id: []const u8, revision: i64, bytes: []const u8) !void {
    const item: Base = .{ .id = id, .revision = revision, .hash = try hash(a, bytes) };
    for (records.items) |*prior| if (same(prior.id, id)) {
        prior.* = item;
        return;
    };
    try records.append(a, item);
}
fn baseFor(records: []const Base, id: []const u8) ?Base {
    for (records) |item| if (same(item.id, id)) return item;
    return null;
}
fn selection(a: A, config: []const u8, root: []const u8, io: Adapter, id: ?[]const u8) !void {
    if (id) |wanted| for (try folders.list(a, root)) |item| if (same(item.id, wanted)) {
        try io.select(a, config, item.path);
        return;
    };
}
fn apply(a: A, config: []const u8, root: []const u8, io: Adapter, left: Local, right: Tree) !void {
    var selected_id: ?[]const u8 = null;
    if (try io.selected(a, config)) |p| for (left.items) |item| if (same(item.path, p)) {
        selected_id = item.id;
        break;
    };
    const meta = try a.alloc(folders.Metadata, right.folders.len);
    for (right.folders, 0..) |node, i| meta[i] = .{ .id = if (same(node.id, "root")) left.items[0].id else node.id, .parent_id = if (node.parent_id) |p| if (same(p, "root")) left.items[0].id else p else null, .name = node.name };
    folders.apply(a, root, meta) catch |err| {
        selection(a, config, root, io, selected_id) catch {};
        return err;
    };
    try selection(a, config, root, io, selected_id);
}
fn tick(a: A, config: []const u8, root: []const u8, io: Adapter, mode: Mode, resolve: bool) !background.Report {
    try checkedRoot(a, root);
    const identity = try io.identity(a, config);
    const owned = try lock(a, root, ".doin-library-sync.lock");
    defer owned.close();
    var left = try local(a, root);
    var right = try fetchTree(a, config, io);
    var docs = try fetchDocs(a, config, io, right.folders);
    var previous = try baseline(a, root);
    if (previous) |old| {
        if (!same(old.root_id, left.items[0].id)) return error.LibraryRootIdentityChanged;
        if (!same(old.identity, identity)) previous = null;
    }
    var lh = try treeHash(a, left.nodes);
    var rh = try treeHash(a, right.folders);
    var state: State = if (previous) |old| old else .{ .identity = identity, .root_id = left.items[0].id, .tree_revision = right.tree_revision, .tree_hash = rh };
    var records: std.ArrayList(Base) = .empty;
    try records.appendSlice(a, state.docs);
    var push_tree = false;
    var pull_tree = false;
    if (previous) |old| {
        if (!same(lh, rh)) {
            const lc = !same(lh, old.tree_hash);
            const rc = !same(rh, old.tree_hash);
            if (lc and !rc and mode != .pull) push_tree = true else if (rc and !lc and mode != .push) pull_tree = true else {
                try conflict(a, root, left, right, docs);
                return .{ .state = "conflict" };
            }
        }
    } else {
        var safe = true;
        if (mode == .push) {
            for (right.folders, 0..) |node, i| {
                const li = nodeIndex(left.nodes, node.id) orelse {
                    safe = false;
                    break;
                };
                if (!resolve and docs[i].content.len > 0 and !same(docs[i].content, left.contents[li])) safe = false;
            }
            push_tree = !same(lh, rh);
        } else if (mode == .pull) {
            for (left.nodes, 0..) |node, i| {
                const ri = nodeIndex(right.folders, node.id) orelse {
                    safe = false;
                    break;
                };
                if (!resolve and !same(left.contents[i], docs[ri].content) and !try placeholder(a, node, left.contents[i])) safe = false;
            }
            pull_tree = !same(lh, rh);
        } else {
            safe = same(lh, rh);
            for (left.nodes, 0..) |node, i| {
                const ri = nodeIndex(right.folders, node.id) orelse {
                    safe = false;
                    break;
                };
                if (!same(left.contents[i], docs[ri].content)) safe = false;
            }
        }
        if (!safe) {
            try conflict(a, root, left, right, docs);
            return .{ .state = "conflict" };
        }
    }
    const fresh = try local(a, root);
    if (!same(try treeHash(a, fresh.nodes), lh)) {
        try conflict(a, root, fresh, right, docs);
        return error.LibraryTreeChanged;
    }
    if (push_tree) {
        const response = try request(a, config, io, "PUT", "/v1/folders", try std.json.Stringify.valueAlloc(a, .{ .tree_revision = right.tree_revision, .folders = try metadata(a, left.nodes) }, .{}));
        if (response.code == 409) {
            try conflict(a, root, left, right, docs);
            return .{ .state = "conflict" };
        }
        right = try decode(Tree, a, response);
        try validate(right);
        rh = try treeHash(a, right.folders);
        if (!same(rh, lh)) return error.InvalidLibraryTree;
        docs = try fetchDocs(a, config, io, right.folders);
    }
    if (pull_tree) {
        _ = try io.identity(a, config);
        apply(a, config, root, io, left, right) catch |err| {
            try conflict(a, root, left, right, docs);
            return err;
        };
        left = try local(a, root);
        lh = try treeHash(a, left.nodes);
        if (!same(lh, rh)) return error.InvalidLibraryTree;
    }
    state.tree_revision = right.tree_revision;
    state.tree_hash = rh;
    var pushed = push_tree;
    var pulled = pull_tree;
    var collided = false;
    if (resolve) {
        try conflict(a, root, left, right, docs);
        for (left.nodes, 0..) |node, i| {
            const ri = nodeIndex(right.folders, node.id) orelse return error.InvalidLibraryTree;
            if (!same(left.contents[i], docs[ri].content)) try output(a, "Resolving folder {s} ({s}).\n", .{ node.name, node.id });
        }
    }
    for (left.nodes, 0..) |node, i| {
        const ri = nodeIndex(right.folders, node.id) orelse return error.InvalidLibraryTree;
        const remote = docs[ri];
        const bytes = left.contents[i];
        if (same(bytes, remote.content)) {
            try accepted(a, &records, node.id, remote.revision, bytes);
            continue;
        }
        const old = baseFor(records.items, node.id);
        var upload = false;
        var download = false;
        if (resolve) {
            upload = mode == .push;
            download = mode == .pull;
        } else if (old) |base| {
            const lc = !same(try hash(a, bytes), base.hash);
            const rc = !same(try hash(a, remote.content), base.hash);
            if (lc and rc) {
                collided = true;
                continue;
            }
            upload = lc and !rc and mode != .pull;
            download = rc and !lc and mode != .push;
        } else {
            upload = mode != .pull and remote.content.len == 0;
            download = mode != .push and try placeholder(a, node, bytes);
            if (!upload and !download) {
                collided = true;
                continue;
            }
        }
        if (!upload and !download) continue;
        _ = try io.identity(a, config);
        try checkedRoot(a, root);
        const current = try local(a, root);
        if (!same(try treeHash(a, current.nodes), lh)) return error.LibraryTreeChanged;
        const ci = nodeIndex(current.nodes, node.id) orelse return error.LibraryTreeChanged;
        const target = current.items[ci].path;
        const task_lock = try lock(a, target, ".tasks.lock");
        defer task_lock.close();
        const task = try path(a, target, "tasks.md");
        const latest = try read(a, task);
        if (!same(latest, bytes)) {
            try conflict(a, root, try local(a, root), right, docs);
            return error.DocumentChanged;
        }
        if (upload) {
            const response = try request(a, config, io, "PUT", try route(a, node.id), try std.json.Stringify.valueAlloc(a, .{ .revision = remote.revision, .content = bytes }, .{}));
            if (response.code == 409) {
                collided = true;
                continue;
            }
            const saved = try decode(Doc, a, response);
            try content(saved.content);
            if (!same(saved.content, bytes)) return error.InvalidSyncDocument;
            try accepted(a, &records, node.id, saved.revision, bytes);
            pushed = true;
        } else {
            try atomic(a, try path(a, target, ".tasks.undo"), latest);
            try atomic(a, try path(a, target, ".tasks.undo-current"), remote.content);
            if (!same(try read(a, task), latest)) return error.DocumentChanged;
            try atomic(a, task, remote.content);
            try accepted(a, &records, node.id, remote.revision, remote.content);
            pulled = true;
        }
    }
    state.docs = records.items;
    _ = try io.identity(a, config);
    try save(a, root, state);
    if (collided) {
        const current_tree = try fetchTree(a, config, io);
        const current_docs = try fetchDocs(a, config, io, current_tree.folders);
        try conflict(a, root, try local(a, root), current_tree, current_docs);
        return .{ .state = "conflict" };
    }
    return .{ .state = if (pushed) "pushed" else if (pulled) "pulled" else "unchanged" };
}
var automatic_adapter: ?Adapter = null;
fn automatic(a: A, config: []const u8, root: []const u8) !background.Report {
    return autoTick(a, config, root, automatic_adapter orelse return error.LibraryAdapterMissing);
}
pub fn autoTick(backing: A, config: []const u8, root: []const u8, io: Adapter) !background.Report {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    return tick(arena.allocator(), config, root, io, .auto, false);
}
fn exportLibrary(a: A, args: []const []const u8, config: []const u8, io: Adapter) !void {
    if (args.len != 2) return error.InvalidSyncArguments;
    const tree = try fetchTree(a, config, io);
    const active = try fetchDocs(a, config, io, tree.folders);
    const retired = try fetchDocs(a, config, io, tree.tombstones);
    const active_export = try a.alloc(ExportDoc, active.len);
    const retired_export = try a.alloc(ExportDoc, retired.len);
    for (active, 0..) |doc, i| active_export[i] = .{ .id = tree.folders[i].id, .revision = doc.revision, .content = doc.content, .updated_at = doc.updated_at };
    for (retired, 0..) |doc, i| retired_export[i] = .{ .id = tree.tombstones[i].id, .revision = doc.revision, .content = doc.content, .updated_at = doc.updated_at };
    const bytes = try std.json.Stringify.valueAlloc(a, .{ .format = "doin-library-v1", .tree = tree, .documents = active_export, .tombstone_documents = retired_export }, .{ .whitespace = .indent_2 });
    const f = try std.fs.cwd().createFile(args[1], .{ .exclusive = true, .mode = 0o600 });
    errdefer std.fs.cwd().deleteFile(args[1]) catch {};
    defer f.close();
    try platform.privateFile(a, args[1]);
    try f.writeAll(bytes);
    try f.sync();
    try output(a, "Saved private whole-library JSON export.\n", .{});
}
pub fn run(backing: A, args: []const []const u8, config: []const u8, root: []const u8, io: Adapter) !void {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const a = arena.allocator();
    if (args.len == 0) return error.InvalidSyncArguments;
    if (same(args[0], "auto")) {
        const prior = automatic_adapter;
        automatic_adapter = io;
        defer automatic_adapter = prior;
        return background.run(a, args[1..], config, root, .{ .tick = automatic });
    }
    if (same(args[0], "export")) return exportLibrary(a, args, config, io);
    if (args.len > 2) return error.InvalidSyncArguments;
    const mode: Mode = if (same(args[0], "push")) .push else if (same(args[0], "pull")) .pull else return error.InvalidSyncArguments;
    const resolve = args.len == 2;
    if (resolve and !((mode == .push and same(args[1], "--force")) or (mode == .pull and same(args[1], "--accept-remote")))) return error.InvalidSyncArguments;
    const report = try tick(a, config, root, io, mode, resolve);
    if (same(report.state, "conflict")) return error.SyncRevisionConflict;
    try output(a, "Library {s}.\n", .{report.state});
}
