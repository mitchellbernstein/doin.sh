const std = @import("std");
const platform = @import("platform.zig");
const theme = @import("theme.zig");
const Allocator = std.mem.Allocator;
const reset = "\x1b[0m";
const accent = "\x1b[39m";
const muted = "\x1b[39m";
const white = "\x1b[39m";
const assistant = "\x1b[39m";
const band = "\x1b[7m";
const bold = "\x1b[1m";
const default_foreground = "\x1b[39m";
const command_options = [_][]const u8{ "/add", "/ask", "/done", "/generate", "/help", "/list", "/ls", "/model", "/note", "/quit", "/exit", "/reopen", "/undo", "/voice", "/sync", "/account", "/provider", "/settings", "/theme", "/review", "/prioritize", "/visualize", "/delete", "/clear", "/config", "/path", "/focus", "/update", "/upgrade", "/remind", "/today", "/week", "/month", "/filter", "/status", "/mark", "/unblock", "/statuses", "/mcp", "/folder", "/team", "/assist", "/properties", "/set", "/unset", "/assign", "/agents" };
var active_accent: ?[]const u8 = null;
var terminal_background: ?theme.Rgb = null;
var terminal_foreground: ?theme.Rgb = null;
var pending_input: [64]u8 = undefined;
var pending_input_len: usize = 0;
var pending_input_at: usize = 0;

pub fn setTheme(accent_hex: ?[]const u8) void {
    active_accent = accent_hex;
}

fn popPending() ?u8 {
    if (pending_input_at >= pending_input_len) return null;
    const byte = pending_input[pending_input_at];
    pending_input_at += 1;
    if (pending_input_at == pending_input_len) {
        pending_input_at = 0;
        pending_input_len = 0;
    }
    return byte;
}
fn rawInputByte(timeout: i32) !?u8 {
    if (popPending()) |buffered| return buffered;
    return platform.readByte(timeout);
}
fn inputByte(timeout: i32) !?u8 {
    const first = (try rawInputByte(timeout)) orelse return null;
    if (first != 27) return first;
    const next_byte = try rawInputByte(6) orelse return first;
    if (next_byte != ']') {
        unreadInput(&.{next_byte});
        return first;
    }
    var sequence: [66]u8 = undefined;
    sequence[0] = first;
    sequence[1] = next_byte;
    var length: usize = 2;
    var terminated = false;
    while (length < sequence.len) {
        const byte = try rawInputByte(8) orelse break;
        sequence[length] = byte;
        length += 1;
        if (byte == 7 or (length >= 2 and sequence[length - 2] == 27 and byte == '\\')) {
            terminated = true;
            break;
        }
    }
    const whole = sequence[0..length];
    if (terminated and (parseOscRgb(whole, "10") != null or parseOscRgb(whole, "11") != null)) return inputByte(timeout);
    unreadInput(whole[1..]);
    return first;
}

fn unreadInput(bytes: []const u8) void {
    if (bytes.len == 0) return;
    const remaining = pending_input_len - pending_input_at;
    if (bytes.len + remaining > pending_input.len) return;
    std.mem.copyBackwards(u8, pending_input[bytes.len .. bytes.len + remaining], pending_input[pending_input_at..pending_input_len]);
    @memcpy(pending_input[0..bytes.len], bytes);
    pending_input_at = 0;
    pending_input_len = bytes.len + remaining;
}

fn parseOscRgb(bytes: []const u8, code: []const u8) ?theme.Rgb {
    const prefix = if (std.mem.eql(u8, code, "10")) "\x1b]10;" else if (std.mem.eql(u8, code, "11")) "\x1b]11;" else return null;
    if (!std.mem.startsWith(u8, bytes, prefix)) return null;
    const raw = bytes[prefix.len..];
    const end = std.mem.indexOfAny(u8, raw, "\x07\x1b") orelse return null;
    const value = raw[0..end];
    if (std.mem.startsWith(u8, value, "rgb:")) {
        var parts = std.mem.splitScalar(u8, value[4..], '/');
        const r = parts.next() orelse return null;
        const g = parts.next() orelse return null;
        const b = parts.next() orelse return null;
        if (parts.next() != null or r.len == 0 or g.len == 0 or b.len == 0 or r.len > 4 or g.len > 4 or b.len > 4) return null;
        const parseChannel = struct {
            fn call(text: []const u8) ?u8 {
                const parsed = std.fmt.parseInt(u16, text, 16) catch return null;
                const maximum: u32 = (@as(u32, 1) << @intCast(text.len * 4)) - 1;
                return @intCast((@as(u32, parsed) * 255 + maximum / 2) / maximum);
            }
        }.call;
        return .{ .r = parseChannel(r) orelse return null, .g = parseChannel(g) orelse return null, .b = parseChannel(b) orelse return null };
    }
    if (value.len == 7 and value[0] == '#') return theme.parseHex(value) catch null;
    return null;
}

fn probeTerminalBackground() void {
    if (!platform.isTty(0) or !platform.isTty(1) or platform.getenv("NO_COLOR") != null) return;
    var original = platform.ConsoleState.capture() catch return;
    original.raw() catch return;
    defer original.restore();
    terminal_foreground = queryOscColor("10");
    // If the foreground probe encountered user input, leave the rest of the
    // startup keystream untouched instead of consuming it during another query.
    if (pending_input_at == pending_input_len) terminal_background = queryOscColor("11");
}

fn queryOscColor(code: []const u8) ?theme.Rgb {
    const query = if (std.mem.eql(u8, code, "10")) "\x1b]10;?\x07" else if (std.mem.eql(u8, code, "11")) "\x1b]11;?\x07" else return null;
    write(query) catch return null;
    const expected = if (std.mem.eql(u8, code, "10")) "\x1b]10;" else "\x1b]11;";
    var reply: [64]u8 = undefined;
    var length: usize = 0;
    for (expected) |byte| {
        const timeout: i32 = if (length == 0) 240 else 20;
        const response_byte = platform.readByte(timeout) catch {
            unreadInput(reply[0..length]);
            return null;
        } orelse {
            unreadInput(reply[0..length]);
            return null;
        };
        reply[length] = response_byte;
        length += 1;
        if (response_byte != byte) {
            unreadInput(reply[0..length]);
            return null;
        }
    }
    while (length < reply.len) {
        const maybe_next = platform.readByte(5) catch break;
        const probe_byte = maybe_next orelse break;
        reply[length] = probe_byte;
        length += 1;
        if (probe_byte == 7 or (length >= 2 and reply[length - 2] == 27 and probe_byte == '\\')) break;
    }
    return parseOscRgb(reply[0..length], code);
}

fn selectionStart() !theme.Selection {
    const styles = theme.ansiSelection(active_accent, terminal_background, terminal_foreground);
    if (styles.colored) {
        try write(styles.background.slice());
        if (styles.override_foreground) try write(styles.foreground.slice());
    } else try write(bold);
    return styles;
}

fn selectionChevron(styles: theme.Selection) !void {
    if (styles.colored) try write(styles.chevron.slice()) else try write(bold);
    try write("›\x1b[22m");
    if (styles.override_foreground) try write(styles.foreground.slice()) else try write(default_foreground);
}

fn selectionSecondary() !void {
    const color = theme.ansiSecondary(terminal_background, terminal_foreground);
    if (color.len > 0) try write(color.slice()) else try write("\x1b[2m");
}
var interrupted = std.atomic.Value(bool).init(false);

