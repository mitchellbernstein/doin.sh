const std = @import("std");
const platform = @import("platform.zig");
const A = std.mem.Allocator;

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn equal(left: Rgb, right: Rgb) bool {
        return left.r == right.r and left.g == right.g and left.b == right.b;
    }
};

pub const CacheEntry = struct {
    account_id: []const u8,
    endpoint_hash: []const u8,
    token_hash: []const u8,
    accent: ?[]const u8 = null,
    revision: i64 = 0,
    pending: bool = false,
};
pub const PendingEntry = struct {
    endpoint_hash: []const u8,
    token_hash: []const u8,
    accent: ?[]const u8 = null,
};

pub const Ansi = struct {
    bytes: [32]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Ansi) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Selection = struct {
    background: Ansi = .{},
    chevron: Ansi = .{},
    foreground: Ansi = .{},
    colored: bool = false,
    override_foreground: bool = false,
};

pub fn parseHex(value: []const u8) !Rgb {
    const text = if (value.len == 7 and value[0] == '#') value[1..] else if (value.len == 6) value else return error.InvalidThemeAccent;
    for (text) |ch| if (!std.ascii.isHex(ch)) return error.InvalidThemeAccent;
    return .{
        .r = try std.fmt.parseInt(u8, text[0..2], 16),
        .g = try std.fmt.parseInt(u8, text[2..4], 16),
        .b = try std.fmt.parseInt(u8, text[4..6], 16),
    };
}

pub fn canonical(a: A, value: []const u8) ![]const u8 {
    const color = try parseHex(value);
    return std.fmt.allocPrint(a, "#{X:0>2}{X:0>2}{X:0>2}", .{ color.r, color.g, color.b });
}

pub fn ansiSelection(accent_value: ?[]const u8, terminal_background: ?Rgb, terminal_foreground: ?Rgb) Selection {
    const default_primary = Rgb{ .r = 150, .g = 150, .b = 150 };
    const primary = if (accent_value) |value| parseHex(value) catch default_primary else default_primary;
    const background = terminal_background orelse {
        const fallback_base = Rgb{ .r = 18, .g = 20, .b = 24 };
        const fallback_bg = mix(primary, fallback_base, 0.84);
        const fallback_fg = Rgb{ .r = 240, .g = 242, .b = 245 };
        const arrow = ensureContrast(mix(primary, fallback_fg, 0.42), fallback_bg, fallback_fg, 3.2);
        return .{ .background = sgr(48, fallback_bg), .chevron = sgr(38, arrow), .foreground = sgr(38, fallback_fg), .colored = true, .override_foreground = true };
    };
    const is_light = luminance(background) > 0.42;
    const foreground = terminal_foreground orelse if (is_light) Rgb{ .r = 24, .g = 24, .b = 24 } else Rgb{ .r = 238, .g = 238, .b = 238 };
    var dim = mix(primary, background, if (is_light) 0.86 else 0.80);
    if (distance(dim, background) < 12) {
        const neutral = if (is_light) Rgb{ .r = 238, .g = 238, .b = 238 } else Rgb{ .r = 34, .g = 34, .b = 34 };
        dim = mix(primary, neutral, 0.90);
    }
    dim = ensureContrast(dim, foreground, background, 4.5);
    const target = if (luminance(dim) > luminance(foreground)) Rgb{ .r = 24, .g = 24, .b = 24 } else Rgb{ .r = 240, .g = 240, .b = 240 };
    const arrow = ensureContrast(mix(primary, target, 0.42), dim, target, 3.2);
    const fg_override = contrast(foreground, dim) < 4.5;
    return .{
        .background = sgr(48, dim),
        .chevron = sgr(38, arrow),
        .foreground = if (fg_override) sgr(38, foreground) else .{},
        .colored = true,
        .override_foreground = fg_override,
    };
}

pub fn ansiSecondary(terminal_background: ?Rgb, terminal_foreground: ?Rgb) Ansi {
    const background = terminal_background orelse return .{};
    const foreground = terminal_foreground orelse if (luminance(background) > 0.42) Rgb{ .r = 24, .g = 24, .b = 24 } else Rgb{ .r = 238, .g = 238, .b = 238 };
    const softened = mix(foreground, background, 0.38);
    return sgr(38, ensureContrast(softened, background, foreground, 4.5));
}

