//! Explicit local notifications; task identity and due instant travel in Markdown.
const std = @import("std");
const builtin = @import("builtin");
const A = std.mem.Allocator;
const calendar_date = @import("calendar.zig");
const scheduler = @import("reminder_scheduler.zig");
const platform = @import("platform.zig");
const limit = 1024 * 1024;
const prefix = " <!-- doin:id=";
const Marker = struct { start: usize, id: []const u8, due: i64 = 0 };
const Task = struct { start: usize, end: usize, done: bool, text: []const u8, id: []const u8 = "", due: i64 = 0 };
const Delivery = struct { id: []const u8, due: i64, status: []const u8 = "pending", attempted_at: i64 = 0 };
const Store = struct { enabled: bool = false, scheduler: bool = false, records: []Delivery = &.{} };
pub const Plan = struct { after: []const u8, id: []const u8, due: i64, label: []const u8 };
pub const FenceTracker = struct {
    char: u8 = 0,
    count: usize = 0,
    pub fn feed(self: *FenceTracker, line: []const u8) bool {
        const text = std.mem.trimStart(u8, line, " \t");
        var count: usize = 0;
        if (text.len > 0 and (text[0] == '`' or text[0] == '~')) while (count < text.len and text[count] == text[0]) {
            count += 1;
        };
        if (self.count > 0) {
            if (count >= self.count and text[0] == self.char and std.mem.trim(u8, text[count..], " \t\r").len == 0) {
                self.count = 0;
                self.char = 0;
            }
            return true;
        }
        if (count >= 3) {
            self.char = text[0];
            self.count = count;
            return true;
        }
        return false;
    }
};
fn marker(text: []const u8) ?Marker {
    const trimmed = std.mem.trimEnd(u8, text, " \t\r");
    const start = std.mem.lastIndexOf(u8, trimmed, prefix) orelse return null;
    const body = trimmed[start + prefix.len ..];
    if (!std.mem.endsWith(u8, body, " -->") or body.len < 36) return null;
    const values = body[0 .. body.len - 4];
    if (values.len < 32) return null;
    for (values[0..32]) |ch| if (!((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'))) return null;
    if (values.len == 32) return .{ .start = start, .id = values[0..32] };
    if (!std.mem.startsWith(u8, values[32..], " remind=")) return null;
    const digits = values[40..];
    if (digits.len == 0) return null;
    for (digits) |ch| if (!std.ascii.isDigit(ch)) return null;
    const due = std.fmt.parseInt(i64, digits, 10) catch return null;
    if (due <= 0 or due > 253402300799) return null;
    return .{ .start = start, .id = values[0..32], .due = due };
}
pub fn title(text: []const u8) []const u8 {
    var end = if (marker(text)) |m| m.start else text.len;
    for ([_][]const u8{ " <!-- doin:values=", " <!-- doin:task=" }) |metadata_prefix| {
        if (std.mem.indexOf(u8, text, metadata_prefix)) |index| end = @min(end, index);
    }
    if (completionMarker(text)) |index| end = @min(end, index);
    return text[0..end];
}

fn completionMarker(text: []const u8) ?usize {
    var cursor: usize = 0;
    var candidate: ?usize = null;
    while (cursor < text.len) {
        const relative_start = std.mem.indexOf(u8, text[cursor..], "<!--") orelse break;
        const start = cursor + relative_start;
        const relative_end = std.mem.indexOf(u8, text[start + 4 ..], "-->") orelse break;
        const close = start + 4 + relative_end + 3;
        if (validCompletionComment(text[start..close]) and onlyMetadataAfter(text, close)) {
            if (candidate != null) return null;
            candidate = if (start > 0 and text[start - 1] == ' ') start - 1 else start;
        }
        cursor = close;
    }
    return candidate;
}

fn onlyMetadataAfter(text: []const u8, start: usize) bool {
    var cursor = start;
    while (cursor < text.len) {
        while (cursor < text.len and (text[cursor] == ' ' or text[cursor] == '\t' or text[cursor] == '\r')) cursor += 1;
        if (cursor == text.len) return true;
        if (!std.mem.startsWith(u8, text[cursor..], "<!--")) return false;
        const relative_end = std.mem.indexOf(u8, text[cursor + 4 ..], "-->") orelse return false;
        cursor += 4 + relative_end + 3;
    }
    return true;
}

fn validCompletionComment(comment: []const u8) bool {
    const completion_prefix = "<!-- doin:completed=";
    const suffix = " -->";
    if (comment.len != completion_prefix.len + 10 + suffix.len or
        !std.mem.startsWith(u8, comment, completion_prefix) or
        !std.mem.endsWith(u8, comment, suffix)) return false;
    const value = comment[completion_prefix.len .. completion_prefix.len + 10];
    if (value[4] != '-' or value[7] != '-') return false;
    for (value, 0..) |c, i| if (i != 4 and i != 7 and !std.ascii.isDigit(c)) return false;
    const year = std.fmt.parseInt(u16, value[0..4], 10) catch return false;
    const month = std.fmt.parseInt(u8, value[5..7], 10) catch return false;
    const day = std.fmt.parseInt(u8, value[8..10], 10) catch return false;
    if (year == 0 or month == 0 or month > 12 or day == 0) return false;
    const days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const day_limit = days[month - 1] + @as(u8, if (month == 2 and year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)) 1 else 0);
    return day <= day_limit;
}
fn tasks(a: A, bytes: []const u8) ![]Task {
    var result: std.ArrayList(Task) = .empty;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var offset: usize = 0;
    var fences: FenceTracker = .{};
    while (lines.next()) |line| {
        defer offset += line.len + 1;
        if (fences.feed(line)) continue;
        const l = std.mem.trimStart(u8, line, " \t");
        if (l.len < 6 or (l[0] != '-' and l[0] != '*') or l[1] != ' ' or l[2] != '[' or (l[3] != ' ' and l[3] != 'x' and l[3] != 'X') or l[4] != ']' or l[5] != ' ') continue;
        const m = marker(l[6..]);
        try result.append(a, .{ .start = offset, .end = offset + line.len, .done = l[3] != ' ', .text = title(std.mem.trimEnd(u8, l[6..], "\r")), .id = if (m) |x| x.id else "", .due = if (m) |x| x.due else 0 });
    }
    return result.toOwnedSlice(a);
}
fn unique(items: []const Task) !void {
    for (items, 0..) |item, index| if (item.id.len > 0) for (items[index + 1 ..]) |other| if (std.mem.eql(u8, item.id, other.id)) return error.DuplicateReminderID;
}
fn now() !i64 {
    return calendar_date.now();
}
fn when(text: []const u8, current: i64) !i64 {
    return calendar_date.parse(text, current);
}
fn label(a: A, due: i64) ![]const u8 {
    return calendar_date.format(a, due);
}
pub fn prepare(a: A, before: []const u8, index: usize, time: []const u8) !Plan {
    const items = try tasks(a, before);
    try unique(items);
    if (index == 0 or index > items.len) return error.TaskNotFound;
    const task = items[index - 1];
    const off = std.mem.eql(u8, std.mem.trim(u8, time, " \t"), "off");
    if (!off and task.done) return error.ReminderTaskCompleted;
    if (off and task.id.len == 0) return .{ .after = before, .id = "", .due = 0, .label = "No reminder" };
    const due = if (off) 0 else try when(time, try now());
    if (due > 253402300799) return error.InvalidReminderTime;
    if (!off and due <= try now()) return error.ReminderTimeMustBeFuture;
    var random: [16]u8 = undefined;
    std.crypto.random.bytes(&random);
    const id = if (task.id.len > 0) task.id else try std.fmt.allocPrint(a, "{x}", .{random});
    const line = before[task.start..task.end];
    const content = if (marker(line)) |m| line[0..m.start] else std.mem.trimEnd(u8, line, "\r");
    const annotation = if (off) try std.fmt.allocPrint(a, "{s}{s} -->", .{ prefix, id }) else try std.fmt.allocPrint(a, "{s}{s} remind={d} -->", .{ prefix, id, due });
    const after = try std.fmt.allocPrint(a, "{s}{s}{s}{s}{s}", .{ before[0..task.start], content, annotation, if (std.mem.endsWith(u8, line, "\r")) "\r" else "", before[task.end..] });
    if (after.len > limit) return error.DocumentTooLarge;
    return .{ .after = after, .id = id, .due = due, .label = if (off) "Reminder off" else try label(a, due) };
}
fn path(a: A, folder: []const u8, name: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ folder, name });
}
fn read(a: A, p: []const u8) ![]const u8 {
    return std.fs.cwd().readFileAlloc(a, p, limit);
}
fn atomic(a: A, p: []const u8, bytes: []const u8) !void {
    var nonce: [8]u8 = undefined;
    std.crypto.random.bytes(&nonce);
    const tmp = try std.fmt.allocPrint(a, "{s}.{x}.tmp", .{ p, nonce });
    defer a.free(tmp);
    defer std.fs.cwd().deleteFile(tmp) catch {};
    const file = try std.fs.cwd().createFile(tmp, .{ .exclusive = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(bytes);
    try file.sync();
    try std.fs.cwd().rename(tmp, p);
}
fn statePath(a: A, config: []const u8, storage: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(storage, &digest, .{});
    return path(a, config, try std.fmt.allocPrint(a, "reminders-{x}.json", .{digest[0..8]}));
}
fn load(a: A, config: []const u8, storage: []const u8) !Store {
    const bytes = read(a, try statePath(a, config, storage)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    const store = (try std.json.parseFromSlice(Store, a, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true })).value;
    if (store.records.len > 1000) return error.ReminderHistoryTooLarge;
    for (store.records) |record| {
        if (record.id.len != 32 or record.due <= 0 or record.due > 253402300799) return error.InvalidReminderHistory;
        for (record.id) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return error.InvalidReminderHistory;
        var valid = false;
        for ([_][]const u8{ "pending", "claimed", "sent", "failed", "missed", "retry", "canceled" }) |status| if (std.mem.eql(u8, record.status, status)) {
            valid = true;
        };
        if (!valid) return error.InvalidReminderHistory;
    }
    return store;
}
fn save(a: A, config: []const u8, storage: []const u8, store: Store) !void {
    try std.fs.cwd().makePath(config);
    try atomic(a, try statePath(a, config, storage), try std.json.Stringify.valueAlloc(a, store, .{}));
}
fn recordFor(records: []Delivery, id: []const u8, due: i64) ?usize {
    for (records, 0..) |item, i| if (item.due == due and std.mem.eql(u8, item.id, id)) return i;
    return null;
}
pub fn scheduled(a: A, config: []const u8, storage: []const u8, plan: Plan) !void {
    if (plan.id.len == 0) return;
    if (!std.mem.eql(u8, plan.after, try read(a, try path(a, storage, "tasks.md")))) return error.DocumentChanged;
    var store = try load(a, config, storage);
    var records: std.ArrayList(Delivery) = .empty;
    try records.appendSlice(a, store.records);
    for (records.items) |*item| if (std.mem.eql(u8, item.id, plan.id) and std.mem.eql(u8, item.status, "pending")) {
        item.status = "canceled";
    };
    if (plan.due > 0) {
        if (recordFor(records.items, plan.id, plan.due)) |i| records.items[i].status = "pending" else try records.append(a, .{ .id = plan.id, .due = plan.due });
    }
    if (records.items.len > 1000) return error.ReminderHistoryTooLarge;
    store.records = records.items;
    try save(a, config, storage, store);
}
fn reconcile(a: A, store: *Store, items: []const Task) !void {
    var records: std.ArrayList(Delivery) = .empty;
    try records.appendSlice(a, store.records);
    for (items) |task| if (task.due > 0 and recordFor(records.items, task.id, task.due) == null) try records.append(a, .{ .id = task.id, .due = task.due });
    for (records.items) |*record| {
        if (!std.mem.eql(u8, record.status, "pending")) continue;
        var live = false;
        for (items) |task| if (task.due == record.due and std.mem.eql(u8, task.id, record.id) and !task.done) {
            live = true;
        };
        if (!live) record.status = "canceled";
    }
    if (records.items.len > 1000) return error.ReminderHistoryTooLarge;
    store.records = records.items;
}
fn cancel(_: c_int) callconv(.c) void {
    @import("terminal.zig").cancelSession();
}
fn exec(a: A, argv: []const []const u8) !void {
    const signals = try platform.SignalGuard.install(cancel);
    defer signals.restore();
    var child = std.process.Child.init(argv, a);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    var group = try platform.ChildGroup.spawn(&child);
    defer group.close();
    @import("terminal.zig").trackHttp(child.id);
    defer @import("terminal.zig").clearHttp();
    try child.waitForSpawn();
    var timer = try std.time.Timer.start();
    while (timer.read() < 5 * std.time.ns_per_s) {
        if (@import("terminal.zig").cancelled()) break;
        if (builtin.os.tag == .windows) {
            if (group.done(&child)) {
                const term = try child.wait();
                group.terminate(&child);
                if (term != .Exited or term.Exited != 0) return error.ReminderCommandFailed;
                return;
            }
        } else {
            const result = std.posix.waitpid(child.id, std.posix.W.NOHANG);
            if (result.pid != 0) {
                group.terminate(&child);
                if (!std.posix.W.IFEXITED(result.status) or std.posix.W.EXITSTATUS(result.status) != 0) return error.ReminderCommandFailed;
                return;
            }
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    group.terminate(&child);
    _ = child.wait() catch {};
    return error.ReminderCommandTimedOut;
}
fn notificationFile(a: A, file_path: []const u8, bytes: []const u8) !void {
    const file = try std.fs.cwd().createFile(file_path, .{ .exclusive = true, .mode = 0o600 });
    defer file.close();
    try platform.privateFile(a, file_path);
    try file.writeAll(bytes);
}
fn notify(a: A, config: []const u8, text: []const u8) !void {
    const clean = try @import("terminal.zig").clean(a, text, false);
    if (builtin.os.tag == .macos) return exec(a, &.{ "osascript", "-e", "on run argv\ndisplay notification (item 1 of argv) with title \"doin\"\nend run", "--", clean });
    if (builtin.os.tag == .linux) return exec(a, &.{ "notify-send", "--", "doin", clean });
    if (builtin.os.tag == .windows) {
        var nonce: [8]u8 = undefined;
        std.crypto.random.bytes(&nonce);
        const payload = try path(a, config, try std.fmt.allocPrint(a, "notify-{x}.json", .{nonce}));
        defer std.fs.cwd().deleteFile(payload) catch {};
        const script = try path(a, config, try std.fmt.allocPrint(a, "notify-{x}.ps1", .{nonce}));
        defer std.fs.cwd().deleteFile(script) catch {};
        try notificationFile(a, payload, try std.json.Stringify.valueAlloc(a, .{ .text = clean }, .{}));
        try notificationFile(a, script,
            \\param([Parameter(Mandatory=$true)][string]$Payload)
            \\$ErrorActionPreference = 'Stop'
            \\Add-Type -AssemblyName System.Windows.Forms
            \\Add-Type -AssemblyName System.Drawing
            \\$data = [System.IO.File]::ReadAllText($Payload, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            \\$icon = New-Object System.Windows.Forms.NotifyIcon
            \\try {
            \\  $icon.Icon = [System.Drawing.SystemIcons]::Information
            \\  $icon.Visible = $true
            \\  $icon.ShowBalloonTip(3000, 'doin', [string]$data.text, [System.Windows.Forms.ToolTipIcon]::Info)
            \\  $until = [DateTime]::UtcNow.AddMilliseconds(2500)
            \\  while ([DateTime]::UtcNow -lt $until) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 25 }
            \\} finally { $icon.Dispose() }
        );
        if (try platform.env(a, "DOIN_REMINDER_NOTIFIER")) |fixture| return exec(a, &.{ fixture, payload, script });
        return exec(a, &.{ "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-Payload", payload });
    }
    return error.ReminderNotificationsUnsupported;
}
fn out(text: []const u8) !void {
    try std.fs.File.stdout().writeAll(text);
}
fn cleanOut(a: A, text: []const u8) !void {
    try out(try @import("terminal.zig").clean(a, text, false));
}
fn enable(a: A, config: []const u8, storage: []const u8, store: *Store, manual: bool) !void {
    if (manual) {
        if (store.scheduler) return error.ReminderDisableSchedulerFirst;
        store.enabled = true;
        try save(a, config, storage, store.*);
        return out("Reminders on for manual checks. No background job installed.\n");
    }
    if (store.scheduler) return out("Reminders already on.\n");
    const job: scheduler.Job = .{ .kind = .reminders, .config_dir = config, .storage = storage };
    try scheduler.enable(a, job);
    store.enabled = true;
    store.scheduler = true;
    save(a, config, storage, store.*) catch |err| {
        scheduler.disable(a, job) catch {};
        return err;
    };
    try out("Reminders on. Checks every minute while logged in.\n");
}
pub fn run(a: A, args: []const []const u8, config: []const u8, storage: []const u8) !void {
    const cmd = if (args.len > 0) args[0] else "list";
    if (std.mem.eql(u8, cmd, "check")) if (try platform.env(a, "DOIN_JOB_STORAGE")) |expected| if (!std.mem.eql(u8, expected, storage)) return error.BackgroundStorageChanged;
    const lock = try std.fs.cwd().createFile(try path(a, storage, ".tasks.lock"), .{ .truncate = false, .mode = 0o600 });
    defer lock.close();
    if (!try platform.tryLockExclusive(lock)) return error.StorageBusy;
    var store = try load(a, config, storage);
    if (std.mem.eql(u8, cmd, "status")) {
        try out(if (store.enabled) "Reminders on" else "Reminders off");
        const os = try scheduler.status(a, .{ .kind = .reminders, .config_dir = config, .storage = storage });
        return out(if (os.active) " · background timer registered.\n" else if (os.installed) " · background job installed, inactive.\n" else " · no background job.\n");
    }
    if (std.mem.eql(u8, cmd, "enable")) {
        if (args.len > 2 or (args.len == 2 and !std.mem.eql(u8, args[1], "--manual"))) return error.InvalidReminderArguments;
        return enable(a, config, storage, &store, args.len == 2);
    }
    if (std.mem.eql(u8, cmd, "disable")) {
        if (args.len != 1) return error.InvalidReminderArguments;
        store.enabled = false;
        try save(a, config, storage, store);
        const job: scheduler.Job = .{ .kind = .reminders, .config_dir = config, .storage = storage };
        const os = try scheduler.status(a, job);
        if (store.scheduler or os.installed or os.active) {
            try scheduler.disable(a, job);
            store.scheduler = false;
            try save(a, config, storage, store);
        }
        return out("Reminders off.\n");
    }
    const doc_path = try path(a, storage, "tasks.md");
    const before = try read(a, doc_path);
    const items = try tasks(a, before);
    try unique(items);
    try reconcile(a, &store, items);
    if (std.mem.eql(u8, cmd, "list")) {
        for (store.records) |record| {
            try out(try std.fmt.allocPrint(a, "  {s}  {s}  ", .{ try label(a, record.due), if (std.mem.eql(u8, record.status, "claimed")) "needs review" else if (std.mem.eql(u8, record.status, "sent")) "delivered" else if (std.mem.eql(u8, record.status, "pending")) "scheduled" else record.status }));
            var found = false;
            for (items, 0..) |task, i| if (std.mem.eql(u8, task.id, record.id)) {
                try out(try std.fmt.allocPrint(a, "#{d} ", .{i + 1}));
                try cleanOut(a, task.text);
                found = true;
                break;
            };
            if (!found) try out("[removed task]");
            try out("\n");
        }
        return;
    }
    if (std.mem.eql(u8, cmd, "retry")) {
        if (args.len != 2) return error.InvalidReminderArguments;
        const index = std.fmt.parseInt(usize, args[1], 10) catch return error.InvalidReminderArguments;
        if (index == 0 or index > items.len) return error.TaskNotFound;
        const task = items[index - 1];
        if (task.done) return error.ReminderTaskCompleted;
        const i = recordFor(store.records, task.id, task.due) orelse return error.ReminderNotFound;
        if (!std.mem.eql(u8, store.records[i].status, "failed") and !std.mem.eql(u8, store.records[i].status, "missed") and !std.mem.eql(u8, store.records[i].status, "claimed")) return error.ReminderNotFailed;
        store.records[i].status = "retry";
        try save(a, config, storage, store);
        return out("Reminder will retry on the next check.\n");
    }
    if (!std.mem.eql(u8, cmd, "check") or args.len != 1) return error.InvalidReminderArguments;
    if (!store.enabled) return out("Reminders off. Use remind enable or remind enable --manual to opt in.\n");
    const current = try now();
    var attempted: usize = 0;
    var failed = false;
    for (store.records) |*record| {
        const retry = std.mem.eql(u8, record.status, "retry");
        if ((!std.mem.eql(u8, record.status, "pending") and !retry) or record.due > current) continue;
        if (!retry and current - record.due > 86400) {
            record.status = "missed";
            continue;
        }
        if (attempted >= 5) break;
        var selected: ?Task = null;
        for (items) |task| if (task.due == record.due and std.mem.eql(u8, task.id, record.id) and !task.done) {
            selected = task;
            break;
        };
        const task = selected orelse {
            record.status = "canceled";
            continue;
        };
        if (!std.mem.eql(u8, before, try read(a, doc_path))) return error.DocumentChanged;
        // Persist a claim before the OS call; interrupted attempts cannot repeat silently.
        record.status = "claimed";
        record.attempted_at = current;
        try save(a, config, storage, store);
        notify(a, config, task.text) catch {
            record.status = "failed";
            failed = true;
            attempted += 1;
            try save(a, config, storage, store);
            continue;
        };
        record.status = "sent";
        attempted += 1;
        try save(a, config, storage, store);
    }
    try save(a, config, storage, store);
    if (failed) return error.ReminderNotificationFailed;
}