var transcript: [65536]u8 = undefined;
var transcript_len: usize = 0;
fn rememberOutput(text: []const u8) void {
    if (!session_wanted) return;
    for (text) |byte| {
        if (transcript_len == transcript.len) {
            var drop = if (std.mem.indexOfScalar(u8, transcript[0..transcript_len], '\n')) |at| at + 1 else transcript_len / 2;
            while (drop < transcript_len and transcript[drop] & 0xc0 == 0x80) drop += 1;
            std.mem.copyForwards(u8, &transcript, transcript[drop..transcript_len]);
            transcript_len -= drop;
        }
        transcript[transcript_len] = byte;
        transcript_len += 1;
    }
}
fn write(text: []const u8) !void {
    try std.fs.File.stdout().writeAll(text);
}
pub fn output(text: []const u8) !void {
    try write(text);
    rememberOutput(text);
}
var docked = false;
var session_wanted = false;
var session_cancelled = std.atomic.Value(bool).init(false);
var owned_http = std.atomic.Value(if (platform.windows) usize else c_int).init(0);
var session_original: ?platform.ConsoleState = null;
var session_signals: ?platform.SignalGuard = null;
pub fn cancelSession() void {
    session_cancelled.store(true, .seq_cst);
    interrupted.store(true, .seq_cst);
    const pid = owned_http.load(.seq_cst);
    if (pid > 0) platform.killDirect(if (platform.windows) @ptrFromInt(pid) else pid);
    if (session_wanted) sessionSignal(0);
}
pub fn cancelled() bool {
    return session_cancelled.load(.seq_cst);
}
pub fn trackHttp(pid: std.process.Child.Id) void {
    owned_http.store(if (platform.windows) @intFromPtr(pid) else pid, .seq_cst);
    if (cancelled()) platform.killDirect(pid);
}
pub fn clearHttp() void {
    owned_http.store(0, .seq_cst);
}
fn sessionSignal(_: c_int) callconv(.c) void {
    session_cancelled.store(true, .seq_cst);
    interrupted.store(true, .seq_cst);
    const cleanup = "\x1b[r\x1b[0m\x1b[?2004l\x1b[?25h";
    if (platform.windows) platform.write(1, cleanup) catch {} else _ = std.c.write(1, cleanup.ptr, cleanup.len);
    if (session_original) |*settings| settings.restore();
    const pid = owned_http.load(.seq_cst);
    if (pid > 0) platform.killDirect(if (platform.windows) @ptrFromInt(pid) else pid);
}
var reserved: usize = 4;
var command_menu_rows: usize = 0;
var command_menu_active = false;
var command_menu_selected: usize = 0;
var dock_height: usize = 0;
var dock_width: usize = 0;
pub var empty_placeholder = false;
var interacted = false;
fn cursorAt(a: Allocator, row: usize, col: usize) !void {
    const sequence = try std.fmt.allocPrint(a, "\x1b[{d};{d}H", .{ row, col });
    defer a.free(sequence);
    try write(sequence);
}
fn margins(a: Allocator, reserve: usize) !void {
    const sequence = try std.fmt.allocPrint(a, "\x1b[1;{d}r", .{rows() - reserve});
    defer a.free(sequence);
    try write(sequence);
    reserved = reserve;
}
const CommandMatches = struct { indices: [command_options.len]usize = undefined, len: usize = 0 };
fn menuMatches(text: []const u8, cursor: usize, active: bool) CommandMatches {
    var matches: CommandMatches = .{};
    if (!active or cursor != text.len or text.len == 0 or text[0] != '/' or std.mem.indexOfScalar(u8, text, ' ') != null or std.mem.indexOfScalar(u8, text, '\t') != null) return matches;
    for (command_options, 0..) |command, index| if (std.mem.startsWith(u8, command, text)) {
        matches.indices[matches.len] = index;
        matches.len += 1;
    };
    return matches;
}
fn menuGhost(text: []const u8, matches: CommandMatches) []const u8 {
    if (matches.len == 0 or command_menu_selected >= matches.len) return "";
    return command_options[matches.indices[command_menu_selected]][text.len..];
}
fn syncCommandMenu(a: Allocator, count: usize) !void {
    if (!docked) return;
    if (count == command_menu_rows) return;
    if (command_menu_rows > 0) {
        try margins(a, 4);
        command_menu_rows = 0;
        const output_height = rows() -| 4;
        try clearRows(a, 1, output_height);
        try replayOutput(a, output_height, columns());
    }
    if (count > 0) {
        command_menu_rows = count;
        try margins(a, 4 + count);
    }
}
pub fn sessionStart(a: Allocator) !void {
    if (!rich()) return;
    probeTerminalBackground();
    // Start a fresh viewport without clearing native terminal history.
    for (0..rows()) |_| try write("\r\n");
    transcript_len = 0;
    session_wanted = true;
    session_original = try platform.ConsoleState.capture();
    session_signals = try platform.SignalGuard.install(sessionSignal);
    session_cancelled.store(false, .seq_cst);
    docked = rows() >= 12 and columns() >= 24;
    dock_height = rows();
    dock_width = columns();
    reserved = if (docked) 4 else 1;
    command_menu_rows = 0;
    if (rows() > reserved) try margins(a, reserved);
    try cursorAt(a, 1, 1);
}
pub fn sessionEnd() void {
    if (!session_wanted) return;
    defer {
        docked = false;
        session_wanted = false;
        if (session_signals) |*guard| guard.restore();
        session_signals = null;
        if (session_original) |*settings| settings.restore();
        session_original = null;
    }
    write("\x1b[r\x1b[0m\x1b[?2004l\x1b[?25h") catch {};
    var buffer: [48]u8 = undefined;
    const sequence = std.fmt.bufPrint(&buffer, "\x1b[{d};1H\r\n", .{rows()}) catch return;
    write(sequence) catch {};
}