pub fn luminance(color: Rgb) f64 {
    return channelLuminance(color.r) * 0.2126 + channelLuminance(color.g) * 0.7152 + channelLuminance(color.b) * 0.0722;
}

fn contrast(foreground: Rgb, background: Rgb) f64 {
    const light = @max(luminance(foreground), luminance(background)) + 0.05;
    const dark = @min(luminance(foreground), luminance(background)) + 0.05;
    return light / dark;
}

fn channelLuminance(channel: u8) f64 {
    const value: f64 = @as(f64, @floatFromInt(channel)) / 255.0;
    return if (value <= 0.04045) value / 12.92 else std.math.pow(f64, (value + 0.055) / 1.055, 2.4);
}

fn distance(left: Rgb, right: Rgb) u16 {
    const r = @abs(@as(i16, left.r) - @as(i16, right.r));
    const g = @abs(@as(i16, left.g) - @as(i16, right.g));
    const b = @abs(@as(i16, left.b) - @as(i16, right.b));
    return @intCast(@max(r, @max(g, b)));
}

fn ensureContrast(color: Rgb, reference: Rgb, mix_target: Rgb, minimum: f64) Rgb {
    if (contrast(color, reference) >= minimum) return color;
    var result = color;
    var amount: f64 = 0.08;
    while (amount <= 1.0) : (amount += 0.08) {
        result = mix(color, mix_target, amount);
        if (contrast(result, reference) >= minimum) return result;
    }
    return mix_target;
}

fn mix(first: Rgb, second: Rgb, amount: f64) Rgb {
    return .{
        .r = mixChannel(first.r, second.r, amount),
        .g = mixChannel(first.g, second.g, amount),
        .b = mixChannel(first.b, second.b, amount),
    };
}

fn mixChannel(first: u8, second: u8, amount: f64) u8 {
    const left: f64 = @floatFromInt(first);
    const right: f64 = @floatFromInt(second);
    return @intFromFloat(@round(left * (1.0 - amount) + right * amount));
}

fn sgr(comptime code: u8, color: Rgb) Ansi {
    var result: Ansi = .{};
    const value = std.fmt.bufPrint(&result.bytes, "\x1b[{d};2;{d};{d};{d}m", .{ code, color.r, color.g, color.b }) catch unreachable;
    result.len = value.len;
    return result;
}

pub fn digest(a: A, text: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &hash, .{});
    return std.fmt.allocPrint(a, "{x}", .{hash});
}

pub fn endpointHash(a: A, endpoint: []const u8) ![]const u8 {
    return digest(a, endpoint);
}

pub fn tokenHash(a: A, token: []const u8) ![]const u8 {
    return digest(a, token);
}

pub fn accountCachePath(a: A, config_dir: []const u8, endpoint: []const u8, account_id: []const u8) ![]const u8 {
    const key = try digest(a, try std.fmt.allocPrint(a, "{s}\n{s}", .{ endpoint, account_id }));
    return std.fmt.allocPrint(a, "{s}/theme-account-{s}.json", .{ config_dir, key });
}

pub fn loadAccount(a: A, config_dir: []const u8, endpoint: []const u8, account_id: []const u8) !CacheEntry {
    const file_path = try accountCachePath(a, config_dir, endpoint, account_id);
    const bytes = try std.fs.cwd().readFileAlloc(a, file_path, 16 * 1024);
    return (try std.json.parseFromSlice(CacheEntry, a, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true })).value;
}

pub fn saveAccount(a: A, config_dir: []const u8, endpoint: []const u8, entry: CacheEntry) !void {
    try std.fs.cwd().makePath(config_dir);
    const file_path = try accountCachePath(a, config_dir, endpoint, entry.account_id);
    const bytes = try std.json.Stringify.valueAlloc(a, entry, .{});
    try atomic(a, file_path, bytes);
}

