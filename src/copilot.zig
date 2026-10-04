const std = @import("std");
const platform = @import("platform.zig");
const terminal = @import("terminal.zig");
const A = std.mem.Allocator;
const app = @import("build_options").app_name;

const helper =
    \\const fs = require('node:fs');
    \\const path = require('node:path');
    \\const {createRequire} = require('node:module');
    \\const {pathToFileURL} = require('node:url');
    \\const base = process.env.COPILOT_HOME;
    \\let client, session, stopping = false;
    \\async function stop(code) {
    \\  if(stopping) return; stopping = true;
    \\  const shutdown = setTimeout(async()=>{ try { if(client) await client.forceStop(); } catch {} process.exit(code || 1); },5000);
    \\  try { if(session) await session.disconnect(); } catch {}
    \\  try { if(client) await client.stop(); } catch {}
    \\  clearTimeout(shutdown);
    \\  process.exit(code);
    \\}
    \\process.on('SIGTERM', () => stop(130));
    \\process.on('SIGINT', () => stop(130));
    \\const timer = setTimeout(() => stop(124), 90000);
    \\(async () => {
    \\  let sdk;
    \\  try {
    \\    const loader = createRequire(path.join(base, 'package.json'));
    \\    const sdkPath = process.env.DOIN_COPILOT_SDK || loader.resolve('@github/copilot-sdk');
    \\    if(!process.env.DOIN_COPILOT_SDK) {
    \\      const metadata = JSON.parse(fs.readFileSync(path.resolve(path.dirname(sdkPath), '..', '..', 'package.json'), 'utf8'));
    \\      const version = metadata.version.split('.').map(Number);
    \\      if(version[0] !== 1 || version[1] < 0 || (version[1] === 0 && version[2] < 16)) throw Error('unsupported SDK');
    \\    }
    \\    sdk = await import(pathToFileURL(sdkPath).href);
    \\  } catch { process.stderr.write('Install Node and @github/copilot-sdk >=1.0.16 in the doin Copilot home.\n'); return stop(127); }
    \\  if(process.argv[1] === 'check') return stop(0);
    \\  const input = JSON.parse(fs.readFileSync(0, 'utf8'));
    \\  client = new sdk.CopilotClient({mode:'empty', baseDirectory:base, workingDirectory:base, useLoggedInUser:true});
    \\  await client.start();
    \\  session = await client.createSession({model:input.model || 'auto', availableTools:[],
    \\    enableFileHooks:false, enableSkills:false, enableHostGitOperations:false,
    \\    enableSessionStore:false, skipCustomInstructions:true, customAgents:[],
    \\    mcpServers:{}, memory:{enabled:false}, infiniteSessions:{enabled:false},
    \\    onPermissionRequest:async()=>({kind:'deny-by-default'}),
    \\    hooks:{onPreToolUse:async()=>({permissionDecision:'deny'})}});
    \\  const response = await session.sendAndWait({prompt:input.prompt}, 60000);
    \\  const text = response?.data?.content;
    \\  if(typeof text !== 'string' || !text.trim() || Buffer.byteLength(text)>1048576) throw Error('invalid answer');
    \\  process.stdout.write(text);
    \\  clearTimeout(timer);
    \\  await stop(0);
    \\})().catch(async()=>{process.stderr.write('Copilot request failed. Check login, SDK version, model and subscription.\n'); await stop(1);});
;

fn home(a: A) ![]const u8 {
    const config = if (try platform.env(a, "DOIN_CONFIG_DIR")) |v| v else if (try platform.env(a, "XDG_CONFIG_HOME")) |v| try std.fs.path.join(a, &.{ v, app }) else if (platform.windows) try std.fs.path.join(a, &.{ (try platform.env(a, "LOCALAPPDATA")) orelse return error.HomeMissing, app }) else try std.fs.path.join(a, &.{ try platform.home(a), ".config", app });
    defer a.free(config);
    const result = try std.fs.path.join(a, &.{ config, "copilot" });
    errdefer a.free(result);
    try std.fs.cwd().makePath(result);
    if (!platform.windows) {
        var directory = try std.fs.cwd().openDir(result, .{});
        defer directory.close();
        try std.posix.fchmod(directory.fd, 0o700);
    } else try platform.privateFile(a, result);
    return result;
}