fn replayOutput(a: Allocator, height: usize, cols: usize) !void {
    var starts: std.ArrayList(usize) = .empty;
    defer starts.deinit(a);
    try starts.append(a, 0);
    var cell: usize = 0;
    var i: usize = 0;
    while (i < transcript_len) {
        if (transcript[i] == 27 and i + 1 < transcript_len and transcript[i + 1] == '[') {
            i += 2;
            while (i < transcript_len and !(transcript[i] >= 0x40 and transcript[i] <= 0x7e)) i += 1;
            if (i < transcript_len) i += 1;
            continue;
        }
        if (transcript[i] == '\n') {
            i += 1;
            try starts.append(a, i);
            cell = 0;
            continue;
        }
        if (transcript[i] == '\r') {
            cell = 0;
            i += 1;
            continue;
        }
        const cp = scalar(transcript[0..transcript_len], i);
        if (cell + cp.cells > cols) {
            try starts.append(a, i);
            cell = 0;
        }
        cell += cp.cells;
        i += cp.len;
    }
    const first = starts.items.len -| height;
    try write(reset ++ "\x1b[?7l");
    defer write("\x1b[?7h") catch {};
    for (starts.items[first..], 0..) |from, row| {
        const index = first + row;
        const until = if (index + 1 < starts.items.len) starts.items[index + 1] else transcript_len;
        const content = std.mem.trimEnd(u8, transcript[from..until], "\r\n");
        try cursorAt(a, row + 1, 1);
        try write(content);
    }
    try write(reset);
    try cursorAt(a, @min(height, starts.items.len - first), @min(cols, cell + 1));
}
fn resizeDock(a: Allocator) !void {
    if (!session_wanted) return;
    const height = rows();
    const cols = columns();
    if (dock_height == height and dock_width == cols) return;
    try write("\x1b[r\x1b[0m\x1b[2J\x1b[H");
    dock_height = height;
    dock_width = cols;
    docked = height >= 12 and cols >= 24;
    reserved = if (docked) 4 else 1;
    const available = @max(1, height -| reserved);
    if (height > reserved) try margins(a, reserved);
    try replayOutput(a, available, cols);
}
fn popupDock(a: Allocator, reserve: usize) !void {
    if (!docked) return;
    if (reserve > reserved) {
        try cursorAt(a, rows() - reserved, 1);
        for (0..reserve - reserved) |_| try write("\r\n");
    }
    try margins(a, reserve);
    try cursorAt(a, rows() - reserve, 1);
}
fn clearRows(a: Allocator, first: usize, count: usize) !void {
    for (0..count) |i| {
        try cursorAt(a, first + i, 1);
        try write("\x1b[2K");
    }
}
fn idleArt(a: Allocator, frame: usize, clear_art: bool) !void {
    if (!docked or rows() < 28 or columns() < 40) return;
    const first = @max(12, (rows() - 4 - 11) / 2 + 1);
    if (first + 10 > rows() - 4) return;
    const col = (columns() - 25) / 2 + 1;
    const artwork = [_][]const u8{
        "          .....          ", "      ...       ...      ", "    ..             ..    ",
        "  ..                 ..  ", " .                     . ", " .        d o i n      . ",
        " .                     . ", "  ..                 ..  ", "    ..             ..    ",
        "      ...       ...      ", "          .....          ",
    };
    for (artwork, 0..) |line_text, row| {
        try cursorAt(a, first + row, col);
        try write(muted);
        if (clear_art) {
            for (0..25) |_| try write(" ");
        } else {
            var line_buffer: [25]u8 = undefined;
            @memcpy(&line_buffer, line_text);
            const orbit = [_]struct { row: usize, col: usize }{ .{ .row = 0, .col = 12 }, .{ .row = 2, .col = 19 }, .{ .row = 5, .col = 23 }, .{ .row = 8, .col = 19 }, .{ .row = 10, .col = 12 }, .{ .row = 8, .col = 5 }, .{ .row = 5, .col = 1 }, .{ .row = 2, .col = 5 } };
            const dot = orbit[frame % orbit.len];
            if (dot.row == row) line_buffer[dot.col] = '*';
            try write(&line_buffer);
        }
    }
    try write(reset);
}
fn signal(_: c_int) callconv(.c) void {
    if (docked) sessionSignal(0) else interrupted.store(true, .seq_cst);
}
pub fn rich() bool {
    if (!platform.isTty(0) or !platform.isTty(1) or platform.getenv("NO_COLOR") != null) return false;
    return !std.mem.eql(u8, platform.getenv("TERM") orelse "", "dumb");
}
pub fn columns() usize {
    return @max(12, platform.size().cols);
}
pub fn rows() usize {
    return platform.size().rows;
}
fn scalar(text: []const u8, offset: usize) struct { len: usize, cells: usize } {
    const len = std.unicode.utf8ByteSequenceLength(text[offset]) catch return .{ .len = 1, .cells = 1 };
    if (offset + len > text.len) return .{ .len = 1, .cells = 1 };
    const cp = std.unicode.utf8Decode(text[offset .. offset + len]) catch return .{ .len = 1, .cells = 1 };
    // ponytail: code-point cells cover normal terminal text; full grapheme segmentation needs a Unicode library.
    const combining = (cp >= 0x300 and cp <= 0x36f) or (cp >= 0x1ab0 and cp <= 0x1aff) or (cp >= 0xfe00 and cp <= 0xfe0f) or cp == 0x200d;
    const wide = (cp >= 0x1100 and cp <= 0x115f) or (cp >= 0x2e80 and cp <= 0xa4cf) or (cp >= 0xac00 and cp <= 0xd7a3) or (cp >= 0xf900 and cp <= 0xfaff) or (cp >= 0xfe10 and cp <= 0xfe6f) or (cp >= 0xff01 and cp <= 0xff60) or (cp >= 0x1f300 and cp <= 0x1faff) or (cp >= 0x20000 and cp <= 0x3ffff);
    return .{ .len = len, .cells = if (combining) 0 else if (wide) 2 else 1 };
}
pub fn width(text: []const u8) usize {
    var cells: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const cp = scalar(text, i);
        cells += cp.cells;
        i += cp.len;
    }
    return cells;
}
fn fit(text: []const u8, cells: usize) []const u8 {
    var used: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const cp = scalar(text, i);
        if (used + cp.cells > cells) break;
        used += cp.cells;
        i += cp.len;
    }
    return text[0..i];
}
fn fitTail(text: []const u8, cells: usize) []const u8 {
    var start = text.len;
    var used: usize = 0;
    while (start > 0) {
        const begin = prev(text, start);
        const cp = scalar(text, begin);
        if (used + cp.cells > cells) break;
        used += cp.cells;
        start = begin;
    }
    return text[start..];
}
fn prev(text: []const u8, at: usize) usize {
    if (at == 0) return 0;
    var i = at - 1;
    while (i > 0 and text[i] & 0xc0 == 0x80) i -= 1;
    return i;
}
fn next(text: []const u8, at: usize) usize {
    return if (at < text.len) at + scalar(text, at).len else at;
}
pub fn clean(a: Allocator, text: []const u8, multiline: bool) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 27) {
            i += 1;
            if (i < text.len and text[i] == '[') {
                i += 1;
                while (i < text.len and !(text[i] >= 0x40 and text[i] <= 0x7e)) i += 1;
                if (i < text.len) i += 1;
            } else if (i < text.len and text[i] == ']') {
                i += 1;
                while (i < text.len) : (i += 1) {
                    if (text[i] == 7) {
                        i += 1;
                        break;
                    }
                    if (text[i] == 27 and i + 1 < text.len and text[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                }
            } else if (i < text.len) i += 1;
            continue;
        }
        if (text[i] < 32 or text[i] == 127) {
            if (multiline and (text[i] == '\n' or text[i] == '\t')) try result.append(a, text[i]);
            i += 1;
            continue;
        }
        const cp = scalar(text, i);
        if (text[i] >= 128 and !std.unicode.utf8ValidateSlice(text[i .. i + cp.len])) {
            try result.append(a, '?');
            i += 1;
            continue;
        }
        try result.appendSlice(a, text[i .. i + cp.len]);
        i += cp.len;
    }
    return result.toOwnedSlice(a);
}
pub fn systemLine(a: Allocator, prefix: []const u8, text: []const u8) !void {
    if (rich()) try write(muted);
    defer if (rich()) write(reset) catch {};
    try line(a, prefix, text);
}
pub fn taskLine(a: Allocator, prefix: []const u8, text: []const u8, completed: bool) !void {
    if (rich()) try write(if (completed) muted else assistant);
    defer if (rich()) write(reset) catch {};
    try line(a, prefix, text);
}
fn messageBandStart(styles: theme.Selection) !void {
    if (styles.colored) {
        try write(styles.background.slice());
        if (styles.override_foreground) {
            try write(styles.foreground.slice());
        } else {
            try write(default_foreground);
        }
    } else try write(bold);
}
fn bandPadding(span: usize, styles: theme.Selection) !void {
    try write("  ");
    try messageBandStart(styles);
    for (0..span) |_| try write(" ");
    try write(reset ++ "\n");
}
pub fn userMessage(a: Allocator, text: []const u8) !void {
    const value = try clean(a, text, false);
    defer a.free(value);
    if (!rich() or columns() < 24) return line(a, "› User  ", value);
    rememberOutput("\n  › User  ");
    rememberOutput(value);
    rememberOutput("\n\n");
    try write("\n");
    var rest = value;
    var first = true;
    const span = columns() -| 4;
    const styles = theme.ansiSelection(active_accent, terminal_background, terminal_foreground);
    try bandPadding(span, styles);
    while (rest.len > 0) {
        const prefix = if (first) "  › User  " else "          ";
        var part = fit(rest, span -| width(prefix));
        if (part.len < rest.len) if (std.mem.lastIndexOfScalar(u8, part, ' ')) |space| {
            if (space > part.len / 2) part = part[0..space];
        };
        try write("  ");
        try messageBandStart(styles);
        try write(prefix);
        try write(part);
        for (0..span -| width(prefix) -| width(part)) |_| try write(" ");
        try write(reset ++ "\n");
        rest = std.mem.trimStart(u8, rest[part.len..], " ");
        first = false;
    }
    try bandPadding(span, styles);
    try write("\n");
}
pub fn assistantStart(a: Allocator) !void {
    try heading(a, "Assistant");
    if (rich()) try write(assistant);
}
pub fn messageEnd() !void {
    if (rich()) try write(reset);
}
pub fn heading(a: Allocator, text: []const u8) !void {
    const value = try clean(a, text, false);
    defer a.free(value);
    rememberOutput("\n  ");
    rememberOutput(value);
    rememberOutput("\n\n");
    try write("\n  ");
    if (rich()) try write(bold);
    try write(value);
    if (rich()) try write(reset);
    try write("\n\n");
}
pub fn line(a: Allocator, prefix: []const u8, text: []const u8) !void {
    const value = try clean(a, text, false);
    defer a.free(value);
    rememberOutput(prefix);
    rememberOutput(value);
    rememberOutput("\n");
    if (!rich()) {
        try write(prefix);
        try write(value);
        try write("\n");
        return;
    }
    const available = @max(4, columns() -| width(prefix) -| 2);
    var rest = value;
    var first = true;
    while (rest.len > 0) {
        var part = fit(rest, available);
        if (part.len < rest.len) if (std.mem.lastIndexOfScalar(u8, part, ' ')) |space| {
            if (space > part.len / 2) part = part[0..space];
        };
        if (first) try write(prefix) else {
            for (0..width(prefix)) |_| try write(" ");
        }
        first = false;
        try write(part);
        try write("\n");
        rest = std.mem.trimStart(u8, rest[part.len..], " ");
    }
    if (value.len == 0) {
        try write(prefix);
        try write("\n");
    }
}

