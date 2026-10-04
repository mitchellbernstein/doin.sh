//! Opt-in, one-shot automatic sync. OS timers own cadence; no resident daemon.
const std = @import("std");
const scheduler = @import("reminder_scheduler.zig");
const platform = @import("platform.zig");
const terminal = @import("terminal.zig");
const A = std.mem.Allocator;
pub const Report = struct { state: []const u8 };
pub const Adapter = struct { tick: *const fn (a: A, config_dir: []const u8, storage: []const u8) anyerror!Report };
const Settings = struct { enabled: bool = false, last_state: []const u8 = "off", last_error: ?[]const u8 = null, last_checked: i64 = 0 };
fn output(a: A, comptime format: []const u8, args: anytype) !void {
    try std.fs.File.stdout().writeAll(try std.fmt.allocPrint(a, format, args));
}
fn path(a: A, config: []const u8, storage: []const u8, suffix: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(storage, &digest, .{});
    return std.fs.path.join(a, &.{ config, try std.fmt.allocPrint(a, "auto-sync-{x}{s}", .{ digest[0..8], suffix }) });
}
fn load(a: A, config: []const u8, storage: []const u8) !Settings {
    const bytes = std.fs.cwd().readFileAlloc(a, try path(a, config, storage, ".json"), 8192) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    return (try std.json.parseFromSlice(Settings, a, bytes, .{ .allocate = .alloc_always })).value;
}
fn save(a: A, config: []const u8, storage: []const u8, state: Settings) !void {
    const target = try path(a, config, storage, ".json");
    var nonce: [8]u8 = undefined;
    std.crypto.random.bytes(&nonce);
    const temporary = try std.fmt.allocPrint(a, "{s}.{x}.tmp", .{ target, nonce });
    defer std.fs.cwd().deleteFile(temporary) catch {};
    const file = try std.fs.cwd().createFile(temporary, .{ .exclusive = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(try std.json.Stringify.valueAlloc(a, state, .{}));
    try file.sync();
    try std.fs.cwd().rename(temporary, target);
    try platform.privateFile(a, target);
}
fn lock(a: A, config: []const u8, storage: []const u8, suffix: []const u8) !std.fs.File {
    const file = try std.fs.cwd().createFile(try path(a, config, storage, suffix), .{ .truncate = false, .mode = 0o600 });
    errdefer file.close();
    if (!try platform.tryLockExclusive(file)) return error.StorageBusy;
    return file;
}
fn cancel(_: c_int) callconv(.c) void {
    terminal.cancelSession();
}
fn record(a: A, config: []const u8, storage: []const u8, state: []const u8, err: ?[]const u8) !void {
    const control = try lock(a, config, storage, ".lock");
    defer control.close();
    var latest = try load(a, config, storage);
    latest.last_state = state;
    latest.last_error = err;
    latest.last_checked = std.time.timestamp();
    try save(a, config, storage, latest);
}
pub fn run(a: A, args: []const []const u8, config: []const u8, storage: []const u8, adapter: Adapter) !void {
    if (args.len > 1) return error.InvalidSyncArguments;
    const command = if (args.len == 0) "status" else args[0];
    if (!std.mem.eql(u8, command, "check")) {
        const control = try lock(a, config, storage, ".lock");
        defer control.close();
        var state = try load(a, config, storage);
        const job: scheduler.Job = .{ .kind = .sync, .config_dir = config, .storage = storage };
        if (std.mem.eql(u8, command, "status")) {
            const os = try scheduler.status(a, job);
            try output(a, "Auto sync {s} · timer {s} · last {s}{s}{s}\n", .{ if (state.enabled) "on" else "off", if (os.active) "active" else if (os.installed) "installed, inactive" else "absent", state.last_state, if (state.last_error != null) ": " else "", state.last_error orelse "" });
            return;
        }
        if (std.mem.eql(u8, command, "enable")) {
            std.fs.cwd().access(try std.fs.path.join(a, &.{ config, "sync.json" }), .{}) catch return error.SyncLoginRequired;
            if (state.enabled) {
                try output(a, "Auto sync already on. Use status to inspect the timer.\n", .{});
                return;
            }
            try scheduler.enable(a, job);
            state.enabled = true;
            state.last_state = "waiting";
            state.last_error = null;
            save(a, config, storage, state) catch |err| {
                scheduler.disable(a, job) catch {};
                return err;
            };
            return output(a, "Auto sync on. Checks every minute while logged in; conflicts keep both copies.\n", .{});
        }
        if (std.mem.eql(u8, command, "disable")) {
            // Gate all future ticks before stopping a potentially running OS process.
            state.enabled = false;
            state.last_state = "off";
            try save(a, config, storage, state);
            const os = try scheduler.status(a, job);
            if (os.installed or os.active) try scheduler.disable(a, job);
            return output(a, "Auto sync off. Local Markdown kept.\n", .{});
        }
        return error.UnknownSyncCommand;
    }
    const running = try lock(a, config, storage, ".running.lock");
    defer running.close();
    const state = try load(a, config, storage);
    if (!state.enabled) return output(a, "Auto sync off. Nothing uploaded.\n", .{});
    if (try platform.env(a, "DOIN_JOB_STORAGE")) |expected| if (!std.mem.eql(u8, expected, storage)) return error.BackgroundStorageChanged;
    const guard = try platform.SignalGuard.install(cancel);
    defer guard.restore();
    const report = adapter.tick(a, config, storage) catch |err| {
        try record(a, config, storage, "error", @errorName(err));
        return err;
    };
    if (!std.mem.eql(u8, report.state, "unchanged") and !std.mem.eql(u8, report.state, "pushed") and !std.mem.eql(u8, report.state, "pulled") and !std.mem.eql(u8, report.state, "conflict")) return error.InvalidSyncResult;
    try record(a, config, storage, report.state, null);
    if (std.mem.eql(u8, report.state, "conflict")) return error.SyncRevisionConflict;
    try output(a, "Auto sync: {s}.\n", .{report.state});
}
