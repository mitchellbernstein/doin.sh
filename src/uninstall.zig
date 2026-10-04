const std = @import("std");
const builtin = @import("builtin");
const terminal = @import("terminal.zig");
const platform = @import("platform.zig");
const scheduler = @import("reminder_scheduler.zig");
const providers = @import("providers.zig");
const A = std.mem.Allocator;
pub const UninstallPlan = struct {
    config_dir: []const u8,
    executable: []const u8,
    task_roots: []const []const u8,
    jobs: []const scheduler.Job,
    config_readable: bool,
};
pub const Input = struct {
    prompt: *const fn (A, []const u8) anyerror![]const u8,
    choose: *const fn () anyerror![]const u8,
};
fn output(a: A, comptime format: []const u8, args: anytype) !void {
    const raw = try std.fmt.allocPrint(a, format, args);
    defer a.free(raw);
    const clean = try terminal.clean(a, raw, true);
    defer a.free(clean);
    try terminal.output(clean);
}
fn contains(parent: []const u8, child: []const u8) bool {
    const equal = if (builtin.os.tag == .windows) std.ascii.eqlIgnoreCase(parent, child) else std.mem.eql(u8, parent, child);
    const prefix = child.len > parent.len and (if (builtin.os.tag == .windows) std.ascii.eqlIgnoreCase(parent, child[0..parent.len]) else std.mem.startsWith(u8, child, parent));
    return equal or (prefix and std.fs.path.isSep(child[parent.len]));
}
fn canonical(a: A, path: []const u8) ![]const u8 {
    if (!std.fs.path.isAbsolute(path)) return error.UnsafeUninstallPath;
    return std.fs.cwd().realpathAlloc(a, path);
}
fn safeRoot(a: A, plan: UninstallPlan, raw: []const u8) ![]const u8 {
    var folder = try std.fs.cwd().openDir(raw, .{ .no_follow = true });
    defer folder.close();
    const root = try canonical(a, raw);
    if (builtin.os.tag == .windows) {
        const disk = std.fs.path.diskDesignatorWindows(root);
        const tail = root[disk.len..];
        if (std.mem.trim(u8, tail, "/\\").len == 0 or std.fs.path.dirnameWindows(root) == null) return error.UnsafeUninstallPath;
        for ([_][]const u8{ "SystemRoot", "WINDIR", "ProgramFiles", "ProgramFiles(x86)", "ProgramData" }) |name| {
            const value = std.process.getEnvVarOwned(a, name) catch |err| switch (err) {
                error.EnvironmentVariableNotFound => continue,
                else => return err,
            };
            const system = std.fs.cwd().realpathAlloc(a, value) catch try std.fs.path.resolveWindows(a, &.{value});
            if (contains(system, root)) return error.UnsafeUninstallPath;
        }
    }
    const home = try canonical(a, try platform.home(a));
    const working = try std.fs.cwd().realpathAlloc(a, ".");
    const config = std.fs.cwd().realpathAlloc(a, plan.config_dir) catch try std.fs.path.resolve(a, &.{plan.config_dir});
    const documents = try std.fs.path.join(a, &.{ home, "Documents" });
    for ([_][]const u8{ "/", "/Users", "/home", "/usr", "/opt", "/bin", "/sbin", "/etc", "/var", "/private", "/tmp", "/private/tmp", "/Library", "/System", "/Applications", home, documents }) |blocked| if (std.mem.eql(u8, root, blocked)) return error.UnsafeUninstallPath;
    for ([_][]const u8{ "/usr", "/bin", "/sbin", "/etc", "/System", "/Library", "/Applications", "/private/etc", "/private/var/db" }) |blocked| if (contains(blocked, root)) return error.UnsafeUninstallPath;
    if (contains(root, working) or contains(root, plan.executable) or contains(root, config) or contains(root, home)) return error.UnsafeUninstallPath;
    return root;
}
fn owned(name: []const u8) bool {
    for ([_][]const u8{ "config.json", "chatgpt.json", "chatgpt-registration.json", "grok.json", "vercel.json", "openrouter.json", "sync.json", "team.json", "mcp-servers.json", "host-id", ".auth.lock", ".mcp-servers.lock" }) |known| if (std.mem.eql(u8, name, known)) return true;
    if (std.mem.startsWith(u8, name, "auto-sync-")) {
        for ([_][]const u8{ ".running.lock", ".lock" }) |suffix| if (std.mem.endsWith(u8, name, suffix)) {
            const digest = name[10 .. name.len - suffix.len];
            if (digest.len != 16) return false;
            for (digest) |ch| if (!std.ascii.isHex(ch)) return false;
            return true;
        };
    }
    for ([_][]const u8{ "auto-sync-", "reminders-", "team-map-", "focus-" }) |prefix| if (std.mem.startsWith(u8, name, prefix) and std.mem.endsWith(u8, name, ".json")) {
        const digest = name[prefix.len .. name.len - 5];
        if (digest.len != (if (std.mem.eql(u8, prefix, "team-map-")) @as(usize, 64) else 16)) return false;
        for (digest) |ch| if (!std.ascii.isHex(ch)) return false;
        return true;
    };
    for (providers.all) |spec| {
        if (std.mem.startsWith(u8, name, "provider-") and std.mem.endsWith(u8, name, ".key") and std.mem.eql(u8, name[9 .. name.len - 4], spec.id)) return true;
    }
    return false;
}
fn removeSettings(a: A, path: []const u8) !void {
    var folder = std.fs.cwd().openDir(path, .{ .iterate = true, .no_follow = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer folder.close();
    var names: std.ArrayList([]const u8) = .empty;
    var iterator = folder.iterate();
    while (try iterator.next()) |entry| if (owned(entry.name) and (entry.kind == .file or entry.kind == .sym_link)) try names.append(a, try a.dupe(u8, entry.name));
    for (names.items) |name| try folder.deleteFile(name);
    if (folder.openDir("copilot", .{ .no_follow = true })) |copilot_dir| {
        var copilot_folder = copilot_dir;
        defer copilot_folder.close();
        copilot_folder.deleteFile("config.json") catch |err| if (err != error.FileNotFound) return err;
        folder.deleteDir("copilot") catch |err| if (err != error.DirNotEmpty) return err;
    } else |err| switch (err) {
        error.FileNotFound, error.NotDir, error.SymLinkLoop => {},
        else => return err,
    }
    std.fs.cwd().deleteDir(path) catch |err| switch (err) {
        error.DirNotEmpty => {},
        else => return err,
    };
}
pub fn run(a: A, plan: UninstallPlan, input: Input) !void {
    try output(a, "Uninstall doin\nTerminal executable: {s}\nApp settings and credentials: {s}\n", .{ plan.executable, plan.config_dir });
    if (!plan.config_readable) try output(a, "Settings unavailable; task deletion is disabled.\n", .{});
    for (plan.task_roots) |root| try output(a, "Task folder: {s}\n", .{root});
    if (!terminal.rich()) try output(a, "\n1  Keep task folders (Recommended)\n2  Delete task folders and ALL their contents\n", .{});
    const choice = std.mem.trim(u8, try input.choose(), " \r\n\t");
    const deleting = std.mem.eql(u8, choice, "2") or std.mem.eql(u8, choice, "delete");
    if (!deleting and choice.len != 0 and !std.mem.eql(u8, choice, "1") and !std.mem.eql(u8, choice, "keep")) return error.InvalidUninstallChoice;
    var roots: std.ArrayList([]const u8) = .empty;
    if (deleting) {
        if (!plan.config_readable) return error.UninstallStorageUnknown;
        for (plan.task_roots) |raw| {
            const root = safeRoot(a, plan, raw) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            var nested = false;
            for (roots.items) |existing| if (contains(existing, root)) {
                nested = true;
                break;
            };
            if (!nested) {
                var i: usize = 0;
                while (i < roots.items.len) {
                    if (contains(root, roots.items[i])) {
                        _ = roots.orderedRemove(i);
                    } else i += 1;
                }
                try roots.append(a, root);
            }
        }
        for (roots.items) |root| try output(a, "Will permanently delete: {s}\n", .{root});
        if (!std.mem.eql(u8, std.mem.trim(u8, try input.prompt(a, "Type DELETE to delete ALL contents: "), " \r\n\t"), "DELETE")) return output(a, "Cancelled. Nothing removed.\n", .{});
    }
    const answer = std.mem.trim(u8, try input.prompt(a, "Remove doin executable and app settings? [y/N]: "), " \r\n\t");
    if (!std.ascii.eqlIgnoreCase(answer, "y") and !std.ascii.eqlIgnoreCase(answer, "yes")) return output(a, "Cancelled. Nothing removed.\n", .{});
    var settings = std.fs.cwd().openDir(plan.config_dir, .{ .no_follow = true }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (settings) |*folder| folder.close();
    const executable = try std.fs.cwd().statFile(plan.executable);
    if (executable.kind != .file) return error.UnsafeUninstallPath;
    for (plan.jobs) |job| {
        const status = try scheduler.status(a, job);
        try scheduler.removeForUninstall(a, job, status);
    }
    for (roots.items) |root| {
        _ = try safeRoot(a, plan, root);
        try std.fs.cwd().deleteTree(root);
    }
    try removeSettings(a, plan.config_dir);
    if (builtin.os.tag == .windows) {
        try output(a, "Settings removed. After this process exits, manually delete: {s}\n", .{plan.executable});
        return;
    }
    try std.fs.cwd().deleteFile(plan.executable);
    try output(a, "doin uninstalled. Task folders {s}.\n", .{if (deleting) "deleted" else "kept"});
}