pub const Editor = struct {
    allocator: Allocator,
    history: std.ArrayList([]const u8) = .empty,
    pending: ?[]const u8 = null,
    pending_byte: ?u8 = null,
    pending_cursor: ?usize = null,
    pending_command_selection: ?usize = null,
    pub fn init(a: Allocator) Editor {
        return .{ .allocator = a };
    }
    pub fn deinit(self: *Editor) void {
        if (self.pending) |draft| self.allocator.free(draft);
        for (self.history.items) |item| self.allocator.free(item);
        self.history.deinit(self.allocator);
    }
    pub fn setDraft(self: *Editor, text: []const u8) !void {
        if (text.len > 8192) return error.InputTooLong;
        if (self.pending) |old| self.allocator.free(old);
        self.pending = try clean(self.allocator, text, false);
        self.pending_cursor = null;
    }
    fn remember(self: *Editor, text: []const u8) !void {
        if (text.len == 0) return;
        if (self.history.items.len > 0 and std.mem.eql(u8, self.history.items[self.history.items.len - 1], text)) return;
        if (self.history.items.len == 100) self.allocator.free(self.history.orderedRemove(0));
        try self.history.append(self.allocator, try self.allocator.dupe(u8, text));
    }
    fn plain(a: Allocator, label: []const u8) ![]const u8 {
        try write(label);
        try write(" ");
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(a);
        while (true) {
            var byte: [1]u8 = undefined;
            if (try platform.read(0, &byte) == 0) {
                if (text.items.len == 0) return error.InputClosed;
                break;
            }
            if (byte[0] == '\n') break;
            if (text.items.len >= 8192) return error.InputTooLong;
            try text.append(a, byte[0]);
        }
        return a.dupe(u8, std.mem.trim(u8, text.items, " \r\t"));
    }
    fn repaint(a: Allocator, text: []const u8, cursor: usize, label: []const u8, hint: []const u8, redraw: bool, focus: ?struct { start: usize, end: usize }) !void {
        const matches = menuMatches(text, cursor, command_menu_active);
        var menu_rows: usize = 0;
        var option_rows: usize = 0;
        var scrolled = false;
        if (docked and matches.len > 0) {
            menu_rows = @min(6, rows() -| 9);
            scrolled = matches.len > menu_rows;
            option_rows = menu_rows - @intFromBool(scrolled);
            menu_rows = @min(matches.len, menu_rows);
        }
        if (matches.len > 0) command_menu_selected = @min(command_menu_selected, matches.len - 1) else command_menu_selected = 0;
        try syncCommandMenu(a, menu_rows);
        if (session_wanted and !docked) {
            const available = columns() -| 3;
            var start: usize = 0;
            while (start < cursor and width(text[start..cursor]) >= available) start = next(text, start);
            try cursorAt(a, rows(), 1);
            try write("\r\x1b[2K› ");
            const input = fit(text[start..], available);
            try write(input);
            const ghost = fit(menuGhost(text, matches), available -| width(input));
            if (ghost.len > 0) {
                try write(muted);
                try write(ghost);
                try write(reset);
            }
            try cursorAt(a, rows(), 3 + width(text[start..cursor]));
            return;
        }
        const box_width = @max(10, columns() -| 4);
        const inside = box_width - 6;
        var start: usize = 0;
        while (start < cursor and width(text[start..cursor]) > inside -| 1) start = next(text, start);
        const marker: usize = if (start > 0) 1 else 0;
        const visible = fit(text[start..], inside - marker);
        const ghost = fit(menuGhost(text, matches), inside -| marker -| width(visible));
        const pad = inside -| marker -| width(visible) -| width(ghost);
        var suggestions: std.ArrayList(u8) = .empty;
        defer suggestions.deinit(a);
        if (focus == null and matches.len > 0 and !docked) {
            for (matches.indices[0..@min(matches.len, 8)], 0..) |index, i| {
                if (i > 0) try suggestions.appendSlice(a, "  ");
                try suggestions.appendSlice(a, command_options[index]);
            }
        }
        const command_hint = if (focus == null and matches.len > 0) (if (docked) "↑↓ choose · Tab complete · Enter run · Esc close" else suggestions.items) else hint;
        if (menu_rows > 0) {
            const options_to_show = if (scrolled) option_rows else menu_rows;
            const start_index = command_menu_selected -| (options_to_show / 2);
            const first = @min(start_index, matches.len -| options_to_show);
            for (0..options_to_show) |row| {
                try cursorAt(a, rows() - 3 - menu_rows + row, 1);
                try write("\r\x1b[2K  ");
                if (matches.indices[first + row] == matches.indices[command_menu_selected]) {
                    const styles = try selectionStart();
                    try selectionChevron(styles);
                    try write(" ");
                } else try write(muted ++ "  ");
                try write(command_options[matches.indices[first + row]]);
                try write(reset);
            }
            if (scrolled) {
                try cursorAt(a, rows() - 4, 1);
                try write("\r\x1b[2K  " ++ muted);
                const more = try std.fmt.allocPrint(a, "↑↓ choose · {d} more", .{matches.len - option_rows});
                defer a.free(more);
                try write(fit(more, columns() -| 4));
                try write(reset);
            }
        }
        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(a);
        if (docked) {
            try cursorAt(a, rows() - 3, 1);
        } else if (redraw) try frame.appendSlice(a, "\r\x1b[1A");
        try frame.appendSlice(a, "\r\x1b[2K  " ++ accent ++ "╭");
        if (label.len == 0) {
            for (0..box_width - 2) |_| try frame.appendSlice(a, "─");
        } else {
            try frame.appendSlice(a, "─ ");
            const title = fit(label, box_width -| 6);
            try frame.appendSlice(a, title);
            try frame.append(a, ' ');
            const top_pad = box_width -| 5 -| width(title);
            for (0..top_pad) |_| try frame.appendSlice(a, "─");
        }
        try frame.appendSlice(a, "╮" ++ reset ++ "\r\n\x1b[2K  " ++ accent ++ "│ " ++ reset ++ bold ++ "› " ++ reset);
        if (marker > 0) try frame.appendSlice(a, "‹");
        if (focus) |range| {
            const from = @min(visible.len, range.start -| start);
            const to = @max(from, @min(visible.len, range.end -| start));
            try frame.appendSlice(a, visible[0..from]);
            try frame.appendSlice(a, band ++ white);
            try frame.appendSlice(a, visible[from..to]);
            try frame.appendSlice(a, reset);
            try frame.appendSlice(a, visible[to..]);
        } else try frame.appendSlice(a, visible);
        if (focus == null and ghost.len > 0) {
            try frame.appendSlice(a, muted);
            try frame.appendSlice(a, ghost);
            try frame.appendSlice(a, reset);
        }
        for (0..pad) |_| try frame.append(a, ' ');
        try frame.appendSlice(a, " " ++ accent ++ "│" ++ reset ++ "\r\n\x1b[2K  " ++ accent ++ "╰");
        for (0..box_width - 2) |_| try frame.appendSlice(a, "─");
        try frame.appendSlice(a, "╯" ++ reset ++ "\r\n\x1b[2K  " ++ muted);
        try frame.appendSlice(a, fit(command_hint, columns() -| 4));
        try frame.appendSlice(a, if (docked) reset ++ "\r\x1b[2A" else reset ++ "\r\n\x1b[3A\r");
        const position = try std.fmt.allocPrint(a, "\x1b[{d}C", .{6 + marker + width(text[start..cursor])});
        defer a.free(position);
        try frame.appendSlice(a, position);
        try write(frame.items);
    }
    fn erase(text: *std.ArrayList(u8), from: usize, to: usize) void {
        std.mem.copyForwards(u8, text.items[from..], text.items[to..]);
        text.items.len -= to - from;
    }
    fn readByte(timeout: i32) !?u8 {
        return inputByte(timeout);
    }
    pub fn read(self: *Editor, a: Allocator, label: []const u8, hint: []const u8, history: bool) ![]const u8 {
        if (cancelled()) return error.InputClosed;
        if (session_wanted and (dock_width != columns() or dock_height != rows())) try resizeDock(a);
        if (!rich() or (!session_wanted and (columns() < 24 or rows() < 12))) {
            if (self.pending) |draft| {
                defer {
                    self.allocator.free(draft);
                    self.pending = null;
                }
                try line(a, "Draft retained: ", draft);
                const replacement = try plain(a, "Enter to keep draft, or type replacement:");
                return if (replacement.len > 0) replacement else a.dupe(u8, draft);
            }
            return plain(a, if (label.len == 0) "›" else label);
        }
        const original = try platform.ConsoleState.capture();
        interrupted.store(false, .seq_cst);
        const signals = try platform.SignalGuard.install(signal);
        defer signals.restore();
        try original.raw();
        defer original.restore();
        if (session_wanted) try write("\x1b7");
        try write(if (session_wanted) "\x1b[?2004h" else "\x1b[?2004h\n");
        var submitted = false;
        var resized = false;
        var art_painted = false;
        defer {
            if (art_painted and !resized) idleArt(a, 0, true) catch {};
            if (session_wanted and !cancelled()) {
                if (!resized) repaint(a, "", 0, label, "Working · input resumes when ready", false, null) catch {};
                if (resized) resizeDock(a) catch {} else write("\x1b8") catch {};
            } else if (!cancelled()) write(if (submitted) "\r" else "\r\x1b[3B\r\n") catch {};
            write("\x1b[?2004l\x1b[0m\x1b[?25h") catch {};
        }
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.allocator);
        if (self.pending) |value| {
            try text.appendSlice(self.allocator, value);
            self.allocator.free(value);
            self.pending = null;
        }
        var cursor: usize = @min(text.items.len, self.pending_cursor orelse text.items.len);
        self.pending_cursor = null;
        command_menu_selected = self.pending_command_selection orelse 0;
        self.pending_command_selection = null;
        var menu_dismissed = false;
        command_menu_active = menuMatches(text.items, cursor, true).len > 0;
        defer {
            command_menu_active = false;
            syncCommandMenu(self.allocator, 0) catch {};
        }
        var selected = self.history.items.len;
        var draft: ?[]const u8 = null;
        defer if (draft) |v| self.allocator.free(v);
        var pasted = false;
        const last_columns = columns();
        const last_rows = rows();
        var art_frame: usize = 0;
        var art_tick = std.time.milliTimestamp();
        try repaint(self.allocator, text.items, cursor, label, hint, false, null);
        while (true) {
            if (cancelled() or interrupted.load(.seq_cst)) return error.InputClosed;
            if (empty_placeholder and !interacted and text.items.len == 0 and docked and rows() >= 28 and columns() >= 40) {
                const now = std.time.milliTimestamp();
                const animated = platform.getenv("DOIN_NO_ANIMATION") == null;
                if (!art_painted or (animated and now - art_tick >= 200)) {
                    try idleArt(a, art_frame, false);
                    art_painted = true;
                    art_frame += 1;
                    art_tick = now;
                    try repaint(a, text.items, cursor, label, hint, false, null);
                }
            }
            if (history and std.mem.startsWith(u8, text.items, "/model ")) {
                if (!session_wanted) try write("\r\x1b[1A\x1b[2K\x1b[1B\x1b[2K\x1b[1B\x1b[2K\x1b[1B\x1b[2K\x1b[3A\r");
                submitted = true;
                return error.ModelPickerRequested;
            }
            const maybe = if (self.pending_byte) |pending| blk: {
                self.pending_byte = null;
                break :blk @as(?u8, pending);
            } else try readByte(100);
            if (columns() != last_columns or rows() != last_rows) {
                resized = true;
                try self.setDraft(text.items);
                self.pending_cursor = cursor;
                self.pending_command_selection = command_menu_selected;
                self.pending_byte = maybe;
                return error.TerminalResized;
            }
            const byte = maybe orelse continue;
            var changed_draft = false;
            interacted = true;
            if (art_painted) {
                try idleArt(a, 0, true);
                art_painted = false;
                try repaint(a, text.items, cursor, label, hint, false, null);
            }
            if (byte == 3 or byte == 4) return error.InputClosed;
            if ((byte == '\r' or byte == '\n') and !pasted) {
                const value = std.mem.trim(u8, text.items, " \t");
                if (history) {
                    try self.remember(value);
                    if (!docked) try write("\r\x1b[1A\x1b[2K\x1b[1B\x1b[2K\x1b[1B\x1b[2K\x1b[1B\x1b[2K\x1b[3A\r");
                    submitted = true;
                }
                return a.dupe(u8, value);
            }
            if (byte == 27) {
                var seq: [24]u8 = undefined;
                var count: usize = 0;
                while (count < seq.len) {
                    seq[count] = (try readByte(30)) orelse break;
                    count += 1;
                    if (count >= 2 and (std.ascii.isAlphabetic(seq[count - 1]) or seq[count - 1] == '~')) break;
                }
                const key = seq[0..count];
                if (std.mem.eql(u8, key, "[200~")) pasted = true else if (std.mem.eql(u8, key, "[201~")) pasted = false else if (std.mem.eql(u8, key, "[D") or std.mem.eql(u8, key, "OD")) cursor = prev(text.items, cursor) else if (std.mem.eql(u8, key, "[C") or std.mem.eql(u8, key, "OC")) cursor = next(text.items, cursor) else if (std.mem.eql(u8, key, "[H") or std.mem.eql(u8, key, "OH") or std.mem.eql(u8, key, "[1~")) cursor = 0 else if (std.mem.eql(u8, key, "[F") or std.mem.eql(u8, key, "OF") or std.mem.eql(u8, key, "[4~")) cursor = text.items.len else if (std.mem.eql(u8, key, "[3~")) erase(&text, cursor, next(text.items, cursor)) else if ((history or command_menu_active) and (std.mem.eql(u8, key, "[A") or std.mem.eql(u8, key, "[B"))) {
                    const matches = menuMatches(text.items, cursor, command_menu_active and !pasted);
                    if (matches.len > 0) {
                        if (key[1] == 'A' and command_menu_selected > 0) command_menu_selected -= 1 else if (key[1] == 'B' and command_menu_selected + 1 < matches.len) command_menu_selected += 1;
                    } else {
                        if (draft == null) draft = try self.allocator.dupe(u8, text.items);
                        if (key[1] == 'A' and selected > 0) selected -= 1 else if (key[1] == 'B' and selected < self.history.items.len) selected += 1;
                        text.clearRetainingCapacity();
                        try text.appendSlice(self.allocator, if (selected == self.history.items.len) draft.? else self.history.items[selected]);
                        cursor = text.items.len;
                        changed_draft = true;
                    }
                } else if (key.len == 0) menu_dismissed = true;
                if (std.mem.eql(u8, key, "[3~")) changed_draft = true;
            } else if (byte == 127 or byte == 8) {
                const from = prev(text.items, cursor);
                erase(&text, from, cursor);
                cursor = from;
                changed_draft = true;
            } else if (byte == 1) cursor = 0 else if (byte == 5) cursor = text.items.len else if (byte == 21) {
                erase(&text, 0, cursor);
                cursor = 0;
                changed_draft = true;
            } else if (byte == 11) {
                erase(&text, cursor, text.items.len);
                changed_draft = true;
            } else if (byte == 23) {
                var from = cursor;
                while (from > 0 and text.items[from - 1] == ' ') from -= 1;
                while (from > 0 and text.items[from - 1] != ' ') from = prev(text.items, from);
                erase(&text, from, cursor);
                cursor = from;
                changed_draft = true;
            } else if (byte == 9 and !pasted and text.items.len > 0 and text.items[0] == '/') {
                const matches = menuMatches(text.items, cursor, command_menu_active);
                if (matches.len > 0) {
                    text.clearRetainingCapacity();
                    try text.appendSlice(self.allocator, command_options[matches.indices[@min(command_menu_selected, matches.len - 1)]]);
                    try text.append(self.allocator, ' ');
                    cursor = text.items.len;
                    changed_draft = true;
                }
            } else if (byte >= 32 or (pasted and (byte == '\r' or byte == '\n' or byte == '\t'))) {
                var bytes: [4]u8 = undefined;
                bytes[0] = if (byte < 32) ' ' else byte;
                const count = std.unicode.utf8ByteSequenceLength(bytes[0]) catch continue;
                var complete = true;
                for (1..count) |i| {
                    bytes[i] = (try readByte(100)) orelse {
                        complete = false;
                        break;
                    };
                }
                if (!complete or !std.unicode.utf8ValidateSlice(bytes[0..count])) continue;
                if (text.items.len + count > 8192) continue;
                try text.insertSlice(self.allocator, cursor, bytes[0..count]);
                cursor += count;
                changed_draft = true;
            }
            if (changed_draft) {
                menu_dismissed = false;
                command_menu_selected = 0;
            }
            command_menu_active = !menu_dismissed and !pasted and menuMatches(text.items, cursor, true).len > 0;
            try repaint(self.allocator, text.items, cursor, label, hint, true, null);
        }
    }
};

