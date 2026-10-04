const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform.zig");
const terminal = @import("terminal.zig");
const version = @import("version.zig");
const A = std.mem.Allocator;
const Release = struct { tag_name: []const u8, draft: bool = false, prerelease: bool = false };
const UpdatePlan = struct { tag: []const u8, asset: []const u8, destination: []const u8, stage: []const u8 };
fn signal(_: c_int) callconv(.c) void {
    terminal.cancelSession();
}
fn command(a: A, argv: []const []const u8, seconds: u64) ![]const u8 {
    return commandLimit(a, argv, seconds, 1024 * 1024);
}
fn commandLimit(a: A, argv: []const []const u8, seconds: u64, limit: usize) ![]const u8 {
    if (terminal.cancelled()) return error.InputClosed;
    var child = std.process.Child.init(argv, a);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    var group = platform.ChildGroup.spawn(&child) catch |err| {
        if (err == error.FileNotFound) return error.UpdateDependencyMissing;
        return err;
    };
    defer group.close();
    terminal.trackHttp(child.id);
    defer terminal.clearHttp();
    var reaped = false;
    errdefer {
        if (!reaped) {
            group.terminate(&child);
            _ = child.kill() catch {};
        }
    }
    try platform.pipeNonblocking(child.stdout.?, false);
    try platform.pipeNonblocking(child.stderr.?, false);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(a);
    var timer = try std.time.Timer.start();
    var out_done = false;
    var err_done = false;
    var buffer: [4096]u8 = undefined;
    var total: usize = 0;
    while (!out_done or !err_done) {
        if (terminal.cancelled()) return error.InputClosed;
        if (timer.read() > seconds * std.time.ns_per_s) return error.UpdateTimeout;
        var read_any = false;
        // Bound each stream's turn so a busy stdout cannot starve stderr or
        // cancellation checks. A batch drains far more than one pipe chunk.
        for (0..2) |stream| {
            var batch: usize = 0;
            while (batch < 256 * 1024) {
                if (terminal.cancelled()) return error.InputClosed;
                if (timer.read() > seconds * std.time.ns_per_s) return error.UpdateTimeout;
                const is_stdout = stream == 0;
                if ((is_stdout and out_done) or (!is_stdout and err_done)) break;
                const file = if (is_stdout) child.stdout.? else child.stderr.?;
                const available = try platform.pipeReadAvailable(file, &buffer);
                if (available) |n| {
                    if (n == 0) {
                        if (is_stdout) out_done = true else err_done = true;
                        break;
                    }
                    read_any = true;
                    batch += n;
                    total += n;
                    if (is_stdout) try output.appendSlice(a, buffer[0..n]);
                    if (total > limit) return error.UpdateOutputTooLarge;
                } else break;
            }
        }
        if (total > limit) return error.UpdateOutputTooLarge;
        if (!read_any) std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    try child.waitForSpawn();
    if (builtin.os.tag != .windows) {
        while (true) {
            if (terminal.cancelled()) return error.InputClosed;
            if (timer.read() > seconds * std.time.ns_per_s) return error.UpdateTimeout;
            const waited = std.posix.waitpid(child.id, std.posix.W.NOHANG);
            if (waited.pid != 0) {
                child.term = if (std.posix.W.IFEXITED(waited.status)) .{ .Exited = std.posix.W.EXITSTATUS(waited.status) } else .{ .Signal = std.posix.W.TERMSIG(waited.status) };
                reaped = true;
                group.terminate(&child);
                break;
            }
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }
    const result = try child.wait();
    reaped = true;
    if (terminal.cancelled()) return error.InputClosed;
    if (result != .Exited or result.Exited != 0) return error.UpdateCommandFailed;
    return output.toOwnedSlice(a);
}
fn fetch(a: A, url: []const u8, destination: ?[]const u8, cap: []const u8) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(a);
    try argv.appendSlice(a, &.{ "curl", "--disable", "--silent", "--show-error", "--fail", "--location", "--proto", "=https", "--proto-redir", "=https", "--connect-timeout", "10", "--max-time", "60", "--max-filesize", cap, "-H", "Accept: application/vnd.github+json", "-H", "X-GitHub-Api-Version: 2026-03-10", "-H", "User-Agent: doin-updater" });
    if (destination) |path| try argv.appendSlice(a, &.{ "--output", path });
    try argv.appendSlice(a, &.{ "--url", url });
    return command(a, argv.items, 65);
}
fn semver(text: []const u8) !std.SemanticVersion {
    const clean = if (std.mem.startsWith(u8, text, "v")) text[1..] else text;
    if (clean.len == 0 or clean.len > 64) return error.InvalidUpdateRelease;
    for (clean) |c| if (!(std.ascii.isDigit(c) or c == '.')) return error.InvalidUpdateRelease;
    return std.SemanticVersion.parse(clean) catch error.InvalidUpdateRelease;
}
fn repository(text: []const u8) bool {
    var parts = std.mem.splitScalar(u8, text, '/');
    const owner = parts.next() orelse return false;
    const repo = parts.next() orelse return false;
    if (parts.next() != null or owner.len == 0 or repo.len == 0 or owner.len > 100 or repo.len > 100) return false;
    for ([_][]const u8{ owner, repo }) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        for (part) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return false;
    }
    return true;
}
fn verifyChecksum(a: A, sums: []const u8, asset: []const u8, archive: []const u8) !void {
    var expected: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, sums, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, "\r");
        if (line.len < 66) continue;
        const name = std.mem.trimStart(u8, line[64..], " *\t");
        if (!std.mem.eql(u8, name, asset)) continue;
        if (expected != null) return error.InvalidUpdateChecksum;
        for (line[0..64]) |c| if (!std.ascii.isHex(c)) return error.InvalidUpdateChecksum;
        expected = line[0..64];
    }
    const wanted = expected orelse return error.InvalidUpdateChecksum;
    const file = try std.fs.cwd().openFile(archive, .{});
    defer file.close();
    if ((try file.stat()).size > 64 * 1024 * 1024) return error.UpdateArchiveTooLarge;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [32768]u8 = undefined;
    while (true) {
        const n = try file.read(&buffer);
        if (n == 0) break;
        hash.update(buffer[0..n]);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const actual = std.fmt.bytesToHex(digest, .lower);
    _ = a;
    if (!std.ascii.eqlIgnoreCase(wanted, &actual)) return error.UpdateChecksumMismatch;
}
pub fn run(a: A, args: []const []const u8) !void {
    if (args.len != 0) return error.InvalidUpdateArguments;
    if (builtin.os.tag == .windows) return error.UpdateWindowsUnsupported;
    const os = switch (builtin.os.tag) {
        .macos => "macos",
        .linux => "linux",
        else => return error.UpdatePlatformUnsupported,
    };
    const arch = switch (builtin.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => return error.UpdatePlatformUnsupported,
    };
    const guard = try platform.SignalGuard.install(signal);
    defer guard.restore();
    const repo = platform.getenv("DOIN_REPO") orelse "mitchellbernstein/doin.sh";
    if (!repository(repo)) return error.InvalidUpdateRepository;
    try terminal.output("Checking latest doin release…\n");
    const metadata = try fetch(a, try std.fmt.allocPrint(a, "https://api.github.com/repos/{s}/releases/latest", .{repo}), null, "1048576");
    const release = std.json.parseFromSlice(Release, a, metadata, .{ .ignore_unknown_fields = true }) catch return error.InvalidUpdateRelease;
    defer release.deinit();
    const latest = try semver(release.value.tag_name);
    if (release.value.draft or release.value.prerelease) return error.InvalidUpdateRelease;
    if (latest.order(try semver(version.current)) != .gt) {
        try terminal.output(try std.fmt.allocPrint(a, "doin {s} is up to date.\n", .{version.current}));
        return;
    }
    const destination = try std.fs.selfExePathAlloc(a);
    const original = try std.fs.cwd().statFile(destination);
    const parent = std.fs.path.dirname(destination) orelse return error.InvalidUpdateDestination;
    var random: [16]u8 = undefined;
    std.crypto.random.bytes(&random);
    const stage = try std.fmt.allocPrint(a, "{s}/.doin-update-{s}", .{ parent, std.fmt.bytesToHex(random, .lower) });
    try std.fs.cwd().makeDir(stage);
    defer std.fs.cwd().deleteTree(stage) catch {};
    if (builtin.os.tag != .windows) {
        var directory = try std.fs.cwd().openDir(stage, .{});
        defer directory.close();
        try std.posix.fchmod(directory.fd, 0o700);
    }
    const plan: UpdatePlan = .{ .tag = release.value.tag_name, .asset = try std.fmt.allocPrint(a, "doin-{s}-{s}.tar.gz", .{ os, arch }), .destination = destination, .stage = stage };
    const base = try std.fmt.allocPrint(a, "https://github.com/{s}/releases/download/{s}", .{ repo, plan.tag });
    const archive = try std.fs.path.join(a, &.{ plan.stage, "release.tar.gz" });
    const sums = try fetch(a, try std.fmt.allocPrint(a, "{s}/SHA256SUMS", .{base}), null, "1048576");
    _ = try fetch(a, try std.fmt.allocPrint(a, "{s}/{s}", .{ base, plan.asset }), archive, "67108864");
    try verifyChecksum(a, sums, plan.asset, archive);
    const listing = try command(a, &.{ "tar", "-tzf", archive }, 15);
    var names = std.mem.splitScalar(u8, listing, '\n');
    var found: usize = 0;
    while (names.next()) |name| {
        if (std.mem.eql(u8, name, "doin")) found += 1;
    }
    if (found != 1) return error.InvalidUpdateArchive;
    const details = try command(a, &.{ "tar", "-tvzf", archive, "doin" }, 15);
    if (details.len == 0 or details[0] != '-') return error.InvalidUpdateArchive;
    const executable_bytes = try commandLimit(a, &.{ "tar", "-xOzf", archive, "doin" }, 15, 64 * 1024 * 1024);
    defer a.free(executable_bytes);
    const candidate = try std.fs.path.join(a, &.{ plan.stage, "doin" });
    {
        const file = try std.fs.cwd().createFile(candidate, .{ .exclusive = true, .read = true, .mode = 0o700 });
        defer file.close();
        try file.writeAll(executable_bytes);
        var link_buffer: [4096]u8 = undefined;
        if (std.fs.cwd().readLink(candidate, &link_buffer)) |_| return error.InvalidUpdateArchive else |err| {
            if (err != error.NotLink) return err;
        }
        const stat = try file.stat();
        if (stat.kind != .file or stat.size == 0 or stat.size > 64 * 1024 * 1024) return error.InvalidUpdateArchive;
        if (builtin.os.tag != .windows) try std.posix.fchmod(file.handle, 0o755);
        try file.sync();
    }
    const result = try command(a, &.{ candidate, "--version" }, 10);
    const expected = try std.fmt.allocPrint(a, "doin {d}.{d}.{d}", .{ latest.major, latest.minor, latest.patch });
    if (!std.mem.eql(u8, std.mem.trim(u8, result, " \r\n\t"), expected)) return error.UpdateVersionMismatch;
    if (terminal.cancelled()) return error.InputClosed;
    const existing = try std.fs.cwd().statFile(plan.destination);
    if (existing.inode != original.inode or existing.size != original.size or existing.mtime != original.mtime) return error.UpdateDestinationChanged;
    try std.fs.cwd().rename(candidate, plan.destination);
    try terminal.output(try std.fmt.allocPrint(a, "Updated to {s}. Run doin again.\n", .{expected}));
}
