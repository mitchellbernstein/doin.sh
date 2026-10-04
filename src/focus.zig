const std = @import("std");
const productivity = @import("productivity.zig");
const reminders = @import("reminders.zig");
const platform = @import("platform.zig");
const A = std.mem.Allocator;

const state_file_limit = 4096;
const next_step_limit = 280;
const id_len = 32;

pub const State = struct {
    date: []const u8,
    task_id: []const u8,
    next_step: ?[]const u8 = null,
};

pub const Active = struct {
    state: State,
    number: usize,
    text: []const u8,
};

pub const View = union(enum) {
    inactive,
    expired: State,
    active: Active,
    completed: Active,
    missing: State,
};

pub const Plan = struct {
    markdown: []const u8,
    state: State,
};

pub const Recommendation = struct {
    task_number: usize,
    reason: []const u8,
    next_step: []const u8,
};

const Identity = struct { start: usize, id: []const u8 };

fn validId(id: []const u8) bool {
    if (id.len != id_len) return false;
    for (id) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

fn validDate(date: []const u8) bool {
    if (date.len != 10 or date[4] != '-' or date[7] != '-') return false;
    for (date, 0..) |c, i| if (i != 4 and i != 7 and !std.ascii.isDigit(c)) return false;
    const year = std.fmt.parseInt(u16, date[0..4], 10) catch return false;
    const month = std.fmt.parseInt(u8, date[5..7], 10) catch return false;
    const day = std.fmt.parseInt(u8, date[8..10], 10) catch return false;
    if (year == 0 or month == 0 or month > 12) return false;
    const month_days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const leap = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
    const maximum = month_days[month - 1] + @as(u8, if (month == 2 and leap) 1 else 0);
    return day > 0 and day <= maximum;
}

fn validNextStep(text: []const u8) bool {
    if (text.len == 0 or text.len > next_step_limit) return false;
    for (text) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

fn validateState(state: State) !void {
    if (!validDate(state.date)) return error.InvalidFocusDate;
    if (!validId(state.task_id)) return error.InvalidFocusTaskID;
    if (state.next_step) |step| if (!validNextStep(step)) return error.InvalidFocusNextStep;
}

fn statePath(a: A, config_dir: []const u8, storage: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(storage, &digest, .{});
    const name = try std.fmt.allocPrint(a, "focus-{x}.json", .{digest[0..8]});
    defer a.free(name);
    return std.fs.path.join(a, &.{ config_dir, name });
}

fn atomicWrite(a: A, path: []const u8, bytes: []const u8) !void {
    var nonce: [8]u8 = undefined;
    std.crypto.random.bytes(&nonce);
    const tmp = try std.fmt.allocPrint(a, "{s}.{x}.tmp", .{ path, nonce });
    defer a.free(tmp);
    defer std.fs.cwd().deleteFile(tmp) catch {};
    {
        const file = try std.fs.cwd().createFile(tmp, .{ .exclusive = true, .mode = 0o600 });
        defer file.close();
        try platform.privateFile(a, tmp);
        try file.writeAll(bytes);
        try file.sync();
    }
    try std.fs.cwd().rename(tmp, path);
}

pub fn load(a: A, config_dir: []const u8, storage: []const u8) !?State {
    const path = try statePath(a, config_dir, storage);
    const bytes = std.fs.cwd().readFileAlloc(a, path, state_file_limit) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer a.free(bytes);
    var parsed = std.json.parseFromSlice(State, a, bytes, .{ .allocate = .alloc_always }) catch return error.InvalidFocusState;
    defer parsed.deinit();
    try validateState(parsed.value);
    return .{
        .date = try a.dupe(u8, parsed.value.date),
        .task_id = try a.dupe(u8, parsed.value.task_id),
        .next_step = if (parsed.value.next_step) |step| try a.dupe(u8, step) else null,
    };
}

pub fn save(a: A, config_dir: []const u8, storage: []const u8, state: State) !void {
    try validateState(state);
    try std.fs.cwd().makePath(config_dir);
    const path = try statePath(a, config_dir, storage);
    const bytes = try std.json.Stringify.valueAlloc(a, state, .{});
    defer a.free(bytes);
    try atomicWrite(a, path, bytes);
}

pub fn clear(a: A, config_dir: []const u8, storage: []const u8) !void {
    const path = try statePath(a, config_dir, storage);
    std.fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
}

fn lineIdentity(line_with_newline: []const u8) !?Identity {
    const ending: usize = if (std.mem.endsWith(u8, line_with_newline, "\r\n")) 2 else if (std.mem.endsWith(u8, line_with_newline, "\n")) 1 else 0;
    const line = std.mem.trimEnd(u8, line_with_newline[0 .. line_with_newline.len - ending], " \t\r");
    var found: ?Identity = null;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, line, cursor, "<!-- doin:id=")) |start| {
        const close_relative = std.mem.indexOf(u8, line[start..], "-->") orelse return error.InvalidFocusTaskID;
        const close = start + close_relative;
        const body_end = if (close > start and line[close - 1] == ' ') close - 1 else close;
        const body = line[start + "<!-- doin:id=".len .. body_end];
        if (body.len < id_len or !validId(body[0..id_len])) return error.InvalidFocusTaskID;
        if (body.len > id_len) {
            if (!std.mem.startsWith(u8, body[id_len..], " remind=")) return error.InvalidFocusTaskID;
            const digits = body[id_len + 8 ..];
            if (digits.len == 0) return error.InvalidFocusTaskID;
            for (digits) |c| if (!std.ascii.isDigit(c)) return error.InvalidFocusTaskID;
            const due = std.fmt.parseInt(i64, digits, 10) catch return error.InvalidFocusTaskID;
            if (due <= 0 or due > 253402300799) return error.InvalidFocusTaskID;
        }
        if (close + 3 != line.len) return error.InvalidFocusTaskID;
        if (found != null) return error.AmbiguousStableID;
        found = .{ .start = start, .id = body[0..id_len] };
        cursor = close + 3;
    }
    return found;
}