pub const ModelOption = struct { value: []const u8, label: []const u8, detail: []const u8 = "" };
pub const ModelField = struct { name: []const u8, prefix: []const u8, suffix: []const u8, placeholder: []const u8, initial: []const u8 = "", options: []const ModelOption, explanation: []const u8, selection_only: bool = false, escape_back: bool = false, on_selection: ?*const fn (?*anyopaque, []const u8) void = null, selection_context: ?*anyopaque = null, directory_mode: bool = false, directory_path: []const u8 = "", directory_state: ?*DirectoryState = null };
pub const DirectoryState = struct { query: std.ArrayList(u8) = .empty, selected: usize = 0, allocator: Allocator };
pub const DirectoryNavigation = enum { none, parent, back, forward, open };
pub const ModelChoice = struct { value: []const u8, back: bool = false, tab: bool = false, navigation: DirectoryNavigation = .none };
const PickerLayout = struct { option_rows: usize, height: usize, rewind: usize, compact_selection: bool };
fn pickerLayout(field_spec: ModelField, terminal_rows: usize) PickerLayout {
    const compact_selection = field_spec.selection_only and (!field_spec.directory_mode or terminal_rows >= 10);
    const option_rows: usize = if (compact_selection and field_spec.directory_mode) @max(1, @min(8, terminal_rows -| 7)) else if (compact_selection) @max(1, @min(8, terminal_rows -| 16)) else if (field_spec.selection_only) @max(1, @min(field_spec.options.len, terminal_rows -| 9)) else 3;
    const gap: usize = if (compact_selection or terminal_rows < 12) 0 else 2;
    return .{
        .option_rows = option_rows,
        .height = option_rows + (if (compact_selection and field_spec.directory_mode) @as(usize, 7) else @as(usize, 6)) + gap,
        .rewind = option_rows + (if (compact_selection) @as(usize, 5) else 3) + gap,
        .compact_selection = compact_selection,
    };
}
fn containsFold(text: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > text.len) return false;
    for (0..text.len - needle.len + 1) |i| if (std.ascii.eqlIgnoreCase(text[i .. i + needle.len], needle)) return true;
    return false;
}
fn pickerClear(a: Allocator, layout: PickerLayout) !void {
    if (docked) {
        try clearRows(std.heap.page_allocator, rows() - (layout.height - 1), layout.height);
        try popupDock(std.heap.page_allocator, 4);
        if (!cancelled()) {
            try write("\x1b7");
            try Editor.repaint(std.heap.page_allocator, "", 0, "", "Working · input resumes when ready", false, null);
            try write("\x1b8");
        }
        return;
    }
    try write(try std.fmt.allocPrint(a, "\r\x1b[{d}A", .{layout.rewind}));
    for (0..layout.height) |i| {
        try write("\x1b[2K");
        if (i + 1 < layout.height) try write("\x1b[1B\r");
    }
    try write(try std.fmt.allocPrint(a, "\x1b[{d}A\r", .{layout.height - 1}));
}
pub fn secret(a: Allocator, label: []const u8) ![]const u8 {
    const tty = platform.isTty(0);
    var original: ?platform.ConsoleState = null;
    if (tty) {
        original = try platform.ConsoleState.capture();
        try original.?.raw();
    }
    defer if (original) |state| state.restore();
    try output(label);
    var value: std.ArrayList(u8) = .empty;
    defer value.deinit(a);
    while (true) {
        if (cancelled()) return error.InputClosed;
        const byte = (try inputByte(100)) orelse continue;
        if (byte == 3 or byte == 4 or byte == 27) return error.InputClosed;
        if (byte == '\r' or byte == '\n') break;
        if (byte == 127 or byte == 8) {
            if (value.items.len > 0) value.items.len -= 1;
        } else if (byte >= 32 and byte < 127) {
            if (value.items.len >= 4096) return error.InvalidCredential;
            try value.append(a, byte);
        }
    }
    try output("\n");
    return value.toOwnedSlice(a);
}
pub fn modelPick(a: Allocator, field_spec: ModelField) !ModelChoice {
    if (field_spec.options.len == 0) return error.NoModelChoices;
    const compact_selection = field_spec.selection_only and (!field_spec.directory_mode or rows() >= 10);
    if (!rich() or columns() < 32 or rows() < 8 or (!field_spec.selection_only and rows() < 12) or (field_spec.directory_mode and rows() < 10) or (compact_selection and rows() < 9)) {
        try heading(a, field_spec.name);
        if (field_spec.directory_mode and field_spec.directory_path.len > 0) try line(a, "  Path: ", field_spec.directory_path);
        for (field_spec.options, 0..) |option, index| try line(a, try std.fmt.allocPrint(a, "  {d}  ", .{index + 1}), option.label);
        try systemLine(a, "  ", field_spec.explanation);
        const answer_text = try Editor.plain(a, if (field_spec.escape_back) "Choice [1; Escape goes back]:" else "Choice [1; Escape cancels]:");
        if (std.mem.indexOfScalar(u8, answer_text, 27) != null) {
            if (field_spec.escape_back) return .{ .value = "", .back = true };
            return error.PickerCancelled;
        }
        const index = if (answer_text.len == 0) 1 else std.fmt.parseInt(usize, answer_text, 10) catch return error.InvalidModelChoice;
        if (index == 0 or index > field_spec.options.len) return error.InvalidModelChoice;
        return .{ .value = field_spec.options[index - 1].value };
    }
    const original = try platform.ConsoleState.capture();
    try original.raw();
    defer original.restore();
    interrupted.store(false, .seq_cst);
    const signals = try platform.SignalGuard.install(signal);
    defer signals.restore();
    const layout = pickerLayout(field_spec, rows());
    const option_rows = layout.option_rows;
    const picker_height = layout.height;
    if (docked) {
        try popupDock(a, picker_height);
        if (compact_selection) try clearRows(std.heap.page_allocator, rows() - (picker_height - 1), picker_height);
    }
    var query: std.ArrayList(u8) = .empty;
    defer query.deinit(a);
    if (field_spec.directory_state) |state| try query.appendSlice(a, state.query.items);
    defer if (field_spec.directory_state) |state| {
        state.query.clearRetainingCapacity();
        state.query.appendSlice(state.allocator, query.items) catch {};
    };
    var matches: std.ArrayList(usize) = .empty;
    defer matches.deinit(a);
    var selected: usize = 0;
    for (field_spec.options, 0..) |option, i| if (std.mem.eql(u8, option.value, field_spec.initial)) {
        selected = i;
        break;
    };
    if (field_spec.directory_state) |state| selected = state.selected;
    defer if (field_spec.directory_state) |state| {
        state.selected = selected;
    };
    var dirty = true;
    var painted = false;
    var resized = false;
    var pasted = false;
    try write("\x1b[?2004h");
    defer {
        if (painted and !resized) pickerClear(a, layout) catch {};
        if (resized) resizeDock(a) catch {};
        write(reset ++ "\x1b[?2004l\x1b[?25h") catch {};
    }
    const initial_columns = columns();
    const initial_rows = rows();
    while (true) {
        if (cancelled() or interrupted.load(.seq_cst)) return error.InputClosed;
        if (columns() != initial_columns or rows() != initial_rows) {
            resized = true;
            if (field_spec.selection_only) return error.PickerResized;
            return error.PickerCancelled;
        }
        if (dirty) {
            matches.clearRetainingCapacity();
            for (field_spec.options, 0..) |option, index| {
                const action = field_spec.directory_mode and (std.mem.eql(u8, option.value, "select") or std.mem.eql(u8, option.label, ".."));
                if ((action and query.items.len == 0) or (!action and (containsFold(option.label, query.items) or (!field_spec.directory_mode and containsFold(option.value, query.items))))) try matches.append(a, index);
            }
            selected = @min(selected, matches.items.len -| 1);
            if (field_spec.on_selection) |callback| if (matches.items.len > 0) callback(field_spec.selection_context, field_spec.options[matches.items[selected]].value);
            if (docked) try cursorAt(a, rows() - (picker_height - 1), 1) else if (painted) try write(try std.fmt.allocPrint(a, "\r\x1b[{d}A", .{layout.rewind}));
            if (layout.compact_selection) {
                const clean_heading = try clean(a, field_spec.name, false);
                defer a.free(clean_heading);
                try write("\r\x1b[2K  ╭ ");
                const inner_width = columns() -| 8;
                try write(bold);
                const title = fit(clean_heading, inner_width);
                try write(title);
                try write(reset);
                var top_used = width(title) + 1;
                while (top_used < inner_width + 2) : (top_used += 1) try write("─");
                try write("╮\r\n");
                try write("\r\x1b[2K  " ++ default_foreground ++ "│   ");
                for (0..inner_width -| 2) |_| try write(" ");
                try write(" │\r\n");
                const start = selected -| (option_rows - 1);
                for (0..option_rows) |row| {
                    try write("\r\x1b[2K  ");
                    const index = start + row;
                    if (index < matches.items.len) {
                        const is_selected = index == selected;
                        const styles = if (is_selected) theme.ansiSelection(active_accent, terminal_background, terminal_foreground) else theme.Selection{};
                        // Keep the frame glyphs neutral; color begins at the selected marker.
                        try write(default_foreground ++ "│ ");
                        if (is_selected) {
                            _ = try selectionStart();
                            try selectionChevron(styles);
                            try write(" ");
                        } else try write("  ");
                        const option = field_spec.options[matches.items[index]];
                        const numbered_label = try std.fmt.allocPrint(a, "{d}  {s}", .{ matches.items[index] + 1, option.label });
                        defer a.free(numbered_label);
                        const label = try clean(a, numbered_label, false);
                        defer a.free(label);
                        const fitted = fit(label, inner_width -| 2);
                        if (is_selected) {
                            if (styles.override_foreground) try write(styles.foreground.slice()) else try write(default_foreground);
                        } else try selectionSecondary();
                        try write(fitted);
                        if (!is_selected) try write("\x1b[22m" ++ default_foreground);
                        var used = width(fitted) + 2;
                        while (used < inner_width) : (used += 1) try write(" ");
                        try write(reset ++ default_foreground ++ " │" ++ reset ++ "\r\n");
                    } else {
                        const empty = if (field_spec.directory_mode and matches.items.len == 0 and row == 0) "No matching folders" else "";
                        try write(default_foreground ++ "│   ");
                        try write(empty);
                        for (0..(inner_width -| 2) -| width(empty)) |_| try write(" ");
                        try write(" │" ++ reset ++ "\r\n");
                    }
                }
                try write("\r\x1b[2K  ╰");
                for (0..inner_width + 2) |_| try write("─");
                try write("╯\r\n\r\n\r\x1b[2K  " ++ default_foreground);
                if (field_spec.directory_mode) {
                    const clean_path = try clean(a, field_spec.directory_path, false);
                    defer a.free(clean_path);
                    const path_width = columns() -| 12;
                    var visible_path = fit(clean_path, path_width);
                    var allocated_path: ?[]const u8 = null;
                    if (width(clean_path) > path_width and path_width > 1) {
                        allocated_path = try std.fmt.allocPrint(a, "…{s}", .{fitTail(clean_path, path_width - 1)});
                        visible_path = allocated_path.?;
                    }
                    defer if (allocated_path) |value| a.free(value);
                    try write("\r\x1b[2K  " ++ default_foreground ++ "Path: ");
                    try write(visible_path);
                    try write(reset ++ "\r\n");

                    const filter_prefix = "  Filter: ";
                    const filter_width = columns() -| 4 -| width(filter_prefix);
                    try write("\r\x1b[2K" ++ default_foreground ++ filter_prefix);
                    var visible_filter: []const u8 = "";
                    if (query.items.len == 0) {
                        const placeholder = try clean(a, field_spec.placeholder, false);
                        defer a.free(placeholder);
                        visible_filter = fit(placeholder, filter_width);
                        try write(muted);
                        try write(visible_filter);
                        try write(reset);
                    } else {
                        const clean_filter = try clean(a, query.items, false);
                        defer a.free(clean_filter);
                        visible_filter = fitTail(clean_filter, filter_width);
                        try write(visible_filter);
                    }
                    const hint = fit("↑↓ select · Enter use/open · →/← navigate · Alt←/→ history · Esc back", columns() -| 4);
                    try write("\r\n\r\x1b[2K  " ++ default_foreground);
                    try write(hint);
                    try write(reset);
                    const cursor_column = width(filter_prefix) + if (query.items.len == 0) @as(usize, 0) else width(visible_filter);
                    try write("\x1b[1A\r");
                    try write(try std.fmt.allocPrint(a, "\x1b[{d}C", .{cursor_column}));
                } else {
                    const description = if (matches.items.len > 0 and field_spec.options[matches.items[selected]].detail.len > 0) field_spec.options[matches.items[selected]].detail else field_spec.explanation;
                    const clean_description = try clean(a, description, false);
                    defer a.free(clean_description);
                    try write(fit(clean_description, columns() -| 4));
                    try write(reset ++ "\r\n\r\x1b[2K  " ++ default_foreground ++ "↑↓ choose · Enter accept · 1–9 select · Esc ");
                    try write(if (field_spec.escape_back) "back" else "cancel");
                    try write(reset);
                }
            } else {
                try write("\r\x1b[2K  " ++ bold ++ default_foreground);
                const clean_heading = try clean(a, field_spec.name, false);
                defer a.free(clean_heading);
                try write(fit(clean_heading, columns() -| 4));
                try write(reset ++ "\r\n");
                if (rows() >= 12) try write("\r\n");
                const start = if (field_spec.selection_only) selected -| (option_rows - 1) else selected -| 1;
                for (0..option_rows) |row| {
                    try write("\r\x1b[2K  ");
                    const index = start + row;
                    if (index < matches.items.len) {
                        const is_selected = index == selected;
                        const styles = if (is_selected) try selectionStart() else theme.Selection{};
                        if (is_selected) {
                            try selectionChevron(styles);
                            try write(" ");
                        } else try write(default_foreground ++ "  ");
                        const option = field_spec.options[matches.items[index]];
                        const label = try clean(a, option.label, false);
                        defer a.free(label);
                        const fitted = fit(label, columns() -| 6);
                        if (!is_selected) try selectionSecondary();
                        try write(fitted);
                        if (!is_selected) try write("\x1b[22m" ++ default_foreground);
                        if (is_selected and styles.colored) for (0..(columns() -| 6) -| width(fitted)) |_| try write(" ");
                    } else if (row == 0 and matches.items.len == 0) try write(default_foreground ++ "No matching options");
                    try write(reset ++ "\r\n");
                }
                if (rows() >= 12) try write("\r\n");
                try write("\r\x1b[2K  " ++ default_foreground);
                const description = if (matches.items.len > 0 and field_spec.options[matches.items[selected]].detail.len > 0) field_spec.options[matches.items[selected]].detail else field_spec.explanation;
                const clean_description = try clean(a, description, false);
                defer a.free(clean_description);
                try write(fit(clean_description, columns() -| 4));
                try write(reset ++ "\r\n");
                const active = if (query.items.len > 0) query.items else field_spec.placeholder;
                const input_text = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ field_spec.prefix, active, field_spec.suffix });
                defer a.free(input_text);
                try Editor.repaint(a, input_text, field_spec.prefix.len + query.items.len, "", if (field_spec.directory_mode) "↑↓ · →/Enter open · ← parent · Alt←/→ history · type filter · Esc cancel" else if (field_spec.selection_only) "↑↓ choose · Enter accept · 1–9 select · Esc cancel" else "Tab next · Shift+Tab back · ↑↓ choose · Enter accept · Esc cancel", false, .{ .start = field_spec.prefix.len, .end = field_spec.prefix.len + active.len });
            }
            painted = true;
            dirty = false;
        }
        const byte = (try Editor.readByte(100)) orelse continue;
        dirty = true;
        if (byte == 3 or byte == 4) return error.InputClosed;
        if (byte == 27) {
            const next_byte = (try Editor.readByte(30)) orelse {
                if (field_spec.escape_back) return .{ .value = "", .back = true };
                return error.PickerCancelled;
            };
            if (next_byte != '[') continue;
            var key_bytes: [16]u8 = undefined;
            var key_len: usize = 0;
            while (key_len < key_bytes.len) {
                key_bytes[key_len] = (try Editor.readByte(30)) orelse break;
                key_len += 1;
                if (std.ascii.isAlphabetic(key_bytes[key_len - 1]) or key_bytes[key_len - 1] == '~') break;
            }
            const key = key_bytes[0..key_len];
            if (std.mem.eql(u8, key, "200~")) {
                pasted = true;
                continue;
            }
            if (std.mem.eql(u8, key, "201~")) {
                pasted = false;
                continue;
            }
            if (pasted) continue;
            if (field_spec.directory_mode) {
                if (std.mem.eql(u8, key, "D")) return .{ .value = "", .navigation = .parent };
                if (std.mem.eql(u8, key, "1;3D")) return .{ .value = "", .navigation = .back };
                if (std.mem.eql(u8, key, "1;3C")) return .{ .value = "", .navigation = .forward };
                if (std.mem.eql(u8, key, "C") and matches.items.len > 0) return .{ .value = field_spec.options[matches.items[selected]].value, .navigation = .open };
            }
            if (std.mem.eql(u8, key, "A") and selected > 0) selected -= 1 else if (std.mem.eql(u8, key, "B") and selected + 1 < matches.items.len) selected += 1 else if (!field_spec.selection_only and std.mem.eql(u8, key, "Z")) return .{ .value = "", .back = true };
        } else if (field_spec.selection_only and !field_spec.directory_mode and byte >= '1' and byte <= '9' and !pasted) {
            const index: usize = byte - '1';
            if (index < field_spec.options.len) selected = index;
        } else if (field_spec.selection_only and !field_spec.directory_mode and pasted) {
            continue;
        } else if (pasted and (byte == '\r' or byte == '\n' or byte == '\t')) {
            if (query.items.len < 256) try query.append(a, ' ');
        } else if (byte == '\r' or byte == '\n' or byte == '\t') {
            if (matches.items.len > 0) return .{ .value = field_spec.options[matches.items[selected]].value, .tab = byte == '\t' };
        } else if (field_spec.directory_mode and byte == 21) {
            query.clearRetainingCapacity();
            selected = 0;
        } else if (byte == 127 or byte == 8) {
            if (query.items.len > 0) query.items.len = prev(query.items, query.items.len);
            selected = 0;
        } else if ((!field_spec.selection_only or field_spec.directory_mode) and byte >= 32 and query.items.len < 256) {
            try query.append(a, byte);
            selected = 0;
        }
    }
}

