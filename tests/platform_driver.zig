//! Executable fixture: real platform browser dispatch; notifier captures file input.
const std = @import("std");
const platform = @import("platform");
pub fn main() !void {
    const a = std.heap.page_allocator;
    const args = try std.process.argsAlloc(a);
    if (args.len == 3 and std.mem.eql(u8, args[1], "console-state")) {
        if (@import("builtin").os.tag != .windows) return error.WindowsOnly;
        const win = @cImport({
            @cInclude("windows.h");
        });
        var input: win.DWORD = 0;
        var output: win.DWORD = 0;
        var cursor: win.CONSOLE_CURSOR_INFO = undefined;
        var screen: win.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        const ih = win.GetStdHandle(win.STD_INPUT_HANDLE);
        const oh = win.GetStdHandle(win.STD_OUTPUT_HANDLE);
        if (win.GetConsoleMode(ih, &input) == 0 or win.GetConsoleMode(oh, &output) == 0 or win.GetConsoleCursorInfo(oh, &cursor) == 0) return error.ConsoleQueryFailed;
        const original_output = output;
        _ = win.SetConsoleMode(oh, output | 1 | 4);
        try platform.write(1, "\x1b[1;1H");
        for (0..platform.size().rows + 2) |_| try platform.write(1, "\r\n");
        if (win.GetConsoleScreenBufferInfo(oh, &screen) == 0) return error.ConsoleQueryFailed;
        _ = win.SetConsoleMode(oh, original_output);
        const record = try std.json.Stringify.valueAlloc(a, .{ .input = input, .output = output, .visible = cursor.bVisible != 0, .codepage = win.GetConsoleOutputCP(), .scroll_row = screen.dwCursorPosition.Y, .bottom = screen.srWindow.Bottom }, .{});
        const f = try std.fs.cwd().createFile(args[2], .{});
        defer f.close();
        try f.writeAll(record);
        return;
    }

    // Fixture-only proxy retains exact generated XML before production rollback,
    // then invokes the real scheduler executable without changing its outcome.
    if (try platform.env(a, "DOIN_TEST_REAL_SCHTASKS")) |real| {
        const destination = (try platform.env(a, "DOIN_TEST_SCHEDULER_XML")) orelse return error.MissingFixturePath;
        for (args[1..], 1..) |arg, index| if (std.ascii.eqlIgnoreCase(arg, "/XML") and index + 1 < args.len) {
            const contents = try std.fs.cwd().readFileAlloc(a, args[index + 1], 65536);
            const output = try std.fs.cwd().createFile(destination, .{});
            defer output.close();
            try output.writeAll(contents);
        };
        var command: std.ArrayList([]const u8) = .empty;
        try command.append(a, real);
        try command.appendSlice(a, args[1..]);
        var child = std.process.Child.init(command.items, a);
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        const result = try child.spawnAndWait();
        if (result != .Exited or result.Exited != 0) std.process.exit(if (result == .Exited) result.Exited else 1);
        return;
    }

    if (args.len > 1 and !std.mem.eql(u8, args[1], "open")) if (try platform.env(a, "DOIN_TEST_CAPTURE")) |path| {
        const record = if (args.len == 3)
            try std.json.Stringify.valueAlloc(a, .{ .arguments = args[1..], .payload = try std.fs.cwd().readFileAlloc(a, args[1], 65536), .script = try std.fs.cwd().readFileAlloc(a, args[2], 65536) }, .{})
        else
            try std.json.Stringify.valueAlloc(a, .{ .arguments = args[1..] }, .{});
        const f = try std.fs.cwd().createFile(path, .{});
        defer f.close();
        try f.writeAll(record);
        return;
    };
    if (args.len != 3 or !std.mem.eql(u8, args[1], "open")) return error.InvalidArguments;
    try platform.openUrl(a, args[2]);
}