fn environment(a: A, base: []const u8) !std.process.EnvMap {
    var map = try std.process.getEnvMap(a);
    errdefer map.deinit();
    try map.put("COPILOT_HOME", base);
    try map.put("COPILOT_DISABLE_KEYTAR", "1");
    try map.put("COPILOT_ALLOW_ALL", "false");
    try map.put("GITHUB_COPILOT_PROMPT_MODE_EXTENSIONS", "false");
    try map.put("GITHUB_COPILOT_PROMPT_MODE_REPO_HOOKS", "false");
    try map.put("COPILOT_AUTO_UPDATE", "false");
    map.remove("COPILOT_SKILLS_DIRS");
    map.remove("COPILOT_CUSTOM_INSTRUCTIONS_DIRS");
    return map;
}

fn interrupted(_: c_int) callconv(.c) void {
    terminal.cancelSession();
}

fn run(a: A, base: []const u8, argv: []const []const u8, input: ?[]const u8, visible: bool) ![]const u8 {
    if (terminal.cancelled()) return error.InputClosed;
    const signals = try platform.SignalGuard.install(interrupted);
    defer signals.restore();
    var map = try environment(a, base);
    defer map.deinit();
    var child = std.process.Child.init(argv, a);
    child.env_map = &map;
    child.cwd = base;
    child.stdin_behavior = if (input != null) .Pipe else .Ignore;
    child.stdout_behavior = if (visible) .Inherit else .Pipe;
    child.stderr_behavior = if (visible) .Inherit else .Pipe;
    var group = platform.ChildGroup.spawn(&child) catch |err| {
        if (err == error.FileNotFound) return error.CopilotDependencyMissing;
        return err;
    };
    defer group.close();
    terminal.trackHttp(child.id);
    defer terminal.clearHttp();
    errdefer {
        group.terminate(&child);
        _ = child.kill() catch {};
    }
    if (input) |bytes| {
        try child.stdin.?.writeAll(bytes);
        child.stdin.?.close();
        child.stdin = null;
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var errors: std.ArrayList(u8) = .empty;
    defer errors.deinit(a);
    if (!visible) try child.collectOutput(a, &out, &errors, 1024 * 1024);
    const term = try child.wait();
    if (terminal.cancelled()) return error.InputClosed;
    if (term != .Exited or term.Exited != 0) {
        if (term == .Exited and term.Exited == 127) return error.CopilotDependencyMissing;
        return error.CopilotRequestFailed;
    }
    return out.toOwnedSlice(a);
}

pub fn login(a: A) !void {
    const base = try home(a);
    defer a.free(base);
    const checked = try run(a, base, &.{ "node", "-e", helper, "check" }, null, false);
    a.free(checked);
    const result = try run(a, base, &.{ "copilot", "login", "--web-flow" }, null, true);
    a.free(result);
    const config = try std.fs.path.join(a, &.{ base, "config.json" });
    defer a.free(config);
    platform.privateFile(a, config) catch |err| if (err != error.FileNotFound) return err;
}

pub fn answer(a: A, model: []const u8, prompt: []const u8) ![]const u8 {
    const base = try home(a);
    defer a.free(base);
    const input = try std.json.Stringify.valueAlloc(a, .{ .model = model, .prompt = prompt }, .{});
    defer a.free(input);
    return run(a, base, &.{ "node", "-e", helper, "answer" }, input, false);
}

pub fn logout(a: A) !void {
    const base = try home(a);
    defer a.free(base);
    const config = try std.fs.path.join(a, &.{ base, "config.json" });
    defer a.free(config);
    platform.requirePrivateFile(a, config) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    try std.fs.cwd().deleteFile(config);
}
