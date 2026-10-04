const std = @import("std");
pub const windows = @import("builtin").os.tag == .windows;
const A = std.mem.Allocator;
const w = std.os.windows;
const c = if (windows) @cImport({
    @cInclude("windows.h");
    @cInclude("shellapi.h");
    @cInclude("sddl.h");
    @cInclude("aclapi.h");
}) else struct {};
pub fn env(a: A, name: []const u8) !?[]const u8 {
    return std.process.getEnvVarOwned(a, name) catch |err| if (err == error.EnvironmentVariableNotFound) null else err;
}
var environment: std.StringHashMap(?[]const u8) = std.StringHashMap(?[]const u8).init(std.heap.page_allocator);
pub fn getenv(name: []const u8) ?[]const u8 {
    if (environment.get(name)) |item| return item;
    const item = env(std.heap.page_allocator, name) catch return null;
    const key = std.heap.page_allocator.dupe(u8, name) catch return item;
    environment.put(key, item) catch {};
    return item;
}
pub fn killDirect(id: std.process.Child.Id) void {
    if (windows) {
        _ = c.TerminateProcess(id, 130);
    } else {
        _ = std.c.kill(id, std.posix.SIG.TERM);
    }
}
pub fn home(a: A) ![]const u8 {
    return (try env(a, if (windows) "USERPROFILE" else "HOME")) orelse error.HomeMissing;
}
fn file(fd: u2) std.fs.File {
    return switch (fd) {
        0 => std.fs.File.stdin(),
        1 => std.fs.File.stdout(),
        else => std.fs.File.stderr(),
    };
}
pub fn read(fd: u2, buffer: []u8) !usize {
    return file(fd).read(buffer);
}
pub fn write(fd: u2, text: []const u8) !void {
    try file(fd).writeAll(text);
}
pub fn isTty(fd: u2) bool {
    if (!windows) return std.posix.isatty(fd);
    var mode: w.DWORD = 0;
    return w.kernel32.GetConsoleMode(file(fd).handle, &mode) != 0;
}
pub const Size = struct { rows: usize, cols: usize };
pub fn size() Size {
    if (windows) {
        var info: w.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (w.kernel32.GetConsoleScreenBufferInfo(file(1).handle, &info) != 0)
            return .{ .rows = @intCast(info.srWindow.Bottom - info.srWindow.Top + 1), .cols = @intCast(info.srWindow.Right - info.srWindow.Left + 1) };
    } else {
        var info: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        if (std.c.ioctl(1, @as(c_int, @intCast(std.c.T.IOCGWINSZ)), &info) == 0 and info.row > 0 and info.col > 0) return .{ .rows = info.row, .cols = info.col };
    }
    return .{ .rows = 24, .cols = 80 };
}
pub const OutputState = struct {
    mode: ?w.DWORD = null,
    codepage: w.UINT = 0,
    pub fn capture() !OutputState {
        if (!windows or !isTty(1)) return .{};
        var original: w.DWORD = 0;
        if (w.kernel32.GetConsoleMode(file(1).handle, &original) == 0) return error.ConsoleUnavailable;
        const state: OutputState = .{ .mode = original, .codepage = w.kernel32.GetConsoleOutputCP() };
        if (w.kernel32.SetConsoleMode(file(1).handle, original | 0x0001 | 0x0004) == 0) return error.ConsoleModeFailed;
        if (w.kernel32.SetConsoleOutputCP(65001) == 0) {
            state.restore();
            return error.ConsoleModeFailed;
        }
        return state;
    }
    pub fn restore(self: *const OutputState) void {
        if (windows) if (self.mode) |mode| {
            _ = w.kernel32.SetConsoleMode(file(1).handle, mode);
            _ = w.kernel32.SetConsoleOutputCP(self.codepage);
        };
    }
};
pub const ConsoleState = struct {
    input: if (windows) w.DWORD else std.posix.termios,
    output: if (windows) w.DWORD else void = if (windows) 0 else {},
    codepage: if (windows) w.UINT else void = if (windows) 0 else {},
    pub fn capture() !ConsoleState {
        if (!windows) return .{ .input = try std.posix.tcgetattr(0) };
        var state: ConsoleState = undefined;
        if (w.kernel32.GetConsoleMode(file(0).handle, &state.input) == 0 or w.kernel32.GetConsoleMode(file(1).handle, &state.output) == 0) return error.ConsoleUnavailable;
        state.codepage = w.kernel32.GetConsoleOutputCP();
        return state;
    }
    pub fn raw(self: *const ConsoleState) !void {
        errdefer self.restore();
        if (windows) {
            // Disable line editing, echo, processed Ctrl+C and QuickEdit; request VT keys.
            const input = (self.input & ~@as(w.DWORD, 0x0001 | 0x0002 | 0x0004 | 0x0040 | 0x0008)) | 0x0200 | 0x0080;
            if (w.kernel32.SetConsoleMode(file(0).handle, input) == 0 or w.kernel32.SetConsoleMode(file(1).handle, self.output | 0x0001 | 0x0004) == 0) return error.ConsoleModeFailed;
            _ = w.kernel32.SetConsoleOutputCP(65001);
        } else {
            var mode = self.input;
            mode.lflag.ICANON = false;
            mode.lflag.ECHO = false;
            mode.lflag.ISIG = false;
            mode.lflag.IEXTEN = false;
            mode.oflag.OPOST = false;
            mode.iflag.IXON = false;
            mode.iflag.ICRNL = false;
            mode.iflag.BRKINT = false;
            mode.iflag.INPCK = false;
            mode.iflag.ISTRIP = false;
            mode.cc[@intFromEnum(std.posix.V.MIN)] = 1;
            mode.cc[@intFromEnum(std.posix.V.TIME)] = 0;
            try std.posix.tcsetattr(0, .NOW, mode);
        }
    }
    pub fn restore(self: *const ConsoleState) void {
        if (windows) {
            _ = w.kernel32.SetConsoleMode(file(0).handle, self.input);
            _ = w.kernel32.SetConsoleMode(file(1).handle, self.output);
            _ = w.kernel32.SetConsoleOutputCP(self.codepage);
        } else std.posix.tcsetattr(0, .NOW, self.input) catch {};
    }
};
pub fn readByte(timeout_ms: i32) !?u8 {
    if (windows) {
        const status = c.WaitForSingleObject(file(0).handle, if (timeout_ms < 0) c.INFINITE else @as(c.DWORD, @intCast(timeout_ms)));
        if (status == c.WAIT_TIMEOUT) return null;
        if (status != c.WAIT_OBJECT_0) return error.ConsoleReadFailed;
    } else {
        var fds = [_]std.posix.pollfd{.{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&fds, timeout_ms) == 0) return null;
    }
    var byte: [1]u8 = undefined;
    if (try read(0, &byte) == 0) return error.InputClosed;
    return byte[0];
}
const Handler = *const fn (c_int) callconv(.c) void;
var current_handler = std.atomic.Value(?Handler).init(null);
fn ctrl(event: w.DWORD) callconv(.winapi) w.BOOL {
    if (event == 0 or event == 1 or event == 2 or event == 5 or event == 6) {
        if (current_handler.load(.seq_cst)) |handler| {
            handler(if (event <= 1) 2 else 15);
            return 1;
        }
    }
    return 0;
}
pub const SignalGuard = struct {
    previous: ?Handler = null,
    old_int: if (windows) void else std.posix.Sigaction = undefined,
    old_term: if (windows) void else std.posix.Sigaction = undefined,
    pub fn install(handler: Handler) !SignalGuard {
        var guard: SignalGuard = .{};
        if (windows) {
            guard.previous = current_handler.load(.seq_cst);
            current_handler.store(handler, .seq_cst);
            if (guard.previous == null and w.kernel32.SetConsoleCtrlHandler(ctrl, 1) == 0) {
                current_handler.store(null, .seq_cst);
                return error.SignalHandlerFailed;
            }
        } else {
            const action: std.posix.Sigaction = .{ .handler = .{ .handler = handler }, .mask = std.posix.sigemptyset(), .flags = 0 };
            std.posix.sigaction(std.posix.SIG.INT, &action, &guard.old_int);
            std.posix.sigaction(std.posix.SIG.TERM, &action, &guard.old_term);
        }
        return guard;
    }
    pub fn restore(self: *const SignalGuard) void {
        if (windows) {
            current_handler.store(self.previous, .seq_cst);
            if (self.previous == null) _ = w.kernel32.SetConsoleCtrlHandler(ctrl, 0);
        } else {
            std.posix.sigaction(std.posix.SIG.INT, &self.old_int, null);
            std.posix.sigaction(std.posix.SIG.TERM, &self.old_term, null);
        }
    }
};
// Child is suspended until it belongs to its private kill-on-close job.
pub const ChildGroup = struct {
    job: if (windows) c.HANDLE else void = if (windows) null else {},
    pub fn spawn(child: *std.process.Child) !ChildGroup {
        var group: ChildGroup = .{};
        if (windows) child.start_suspended = true else child.pgid = 0;
        try child.spawn();
        errdefer {
            _ = child.kill() catch {};
        }
        if (windows) {
            group.job = c.CreateJobObjectW(null, null);
            if (group.job == null) return error.ProcessGroupFailed;
            errdefer _ = c.CloseHandle(group.job);
            var limits = std.mem.zeroes(c.JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
            limits.BasicLimitInformation.LimitFlags = c.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            if (c.SetInformationJobObject(group.job, c.JobObjectExtendedLimitInformation, &limits, @sizeOf(@TypeOf(limits))) == 0 or c.AssignProcessToJobObject(group.job, child.id) == 0) return error.ProcessGroupFailed;
            if (c.ResumeThread(child.thread_handle) == 0xffffffff) return error.ProcessGroupFailed;
        }
        return group;
    }
    pub fn done(_: *const ChildGroup, child: *std.process.Child) bool {
        if (windows) return c.WaitForSingleObject(child.id, 0) == c.WAIT_OBJECT_0;
        // POSIX wait/reap remains at the caller until its lifecycle is migrated.
        return false;
    }
    pub fn terminate(self: *ChildGroup, child: *std.process.Child) void {
        if (windows) {
            if (self.job != null) _ = c.TerminateJobObject(self.job, 130);
        } else {
            std.posix.kill(-child.id, std.posix.SIG.TERM) catch {};
            std.Thread.sleep(80 * std.time.ns_per_ms);
            std.posix.kill(-child.id, std.posix.SIG.KILL) catch {};
        }
    }
    pub fn close(self: *ChildGroup) void {
        if (windows and self.job != null) {
            _ = c.CloseHandle(self.job);
            self.job = null;
        }
    }
};
pub fn pipeNonblocking(f: std.fs.File, writing: bool) !void {
    if (windows) {
        if (writing) {
            var mode: c.DWORD = c.PIPE_NOWAIT;
            if (c.SetNamedPipeHandleState(f.handle, &mode, null, null) == 0) return error.PipeModeFailed;
        }
    } else {
        const flags = try std.posix.fcntl(f.handle, std.posix.F.GETFL, 0);
        _ = try std.posix.fcntl(f.handle, std.posix.F.SETFL, flags | (@as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK")));
    }
}
pub fn pipeWriteAvailable(f: std.fs.File, bytes: []const u8) !usize {
    if (windows) {
        var count: c.DWORD = 0;
        if (c.WriteFile(f.handle, bytes.ptr, @intCast(@min(bytes.len, 4096)), &count, null) == 0) {
            if (c.GetLastError() == c.ERROR_NO_DATA) return error.WouldBlock;
            return error.BrokenPipe;
        }
        if (count == 0) return error.WouldBlock;
        return count;
    }
    return std.posix.write(f.handle, bytes);
}
pub fn pipeReadAvailable(f: std.fs.File, buffer: []u8) !?usize {
    if (windows) {
        var count: c.DWORD = 0;
        if (c.PeekNamedPipe(f.handle, null, 0, null, &count, null) == 0) {
            if (c.GetLastError() == c.ERROR_BROKEN_PIPE) return 0;
            return error.PipeReadFailed;
        }
        if (count == 0) return null;
        return try f.read(buffer[0..@min(buffer.len, count)]);
    }
    return std.posix.read(f.handle, buffer) catch |err| if (err == error.WouldBlock) null else err;
}
pub fn socketReadable(handle: std.posix.socket_t, timeout_ms: i32) !bool {
    if (windows) {
        var poll = [_]w.ws2_32.WSAPOLLFD{.{ .fd = handle, .events = 0x0300, .revents = 0 }};
        const result = w.ws2_32.WSAPoll(&poll, 1, timeout_ms);
        if (result < 0) return error.SocketPollFailed;
        return result > 0;
    }
    var poll = [_]std.posix.pollfd{.{ .fd = handle, .events = std.posix.POLL.IN, .revents = 0 }};
    return try std.posix.poll(&poll, timeout_ms) > 0;
}
pub fn openUrl(a: A, url: []const u8) !void {
    if (getenv("DOIN_BROWSER_COMMAND")) |exe| {
        var child = std.process.Child.init(&.{ exe, url }, a);
        const term = try child.spawnAndWait();
        if (term != .Exited or term.Exited != 0) return error.BrowserOpenFailed;
        return;
    }
    if (windows) {
        const utf16 = try std.unicode.utf8ToUtf16LeAllocZ(a, url);
        defer a.free(utf16);
        const result = c.ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("open"), utf16.ptr, null, null, c.SW_SHOWNORMAL);
        if (@intFromPtr(result) <= 32) return error.BrowserOpenFailed;
    } else {
        var child = std.process.Child.init(&.{ if (@import("builtin").os.tag == .macos) "open" else "xdg-open", url }, a);
        const term = try child.spawnAndWait();
        if (term != .Exited or term.Exited != 0) return error.BrowserOpenFailed;
    }
}
fn userSid(a: A) ![]u8 {
    var token: c.HANDLE = null;
    if (c.OpenProcessToken(c.GetCurrentProcess(), c.TOKEN_QUERY, &token) == 0) return error.PrivateAclFailed;
    defer _ = c.CloseHandle(token);
    var needed: c.DWORD = 0;
    _ = c.GetTokenInformation(token, c.TokenUser, null, 0, &needed);
    if (needed == 0 or needed > 65536) return error.PrivateAclFailed;
    const buffer = try a.alignedAlloc(u8, .of(c.TOKEN_USER), needed);
    defer a.free(buffer);
    if (c.GetTokenInformation(token, c.TokenUser, buffer.ptr, needed, &needed) == 0) return error.PrivateAclFailed;
    const info: *c.TOKEN_USER = @ptrCast(buffer.ptr);
    const sid = info.User.Sid;
    const len = c.GetLengthSid(sid);
    if (len == 0 or len > 1024) return error.PrivateAclFailed;
    const result = try a.alloc(u8, len);
    if (c.CopySid(len, result.ptr, sid) == 0) {
        a.free(result);
        return error.PrivateAclFailed;
    }
    return result;
}
pub fn currentUserSid(a: A) ![]const u8 {
    if (!windows) return error.WindowsOnly;
    const sid = try userSid(a);
    defer a.free(sid);
    var sid_text: c.LPWSTR = null;
    if (c.ConvertSidToStringSidW(sid.ptr, &sid_text) == 0) return error.PrivateAclFailed;
    defer _ = c.LocalFree(sid_text);
    return std.unicode.utf16LeToUtf8Alloc(a, std.mem.span(sid_text));
}
pub fn privateFile(a: A, path: []const u8) !void {
    if (!windows) {
        const f = try std.fs.cwd().openFile(path, .{});
        defer f.close();
        try f.chmod(0o600);
        return;
    }
    const sid = try userSid(a);
    defer a.free(sid);
    var sid_text: c.LPWSTR = null;
    if (c.ConvertSidToStringSidW(sid.ptr, &sid_text) == 0) return error.PrivateAclFailed;
    defer _ = c.LocalFree(sid_text);
    const sid_utf8 = try std.unicode.utf16LeToUtf8Alloc(a, std.mem.span(sid_text));
    defer a.free(sid_utf8);
    const sddl = try std.fmt.allocPrint(a, "D:P(A;;FA;;;{s})", .{sid_utf8});
    defer a.free(sddl);
    const description = try std.unicode.utf8ToUtf16LeAllocZ(a, sddl);
    defer a.free(description);
    var descriptor: c.PSECURITY_DESCRIPTOR = null;
    if (c.ConvertStringSecurityDescriptorToSecurityDescriptorW(description.ptr, c.SDDL_REVISION_1, &descriptor, null) == 0) return error.PrivateAclFailed;
    defer _ = c.LocalFree(descriptor);
    var acl: c.PACL = null;
    var present: c.BOOL = 0;
    var defaulted: c.BOOL = 0;
    if (c.GetSecurityDescriptorDacl(descriptor, &present, &acl, &defaulted) == 0 or present == 0 or acl == null) return error.PrivateAclFailed;
    const name = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
    defer a.free(name);
    if (c.SetNamedSecurityInfoW(name.ptr, c.SE_FILE_OBJECT, c.OWNER_SECURITY_INFORMATION | c.DACL_SECURITY_INFORMATION | c.PROTECTED_DACL_SECURITY_INFORMATION, sid.ptr, null, acl, null) != c.ERROR_SUCCESS) return error.PrivateAclFailed;
    try requirePrivateFile(a, path);
}
pub fn requirePrivateFile(a: A, path: []const u8) !void {
    if (!windows) {
        const f = try std.fs.cwd().openFile(path, .{});
        defer f.close();
        if ((try f.stat()).mode & 0o077 != 0) return error.PrivateFileRequired;
        return;
    }
    const sid = try userSid(a);
    defer a.free(sid);
    const name = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
    defer a.free(name);
    var owner: c.PSID = null;
    var acl: c.PACL = null;
    var descriptor: c.PSECURITY_DESCRIPTOR = null;
    if (c.GetNamedSecurityInfoW(name.ptr, c.SE_FILE_OBJECT, c.OWNER_SECURITY_INFORMATION | c.DACL_SECURITY_INFORMATION, &owner, null, &acl, null, &descriptor) != c.ERROR_SUCCESS) return error.PrivateAclFailed;
    defer _ = c.LocalFree(descriptor);
    if (owner == null or acl == null or c.EqualSid(owner, sid.ptr) == 0 or acl.*.AceCount != 1) return error.PrivateFileRequired;
    var control: c.SECURITY_DESCRIPTOR_CONTROL = 0;
    var revision: c.DWORD = 0;
    if (c.GetSecurityDescriptorControl(descriptor, &control, &revision) == 0 or control & c.SE_DACL_PROTECTED == 0) return error.PrivateFileRequired;
    var raw_ace: ?*anyopaque = null;
    if (c.GetAce(acl, 0, &raw_ace) == 0 or raw_ace == null) return error.PrivateFileRequired;
    const ace: *c.ACCESS_ALLOWED_ACE = @ptrCast(@alignCast(raw_ace.?));
    if (ace.Header.AceType != c.ACCESS_ALLOWED_ACE_TYPE or c.EqualSid(@ptrCast(&ace.SidStart), sid.ptr) == 0 or ace.Mask & c.FILE_ALL_ACCESS != c.FILE_ALL_ACCESS) return error.PrivateFileRequired;
}

pub fn tryLockExclusive(f: std.fs.File) !bool {
    if (!windows) return f.tryLock(.exclusive);
    var status: w.IO_STATUS_BLOCK = undefined;
    const offset: w.LARGE_INTEGER = 0;
    const length: w.LARGE_INTEGER = 1;
    w.LockFile(f.handle, null, null, null, &status, &offset, &length, null, w.TRUE, w.TRUE) catch |err| {
        if (err == error.WouldBlock) return false;
        return err;
    };
    return true;
}