pub fn findOfflineAccount(a: A, config_dir: []const u8, endpoint: []const u8, token_digest: []const u8) !?CacheEntry {
    var config = std.fs.cwd().openDir(config_dir, .{ .iterate = true, .no_follow = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    defer config.close();
    const endpoint_digest = try endpointHash(a, endpoint);
    var iterator = config.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, "theme-account-") or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const bytes = std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ config_dir, entry.name }), 16 * 1024) catch continue;
        const cached = (std.json.parseFromSlice(CacheEntry, a, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch continue).value;
        if (std.mem.eql(u8, cached.endpoint_hash, endpoint_digest) and std.mem.eql(u8, cached.token_hash, token_digest)) return cached;
    }
    return null;
}

pub fn loadLocal(a: A, config_dir: []const u8) !?[]const u8 {
    const file_path = try std.fs.path.join(a, &.{ config_dir, "theme-local.json" });
    const bytes = std.fs.cwd().readFileAlloc(a, file_path, 4096) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const decoded = try std.json.parseFromSlice(LocalCache, a, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    if (decoded.value.accent) |value| _ = try parseHex(value);
    return decoded.value.accent;
}

pub fn saveLocal(a: A, config_dir: []const u8, accent_value: ?[]const u8) !void {
    if (accent_value) |value| _ = try parseHex(value);
    try std.fs.cwd().makePath(config_dir);
    const file_path = try std.fs.path.join(a, &.{ config_dir, "theme-local.json" });
    try atomic(a, file_path, try std.json.Stringify.valueAlloc(a, LocalCache{ .accent = accent_value }, .{}));
}

pub fn pendingPath(a: A, config_dir: []const u8, endpoint: []const u8, token_digest: []const u8) ![]const u8 {
    const key = try digest(a, try std.fmt.allocPrint(a, "{s}\n{s}", .{ endpoint, token_digest }));
    return std.fmt.allocPrint(a, "{s}/theme-pending-{s}.json", .{ config_dir, key });
}

pub fn loadPending(a: A, config_dir: []const u8, endpoint: []const u8, token_digest: []const u8) !?PendingEntry {
    const file_path = try pendingPath(a, config_dir, endpoint, token_digest);
    const bytes = std.fs.cwd().readFileAlloc(a, file_path, 4096) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const result = (try std.json.parseFromSlice(PendingEntry, a, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true })).value;
    if (!std.mem.eql(u8, result.endpoint_hash, try endpointHash(a, endpoint)) or !std.mem.eql(u8, result.token_hash, token_digest)) return error.InvalidThemeCache;
    if (result.accent) |value| _ = try parseHex(value);
    return result;
}

pub fn savePending(a: A, config_dir: []const u8, endpoint: []const u8, token_digest: []const u8, accent_value: ?[]const u8) !void {
    if (accent_value) |value| _ = try parseHex(value);
    try std.fs.cwd().makePath(config_dir);
    const file_path = try pendingPath(a, config_dir, endpoint, token_digest);
    const entry = PendingEntry{ .endpoint_hash = try endpointHash(a, endpoint), .token_hash = token_digest, .accent = accent_value };
    try atomic(a, file_path, try std.json.Stringify.valueAlloc(a, entry, .{}));
}

pub fn deletePending(a: A, config_dir: []const u8, endpoint: []const u8, token_digest: []const u8) !void {
    const file_path = try pendingPath(a, config_dir, endpoint, token_digest);
    std.fs.cwd().deleteFile(file_path) catch |err| if (err != error.FileNotFound) return err;
}

const LocalCache = struct { accent: ?[]const u8 = null };

fn atomic(a: A, file_path: []const u8, bytes: []const u8) !void {
    var random: [8]u8 = undefined;
    std.crypto.random.bytes(&random);
    const temp_path = try std.fmt.allocPrint(a, "{s}.{x}.tmp", .{ file_path, std.mem.readInt(u64, &random, .little) });
    defer std.fs.cwd().deleteFile(temp_path) catch {};
    const file = try std.fs.cwd().createFile(temp_path, .{ .exclusive = true, .mode = 0o600 });
    defer file.close();
    try platform.privateFile(a, temp_path);
    try file.writeAll(bytes);
    try file.sync();
    try std.fs.cwd().rename(temp_path, file_path);
}