pub fn browseChart(a: Allocator, markdown: []const u8, groups: usize, render: *const fn (Allocator, []const u8, usize) anyerror![]const u8) !void {
    if (!rich() or rows() < 10 or columns() < 32 or groups == 0) {
        const value = try clean(a, try render(a, markdown, 0), true);
        defer a.free(value);
        return write(value);
    }
    const original = try platform.ConsoleState.capture();
    try original.raw();
    defer original.restore();
    interrupted.store(false, .seq_cst);
    const signals = try platform.SignalGuard.install(signal);
    defer {
        signals.restore();
        write(reset ++ "\x1b[?25h") catch {};
    }
    const height = rows();
    const cols = columns();
    const visible = @min(groups, height - (if (docked) reserved else @as(usize, 0)) - 3);
    var selected: usize = 0;
    var dirty = true;
    var painted = false;
    try write("\n");
    while (true) {
        if (cancelled() or interrupted.load(.seq_cst)) return error.InputClosed;
        if (rows() != height or columns() != cols) {
            try write("\r\n");
            return;
        }
        if (dirty) {
            if (painted) try write(try std.fmt.allocPrint(a, "\r\x1b[{d}A", .{visible + 2}));
            const text = try clean(a, try render(a, markdown, selected), true);
            defer a.free(text);
            var lines = std.mem.splitScalar(u8, text, '\n');
            try write("\r\x1b[2K  " ++ muted);
            try write(fit(lines.next() orelse "Completion snapshot", cols -| 4));
            try write(reset ++ "\r\n");
            const start = selected -| (visible / 2);
            for (0..start) |_| _ = lines.next();
            for (0..visible) |row| {
                const text_line = lines.next() orelse "";
                try write("\r\x1b[2K  ");
                const is_selected = start + row == selected;
                const styles = if (is_selected) try selectionStart() else theme.Selection{};
                if (is_selected) {
                    try selectionChevron(styles);
                    try write(" ");
                } else try write(assistant);
                const fitted = fit(text_line, cols -| (if (is_selected) @as(usize, 6) else @as(usize, 4)));
                try write(fitted);
                if (is_selected and styles.colored) for (0..(cols -| 6) -| width(fitted)) |_| try write(" ");
                try write(reset ++ "\r\n");
            }
            try write("\r\x1b[2K  " ++ muted);
            try write(fit("←→ select group · Enter/Esc return", cols -| 4));
            try write(reset ++ "\r\n");
            painted = true;
            dirty = false;
        }
        const byte = (try Editor.readByte(100)) orelse continue;
        if (byte == 3 or byte == 4) return error.InputClosed;
        if (byte == '\r' or byte == '\n') return;
        if (byte == 27) {
            const lead = (try Editor.readByte(30)) orelse return;
            if (lead != '[') continue;
            const key = (try Editor.readByte(30)) orelse continue;
            if (key == 'A' or key == 'D') selected -|= 1 else if ((key == 'B' or key == 'C') and selected + 1 < groups) selected += 1;
            dirty = true;
        }
    }
}
