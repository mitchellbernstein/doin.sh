//! Shared local calendar; POSIX timezone conversion stays isolated from Windows ABI.
const std = @import("std");
const builtin = @import("builtin");
const A = std.mem.Allocator;
pub const Date = struct { year: i32, month: i32, day: i32, hour: i32 = 0, minute: i32 = 0, second: i32 = 0, weekday: i32 = 0 };
const Tm = extern struct { sec: c_int = 0, min: c_int = 0, hour: c_int = 0, day: c_int = 1, month: c_int = 0, year: c_int = 70, weekday: c_int = 0, yearday: c_int = 0, dst: c_int = -1, offset: c_long = 0, zone: ?[*:0]const u8 = null };
extern "c" fn mktime(t: *Tm) i64;
extern "c" fn localtime_r(timestamp: *const i64, t: *Tm) ?*Tm;
const SystemTime = extern struct { year: u16 = 0, month: u16 = 0, weekday: u16 = 0, day: u16 = 0, hour: u16 = 0, minute: u16 = 0, second: u16 = 0, millisecond: u16 = 0 };
const ZoneInfo = extern struct { bias: i32 = 0, standard_name: [32]u16 = @splat(0), standard_date: SystemTime = .{}, standard_bias: i32 = 0, daylight_name: [32]u16 = @splat(0), daylight_date: SystemTime = .{}, daylight_bias: i32 = 0 };
const DynamicZone = extern struct { bias: i32 = 0, standard_name: [32]u16 = @splat(0), standard_date: SystemTime = .{}, standard_bias: i32 = 0, daylight_name: [32]u16 = @splat(0), daylight_date: SystemTime = .{}, daylight_bias: i32 = 0, key: [128]u16 = @splat(0), disabled: u8 = 0 };
extern "kernel32" fn GetDynamicTimeZoneInformation(zone: *DynamicZone) callconv(.winapi) u32;
extern "kernel32" fn EnumDynamicTimeZoneInformation(index: u32, zone: *DynamicZone) callconv(.winapi) u32;
extern "kernel32" fn GetTimeZoneInformationForYear(year: u16, zone: *DynamicZone, info: *ZoneInfo) callconv(.winapi) i32;
extern "kernel32" fn SystemTimeToTzSpecificLocalTimeEx(zone: *const DynamicZone, utc: *const SystemTime, local: *SystemTime) callconv(.winapi) i32;
fn zone() !DynamicZone {
    var result: DynamicZone = .{};
    const chosen = std.process.getEnvVarOwned(std.heap.page_allocator, "DOIN_CALENDAR_TIMEZONE") catch null;
    defer if (chosen) |name| std.heap.page_allocator.free(name);
    if (chosen) |name| {
        var index: u32 = 0;
        while (index < 1000) : (index += 1) {
            if (EnumDynamicTimeZoneInformation(index, &result) != 0) break;
            const end = std.mem.indexOfScalar(u16, &result.key, 0) orelse result.key.len;
            const key = try std.unicode.utf16LeToUtf8Alloc(std.heap.page_allocator, result.key[0..end]);
            defer std.heap.page_allocator.free(key);
            if (std.mem.eql(u8, name, key)) return result;
        }
        return error.InvalidCalendarTimezone;
    }
    if (GetDynamicTimeZoneInformation(&result) == 0xffffffff) return error.InvalidReminderTime;
    return result;
}
fn leap(year: i32) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}
fn monthDays(year: i32, month: i32) !i32 {
    if (month < 1 or month > 12) return error.InvalidReminderTime;
    const counts = [_]i32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return counts[@intCast(month - 1)] + @as(i32, if (month == 2 and leap(year)) 1 else 0);
}
fn days(date: Date) !i64 {
    if (date.year < 1970 or date.year > 9999 or date.day < 1 or date.day > try monthDays(date.year, date.month) or date.hour < 0 or date.hour > 23 or date.minute < 0 or date.minute > 59 or date.second < 0 or date.second > 59) return error.InvalidReminderTime;
    const year = @as(i64, date.year) - @as(i64, if (date.month <= 2) 1 else 0);
    const era = @divFloor(year, 400);
    const yoe = year - era * 400;
    const month = @as(i64, date.month) + (if (date.month > 2) @as(i64, -3) else 9);
    const doy = @divFloor(153 * month + 2, 5) + date.day - 1;
    return era * 146097 + yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy - 719468;
}
fn utc(date: Date) !i64 {
    return try days(date) * 86400 + @as(i64, date.hour) * 3600 + @as(i64, date.minute) * 60 + date.second;
}
fn civil(instant: i64) !Date {
    if (instant < 0 or instant > 253402300799) return error.InvalidReminderTime;
    const day_count = @divFloor(instant, 86400);
    const z = day_count + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const month = mp + (if (mp < 10) @as(i64, 3) else -9);
    const seconds = @mod(instant, 86400);
    return .{ .year = @intCast(y + @as(i64, if (month <= 2) 1 else 0)), .month = @intCast(month), .day = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1), .hour = @intCast(@divTrunc(seconds, 3600)), .minute = @intCast(@divTrunc(@mod(seconds, 3600), 60)), .second = @intCast(@mod(seconds, 60)), .weekday = @intCast(@mod(day_count + 4, 7)) };
}
fn system(date: Date) SystemTime {
    return .{ .year = @intCast(date.year), .month = @intCast(date.month), .day = @intCast(date.day), .hour = @intCast(date.hour), .minute = @intCast(date.minute), .second = @intCast(date.second) };
}
fn fromSystem(t: SystemTime) Date {
    return .{ .year = t.year, .month = t.month, .day = t.day, .hour = t.hour, .minute = t.minute, .second = t.second, .weekday = t.weekday };
}
fn same(x: Date, y: Date) bool {
    return x.year == y.year and x.month == y.month and x.day == y.day and x.hour == y.hour and x.minute == y.minute and x.second == y.second;
}
pub fn utcComponents(instant: i64) !Date {
    return civil(instant);
}
pub fn components(instant: i64) !Date {
    if (builtin.os.tag == .windows) {
        const tz = try zone();
        const input = system(try civil(instant));
        var output: SystemTime = .{};
        if (SystemTimeToTzSpecificLocalTimeEx(&tz, &input, &output) == 0) return error.InvalidReminderTime;
        return fromSystem(output);
    } else {
        var t: Tm = .{};
        if (localtime_r(&instant, &t) == null) return error.InvalidReminderTime;
        return .{ .year = t.year + 1900, .month = t.month + 1, .day = t.day, .hour = t.hour, .minute = t.min, .second = t.sec, .weekday = t.weekday };
    }
}
fn local(date: Date) !i64 {
    var first: ?i64 = null;
    if (builtin.os.tag == .windows) {
        var tz = try zone();
        var info: ZoneInfo = .{};
        if (GetTimeZoneInformationForYear(@intCast(date.year), &tz, &info) == 0) return error.InvalidReminderTime;
        for ([_]i32{ info.standard_bias, if (tz.disabled != 0 or info.daylight_date.month == 0) info.standard_bias else info.daylight_bias }) |extra| {
            const candidate = try utc(date) + (@as(i64, info.bias) + extra) * 60;
            const input = system(civil(candidate) catch continue);
            var output: SystemTime = .{};
            if (SystemTimeToTzSpecificLocalTimeEx(&tz, &input, &output) == 0 or !same(date, fromSystem(output))) continue;
            if (first) |previous| {
                if (previous != candidate) return error.AmbiguousReminderTime;
            } else first = candidate;
        }
    } else {
        for ([_]c_int{ 0, 1 }) |dst| {
            var t: Tm = .{ .year = date.year - 1900, .month = date.month - 1, .day = date.day, .hour = date.hour, .min = date.minute, .sec = date.second, .dst = dst };
            const candidate = mktime(&t);
            if (candidate == -1) continue;
            if (!same(date, try components(candidate))) continue;
            if (first) |previous| {
                if (previous != candidate) return error.AmbiguousReminderTime;
            } else first = candidate;
        }
    }
    return first orelse error.NonexistentReminderTime;
}
pub fn now() !i64 {
    const override = std.process.getEnvVarOwned(std.heap.page_allocator, "DOIN_REMINDER_NOW") catch null;
    defer if (override) |text| std.heap.page_allocator.free(text);
    const current = if (override) |text| std.fmt.parseInt(i64, text, 10) catch return error.InvalidReminderClock else std.time.timestamp();
    if (current < 0 or current > 253370678399) return error.InvalidReminderClock;
    return current;
}
fn num(text: []const u8) !i32 {
    if (text.len == 0) return error.InvalidReminderTime;
    for (text) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidReminderTime;
    return std.fmt.parseInt(i32, text, 10) catch error.InvalidReminderTime;
}
fn parsed(text: []const u8) !Date {
    if (text.len < 16 or text[4] != '-' or text[7] != '-' or (text[10] != ' ' and text[10] != 'T') or text[13] != ':') return error.InvalidReminderTime;
    var date: Date = .{ .year = try num(text[0..4]), .month = try num(text[5..7]), .day = try num(text[8..10]), .hour = try num(text[11..13]), .minute = try num(text[14..16]) };
    if (text.len > 16) {
        if (text.len < 19 or text[16] != ':') return error.InvalidReminderTime;
        date.second = try num(text[17..19]);
    }
    _ = try days(date);
    return date;
}
pub fn parse(text: []const u8, current: i64) !i64 {
    const input = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, input, "in ")) {
        const duration = input[3..];
        if (duration.len < 2) return error.InvalidReminderTime;
        const quantity = std.fmt.parseInt(i64, duration[0 .. duration.len - 1], 10) catch return error.InvalidReminderTime;
        const factor: i64 = switch (duration[duration.len - 1]) {
            'm' => 60,
            'h' => 3600,
            'd' => 86400,
            else => return error.InvalidReminderTime,
        };
        if (quantity <= 0 or quantity > @divTrunc(366 * 86400, factor)) return error.InvalidReminderTime;
        return current + quantity * factor;
    }
    if (std.mem.startsWith(u8, input, "tomorrow ")) {
        if (input.len != 14 or input[11] != ':') return error.InvalidReminderTime;
        const date = try components(current);
        var tomorrow = try civil((try days(date) + 1) * 86400);
        tomorrow.hour = try num(input[9..11]);
        tomorrow.minute = try num(input[12..14]);
        _ = try days(tomorrow);
        return local(tomorrow);
    }
    const date = try parsed(input);
    if (input.len == 16) return local(date);
    if (input.len == 20 and input[19] == 'Z') return utc(date);
    if (input.len != 25 or (input[19] != '+' and input[19] != '-') or input[22] != ':') return error.InvalidReminderTime;
    const hours = try num(input[20..22]);
    const minutes = try num(input[23..25]);
    if (hours > 23 or minutes > 59) return error.InvalidReminderTime;
    const offset = @as(i64, hours) * 3600 + @as(i64, minutes) * 60;
    return try utc(date) - (if (input[19] == '+') offset else -offset);
}
pub fn format(a: A, instant: i64) ![]const u8 {
    const d = try components(instant);
    var suffix: []const u8 = "local";
    if (builtin.os.tag != .windows) {
        var t: Tm = .{};
        if (localtime_r(&instant, &t) == null) return error.InvalidReminderTime;
        if (t.zone) |name| suffix = std.mem.span(name);
    }
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} {s}", .{ @as(u32, @intCast(d.year)), @as(u32, @intCast(d.month)), @as(u32, @intCast(d.day)), @as(u32, @intCast(d.hour)), @as(u32, @intCast(d.minute)), suffix });
}
pub fn dateLimit(a: A, scope: []const u8) ![]const u8 {
    var date = try components(try now());
    if (std.mem.eql(u8, scope, "week")) date = try civil((try days(date) + @mod(7 - date.weekday, 7)) * 86400) else if (std.mem.eql(u8, scope, "month")) date.day = try monthDays(date.year, date.month) else if (!std.mem.eql(u8, scope, "today")) return error.InvalidTaskFilter;
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(date.year)), @as(u32, @intCast(date.month)), @as(u32, @intCast(date.day)) });
}