const TaskIdentity = struct { number: usize, task: productivity.Task, id: ?[]const u8 };

fn taskIdentities(a: A, markdown: []const u8) ![]TaskIdentity {
    const tasks = try productivity.parse(a, markdown);
    defer a.free(tasks);
    const result = try a.alloc(TaskIdentity, tasks.len);
    for (tasks, 0..) |task, index| {
        const identity = try lineIdentity(markdown[task.start..task.end]);
        result[index] = .{ .number = task.number, .task = task, .id = if (identity) |value| value.id else null };
    }
    for (result, 0..) |current, index| if (current.id) |id| {
        for (result[index + 1 ..]) |other| if (other.id) |other_id| {
            if (std.mem.eql(u8, id, other_id)) return error.AmbiguousStableID;
        };
    };
    return result;
}

fn taskForID(a: A, markdown: []const u8, id: []const u8) !?TaskIdentity {
    const tasks = try taskIdentities(a, markdown);
    defer a.free(tasks);
    var result: ?TaskIdentity = null;
    for (tasks) |task| if (task.id) |task_id| {
        if (std.mem.eql(u8, id, task_id)) {
            if (result != null) return error.AmbiguousStableID;
            result = task;
        }
    };
    return result;
}

fn validRecommendationText(text: []const u8, maximum: usize) bool {
    if (text.len == 0 or text.len > maximum or !std.unicode.utf8ValidateSlice(text)) return false;
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return false;
    for (text) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

pub fn recommendation(a: A, raw: []const u8, markdown: []const u8) !Recommendation {
    if (raw.len == 0 or raw.len > 4096 or !std.unicode.utf8ValidateSlice(raw)) return error.InvalidFocusRecommendation;
    var parsed = std.json.parseFromSlice(std.json.Value, a, raw, .{}) catch return error.InvalidFocusRecommendation;
    defer parsed.deinit();
    const value = parsed.value;
    if (value != .object or value.object.count() != 3) return error.InvalidFocusRecommendation;
    const number_value = value.object.get("task_number") orelse return error.InvalidFocusRecommendation;
    const reason_value = value.object.get("reason") orelse return error.InvalidFocusRecommendation;
    const step_value = value.object.get("next_step") orelse return error.InvalidFocusRecommendation;
    if (number_value != .integer or number_value.integer <= 0) return error.InvalidFocusRecommendation;
    if (reason_value != .string or !validRecommendationText(reason_value.string, 600)) return error.InvalidFocusRecommendation;
    if (step_value != .string or !validRecommendationText(step_value.string, 240)) return error.InvalidFocusRecommendation;
    const number = std.math.cast(usize, number_value.integer) orelse return error.InvalidFocusRecommendation;
    const tasks = taskIdentities(a, markdown) catch return error.InvalidFocusRecommendation;
    defer a.free(tasks);
    if (number > tasks.len or tasks[number - 1].task.completed) return error.InvalidFocusRecommendation;
    return .{
        .task_number = number,
        .reason = try a.dupe(u8, reason_value.string),
        .next_step = try a.dupe(u8, step_value.string),
    };
}

pub fn inspect(a: A, markdown: []const u8, state: ?State, today: []const u8) !View {
    if (!validDate(today)) return error.InvalidFocusDate;
    const current = state orelse return .inactive;
    try validateState(current);
    if (!std.mem.eql(u8, current.date, today)) return .{ .expired = current };
    const task = (try taskForID(a, markdown, current.task_id)) orelse return .{ .missing = current };
    const active = Active{ .state = current, .number = task.number, .text = task.task.text };
    if (task.task.completed) return .{ .completed = active };
    return .{ .active = active };
}

pub fn choose(a: A, markdown: []const u8, number: usize, date: []const u8) !Plan {
    if (!validDate(date)) return error.InvalidFocusDate;
    const tasks = try taskIdentities(a, markdown);
    defer a.free(tasks);
    if (number == 0 or number > tasks.len) return error.TaskNotFound;
    const chosen = tasks[number - 1];
    if (chosen.task.completed) return error.FocusTaskCompleted;

    const id = if (chosen.id) |existing| existing else blk: {
        var bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&bytes);
        break :blk try std.fmt.allocPrint(a, "{x}", .{bytes});
    };
    if (chosen.id != null) {
        const markdown_with_same_id = try taskForID(a, markdown, id);
        if (markdown_with_same_id == null) return error.FocusTaskNotFound;
    }

    const state = State{ .date = date, .task_id = id };
    if (chosen.id) |existing| return .{ .markdown = markdown, .state = .{ .date = date, .task_id = existing } };

    const line = markdown[chosen.task.start..chosen.task.end];
    const ending = if (std.mem.endsWith(u8, line, "\r\n")) "\r\n" else if (std.mem.endsWith(u8, line, "\n")) "\n" else "";
    const content = line[0 .. line.len - ending.len];
    const after = try std.fmt.allocPrint(a, "{s}{s} <!-- doin:id={s} -->{s}{s}", .{
        markdown[0..chosen.task.start], content, id, ending, markdown[chosen.task.end..],
    });
    return .{ .markdown = after, .state = state };
}

pub fn complete(a: A, markdown: []const u8, state: State) !Plan {
    try validateState(state);
    const task = (try taskForID(a, markdown, state.task_id)) orelse return error.FocusTaskNotFound;
    if (task.task.completed) return error.FocusTaskCompleted;
    const proposal = try productivity.mark(a, markdown, task.number, "done");
    return .{ .markdown = proposal.markdown, .state = state };
}
