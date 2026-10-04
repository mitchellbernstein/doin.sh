//! Explicit per-user one-shot OS timers shared by reminders and optional sync.
const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform.zig");
const terminal = @import("terminal.zig");
const A = std.mem.Allocator;
pub const Kind = enum { reminders, sync };
pub const Platform = enum { macos, linux, windows, unsupported };
pub const Job = struct { kind: Kind, config_dir: []const u8, storage: []const u8 };
pub const Status = struct { installed: bool, active: bool };
fn current() Platform {
    return switch (builtin.os.tag) {
        .macos => .macos,
        .linux => .linux,
        .windows => .windows,
        else => .unsupported,
    };
}
fn env(a: A, key: []const u8, default: []const u8) ![]const u8 {
    return std.process.getEnvVarOwned(a, key) catch try a.dupe(u8, default);
}
fn clean(text: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidSchedulerPath;
    for (text) |ch| if (ch < 32 or ch == 127) return error.InvalidSchedulerPath;
}
fn atomic(a: A, path: []const u8, bytes: []const u8) !void {
    var nonce: [8]u8 = undefined;
    std.crypto.random.bytes(&nonce);
    const temp = try std.fmt.allocPrint(a, "{s}.{x}.tmp", .{ path, nonce });
    defer std.fs.cwd().deleteFile(temp) catch {};
    const file = try std.fs.cwd().createFile(temp, .{ .exclusive = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(bytes);
    try file.sync();
    try std.fs.cwd().rename(temp, path);
    try platform.privateFile(a, path);
}
fn taskXml(a: A, path: []const u8, text: []const u8) !void {
    const utf16 = try std.unicode.utf8ToUtf16LeAlloc(a, text);
    defer a.free(utf16);
    const bytes = try a.alloc(u8, 2 + utf16.len * 2);
    defer a.free(bytes);
    bytes[0] = 0xff;
    bytes[1] = 0xfe;
    for (utf16, 0..) |unit, i| std.mem.writeInt(u16, bytes[2 + i * 2 ..][0..2], std.mem.littleToNative(u16, unit), .little);
    try atomic(a, path, bytes);
}
fn quote(a: A, text: []const u8, exec_start: bool) ![]const u8 {
    try clean(text);
    var result: std.ArrayList(u8) = .empty;
    try result.append(a, '"');
    for (text) |ch| switch (ch) {
        '"', '\\' => {
            try result.append(a, '\\');
            try result.append(a, ch);
        },
        '%' => try result.appendSlice(a, "%%"),
        '$' => if (exec_start) {
            try result.appendSlice(a, "$$");
        } else {
            try result.append(a, ch);
        },
        else => try result.append(a, ch),
    };
    try result.append(a, '"');
    return result.toOwnedSlice(a);
}
fn xml(a: A, text: []const u8) ![]const u8 {
    try clean(text);
    var result: std.ArrayList(u8) = .empty;
    for (text) |ch| try result.appendSlice(a, switch (ch) {
        '&' => "&amp;",
        '<' => "&lt;",
        '>' => "&gt;",
        '"' => "&quot;",
        '\'' => "&apos;",
        else => &.{ch},
    });
    return result.toOwnedSlice(a);
}
fn windowsArg(a: A, text: []const u8) ![]const u8 {
    try clean(text);
    var result: std.ArrayList(u8) = .empty;
    try result.append(a, '"');
    var slashes: usize = 0;
    for (text) |ch| {
        if (ch == '\\') {
            slashes += 1;
            continue;
        }
        const count = if (ch == '"') slashes * 2 + 1 else slashes;
        try result.appendNTimes(a, '\\', count);
        slashes = 0;
        try result.append(a, ch);
    }
    try result.appendNTimes(a, '\\', slashes * 2);
    try result.append(a, '"');
    return result.toOwnedSlice(a);
}
fn name(a: A, job: Job) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(job.config_dir, &digest, .{});
    return std.fmt.allocPrint(a, "com.studioyeehaw.doin.{s}.{x}", .{ @tagName(job.kind), digest[0..8] });
}
fn folder(a: A, job: Job, os: Platform) ![]const u8 {
    if (os == .windows) return job.config_dir;
    if (os == .linux) {
        const base = try env(a, "XDG_CONFIG_HOME", try std.fs.path.join(a, &.{ try platform.home(a), ".config" }));
        return env(a, "DOIN_SYSTEMD_UNIT_DIR", try std.fs.path.join(a, &.{ base, "systemd/user" }));
    }
    if (os == .macos) return env(a, if (job.kind == .sync) "DOIN_SYNC_AGENT_DIR" else "DOIN_REMINDER_AGENT_DIR", try std.fs.path.join(a, &.{ try platform.home(a), "Library/LaunchAgents" }));
    return error.BackgroundSchedulerUnsupported;
}
fn location(a: A, job: Job, os: Platform, suffix: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ try folder(a, job, os), try std.fmt.allocPrint(a, "{s}{s}", .{ try name(a, job), suffix }) });
}
fn domain(a: A) ![]const u8 {
    return std.fmt.allocPrint(a, "gui/{d}", .{if (builtin.os.tag == .windows) @as(u32, 0) else std.posix.getuid()});
}
fn cancel(_: c_int) callconv(.c) void {
    terminal.cancelSession();
}
fn execute(a: A, args: []const []const u8) !void {
    const signals = try platform.SignalGuard.install(cancel);
    defer signals.restore();
    var child = std.process.Child.init(args, a);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = if (builtin.os.tag == .windows) .Inherit else .Ignore;
    var group = try platform.ChildGroup.spawn(&child);
    defer group.close();
    terminal.trackHttp(child.id);
    defer terminal.clearHttp();
    try child.waitForSpawn();
    var timer = try std.time.Timer.start();
    while (timer.read() < 5 * std.time.ns_per_s) {
        if (terminal.cancelled()) break;
        if (builtin.os.tag == .windows) {
            if (group.done(&child)) {
                const term = try child.wait();
                group.terminate(&child);
                if (term != .Exited or term.Exited != 0) return error.SchedulerCommandFailed;
                return;
            }
        } else {
            const result = std.posix.waitpid(child.id, std.posix.W.NOHANG);
            if (result.pid != 0) {
                group.terminate(&child);
                if (!std.posix.W.IFEXITED(result.status) or std.posix.W.EXITSTATUS(result.status) != 0) return error.SchedulerCommandFailed;
                return;
            }
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    group.terminate(&child);
    _ = child.wait() catch {};
    return error.SchedulerCommandTimedOut;
}
pub fn enable(a: A, job: Job) !void {
    return enableOn(a, job, current());
}
pub fn enableOn(a: A, job: Job, os: Platform) !void {
    if (os == .unsupported) return error.BackgroundSchedulerUnsupported;
    try clean(job.config_dir);
    try clean(job.storage);
    const exe = try std.fs.selfExePathAlloc(a);
    const label = try name(a, job);
    const timer_name = try std.fmt.allocPrint(a, "{s}.timer", .{label});
    const paths = try env(a, "PATH", "/usr/bin:/bin");
    try std.fs.cwd().makePath(try folder(a, job, os));
    if (os == .linux) {
        const service = try location(a, job, os, ".service");
        const timer = try location(a, job, os, ".timer");
        for ([_][]const u8{ service, timer }) |existing| {
            std.fs.cwd().access(existing, .{}) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            return error.BackgroundSchedulerAlreadyInstalled;
        }
        const args = if (job.kind == .sync) "sync auto check" else "remind check";
        const contents = try std.fmt.allocPrint(a, "[Unit]\nDescription=doin {s} checks\n[Service]\nType=oneshot\nExecStart={s} {s}\nEnvironment={s}\nEnvironment={s}\nEnvironment={s}\nTimeoutStartSec=50s\nKillMode=control-group\n", .{ @tagName(job.kind), try quote(a, exe, true), args, try quote(a, try std.fmt.allocPrint(a, "DOIN_CONFIG_DIR={s}", .{job.config_dir}), false), try quote(a, try std.fmt.allocPrint(a, "DOIN_JOB_STORAGE={s}", .{job.storage}), false), try quote(a, try std.fmt.allocPrint(a, "PATH={s}", .{paths}), false) });
        try atomic(a, service, contents);
        errdefer {
            std.fs.cwd().deleteFile(service) catch {};
            execute(a, &.{ "systemctl", "--user", "daemon-reload" }) catch {};
        }
        try atomic(a, timer, try std.fmt.allocPrint(a, "[Unit]\nDescription=doin {s} timer\n[Timer]\nOnActiveSec=60s\nOnUnitInactiveSec=60s\nAccuracySec=5s\n[Install]\nWantedBy=timers.target\n", .{@tagName(job.kind)}));
        errdefer {
            execute(a, &.{ "systemctl", "--user", "disable", "--now", timer_name }) catch {};
            std.fs.cwd().deleteFile(timer) catch {};
            execute(a, &.{ "systemctl", "--user", "daemon-reload" }) catch {};
        }
        try execute(a, &.{ "systemctl", "--user", "daemon-reload" });
        try execute(a, &.{ "systemctl", "--user", "enable", "--now", timer_name });
    } else if (os == .windows) {
        const file = try location(a, job, os, ".xml");
        if (std.fs.cwd().access(file, .{})) |_| return error.BackgroundSchedulerAlreadyInstalled else |err| {
            if (err != error.FileNotFound) return err;
        }
        const arguments = try std.fmt.allocPrint(a, "background-check {s} {s} {s}", .{ @tagName(job.kind), try windowsArg(a, job.config_dir), try windowsArg(a, job.storage) });
        const sid = try platform.currentUserSid(a);
        const date = try @import("calendar.zig").utcComponents(std.time.timestamp() + 60);
        const boundary = try std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ @as(u32, @intCast(date.year)), @as(u32, @intCast(date.month)), @as(u32, @intCast(date.day)), @as(u32, @intCast(date.hour)), @as(u32, @intCast(date.minute)), @as(u32, @intCast(date.second)) });
        try taskXml(a, file, try std.fmt.allocPrint(a, "<?xml version=\"1.0\" encoding=\"UTF-16\"?><Task version=\"1.2\" xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\"><Triggers><TimeTrigger><Enabled>true</Enabled><StartBoundary>{s}</StartBoundary><Repetition><Interval>PT1M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition></TimeTrigger></Triggers><Principals><Principal id=\"User\"><UserId>{s}</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals><Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><ExecutionTimeLimit>PT50S</ExecutionTimeLimit><Enabled>true</Enabled></Settings><Actions Context=\"User\"><Exec><Command>{s}</Command><Arguments>{s}</Arguments></Exec></Actions></Task>", .{ boundary, try xml(a, sid), try xml(a, exe), try xml(a, arguments) }));
        errdefer std.fs.cwd().deleteFile(file) catch {};
        try execute(a, &.{ "schtasks.exe", "/Create", "/TN", label, "/XML", file });
    } else {
        const file = try location(a, job, os, ".plist");
        if (std.fs.cwd().access(file, .{})) |_| return error.BackgroundSchedulerAlreadyInstalled else |err| {
            if (err != error.FileNotFound) return err;
        }
        const command = if (job.kind == .sync) "<string>sync</string><string>auto</string><string>check</string>" else "<string>remind</string><string>check</string>";
        try atomic(a, file, try std.fmt.allocPrint(a, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>Label</key><string>{s}</string><key>ProgramArguments</key><array><string>{s}</string>{s}</array><key>EnvironmentVariables</key><dict><key>DOIN_CONFIG_DIR</key><string>{s}</string><key>DOIN_JOB_STORAGE</key><string>{s}</string><key>PATH</key><string>{s}</string></dict><key>StartInterval</key><integer>60</integer></dict></plist>", .{ try xml(a, label), try xml(a, exe), command, try xml(a, job.config_dir), try xml(a, job.storage), try xml(a, paths) }));
        errdefer std.fs.cwd().deleteFile(file) catch {};
        try execute(a, &.{ "launchctl", "bootstrap", try domain(a), file });
    }
}
pub fn disable(a: A, job: Job) !void {
    return disableOn(a, job, current());
}
pub fn removeForUninstall(a: A, job: Job, known: Status) !void {
    if (current() == .macos and known.installed and !known.active) {
        std.fs.cwd().deleteFile(try location(a, job, .macos, ".plist")) catch |err| if (err != error.FileNotFound) return err;
        return;
    }
    if (known.installed or known.active) try disable(a, job);
}
pub fn disableOn(a: A, job: Job, os: Platform) !void {
    if (os == .unsupported) return error.BackgroundSchedulerUnsupported;
    const label = try name(a, job);
    const timer_name = try std.fmt.allocPrint(a, "{s}.timer", .{label});
    if (os == .linux) {
        try execute(a, &.{ "systemctl", "--user", "disable", "--now", timer_name });
        try execute(a, &.{ "systemctl", "--user", "stop", try std.fmt.allocPrint(a, "{s}.service", .{label}) });
        for ([_][]const u8{ ".timer", ".service" }) |suffix| std.fs.cwd().deleteFile(try location(a, job, os, suffix)) catch |err| if (err != error.FileNotFound) return err;
        try execute(a, &.{ "systemctl", "--user", "daemon-reload" });
    } else if (os == .windows) {
        // /End may report no running instance. Deletion still disables all future ticks.
        execute(a, &.{ "schtasks.exe", "/End", "/TN", label }) catch {};
        try execute(a, &.{ "schtasks.exe", "/Delete", "/TN", label, "/F" });
        std.fs.cwd().deleteFile(try location(a, job, os, ".xml")) catch |err| if (err != error.FileNotFound) return err;
    } else {
        const file = try location(a, job, os, ".plist");
        try execute(a, &.{ "launchctl", "bootout", try domain(a), file });
        std.fs.cwd().deleteFile(file) catch |err| if (err != error.FileNotFound) return err;
    }
}
pub fn status(a: A, job: Job) !Status {
    const os = current();
    if (os == .unsupported) return .{ .installed = false, .active = false };
    const file = try location(a, job, os, if (os == .linux) ".timer" else if (os == .windows) ".xml" else ".plist");
    std.fs.cwd().access(file, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{ .installed = false, .active = false },
        else => return err,
    };
    const args: []const []const u8 = if (os == .linux) &.{ "systemctl", "--user", "is-active", "--quiet", try std.fmt.allocPrint(a, "{s}.timer", .{try name(a, job)}) } else if (os == .windows) &.{ "schtasks.exe", "/Query", "/TN", try name(a, job) } else &.{ "launchctl", "print", try std.fmt.allocPrint(a, "{s}/{s}", .{ try domain(a), try name(a, job) }) };
    execute(a, args) catch |err| switch (err) {
        error.SchedulerCommandFailed => return .{ .installed = true, .active = false },
        else => return err,
    };
    return .{ .installed = true, .active = true };
}
