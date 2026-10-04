const std = @import("std");
const platform = @import("platform.zig");
const terminal = @import("terminal.zig");
const A = std.mem.Allocator;
const Json = std.json.Value;
fn str(v: Json, key: []const u8) ![]const u8 {
    const x = if (v == .object) v.object.get(key) else null;
    if (x) |value| {
        if (value == .string) return value.string;
    }
    return error.InvalidAuthResponse;
}
fn opt(v: Json, key: []const u8) ?[]const u8 {
    return str(v, key) catch null;
}
fn number(v: Json, key: []const u8) !i64 {
    const x = if (v == .object) v.object.get(key) else null;
    if (x) |value| {
        if (value == .integer) return value.integer;
    }
    return error.InvalidAuthResponse;
}
fn parse(a: A, bytes: []const u8) !std.json.Parsed(Json) {
    return std.json.parseFromSlice(Json, a, bytes, .{ .allocate = .alloc_always });
}
fn path(a: A, dir: []const u8, name: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ dir, name });
}
fn read(a: A, dir: []const u8, name: []const u8) ![]const u8 {
    const p = try path(a, dir, name);
    defer a.free(p);
    try platform.requirePrivateFile(a, p);
    return std.fs.cwd().readFileAlloc(a, p, 1024 * 1024);
}
fn random(a: A) ![]const u8 {
    var bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    const out = try a.alloc(u8, 43);
    return std.base64.url_safe_no_pad.Encoder.encode(out, &bytes);
}
fn save(a: A, dir: []const u8, name: []const u8, bytes: []const u8) !void {
    if (terminal.cancelled()) return error.InputClosed;
    try std.fs.cwd().makePath(dir);
    const p = try path(a, dir, name);
    defer a.free(p);
    const suffix = try random(a);
    defer a.free(suffix);
    const tmp = try std.fmt.allocPrint(a, "{s}.{s}.tmp", .{ p, suffix });
    defer a.free(tmp);
    defer std.fs.cwd().deleteFile(tmp) catch {};
    const f = try std.fs.cwd().createFile(tmp, .{ .exclusive = true, .mode = 0o600 });
    defer f.close();
    try platform.privateFile(a, tmp);
    try f.writeAll(bytes);
    try f.sync();
    if (terminal.cancelled()) return error.InputClosed;
    try std.fs.cwd().rename(tmp, p);
}
fn authSignal(_: c_int) callconv(.c) void {
    terminal.cancelSession();
}
fn run(a: A, argv: []const []const u8, input: ?[]const u8) ![]const u8 {
    const signal_guard = try platform.SignalGuard.install(authSignal);
    defer signal_guard.restore();
    if (terminal.cancelled()) return error.InputClosed;
    var child = std.process.Child.init(argv, a);
    child.stdin_behavior = if (input != null) .Pipe else .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    var group = platform.ChildGroup.spawn(&child) catch |err| {
        if (err == error.FileNotFound) return error.AuthDependencyMissing;
        return err;
    };
    defer group.close();
    if (argv.len > 0 and std.mem.eql(u8, argv[0], "curl")) terminal.trackHttp(child.id);
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
    var err: std.ArrayList(u8) = .empty;
    defer err.deinit(a);
    try child.collectOutput(a, &out, &err, 1024 * 1024);
    const term = try child.wait();
    if (terminal.cancelled()) return error.InputClosed;
    if (term != .Exited or term.Exited != 0) return error.AuthDependencyFailed;
    return out.toOwnedSlice(a);
}
fn http(a: A, url: []const u8, body: ?[]const u8) ![]const u8 {
    if (body) |data| return run(a, &.{ "curl", "--disable", "--silent", "--show-error", "--fail-with-body", "--max-time", "30", "--proto", "=https", "-H", "Content-Type: application/x-www-form-urlencoded", "--data-binary", "@-", url }, data);
    return run(a, &.{ "curl", "--disable", "--silent", "--show-error", "--fail", "--max-time", "30", "--proto", "=https", url }, null);
}
fn enc(a: A, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') try out.append(a, c) else {
            try out.append(a, '%');
            try out.append(a, "0123456789ABCDEF"[c >> 4]);
            try out.append(a, "0123456789ABCDEF"[c & 15]);
        }
    }
    return out.toOwnedSlice(a);
}
fn form(a: A, fields: []const [2][]const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (fields, 0..) |pair, i| {
        if (i != 0) try out.append(a, '&');
        const v = try enc(a, pair[1]);
        defer a.free(v);
        try out.appendSlice(a, pair[0]);
        try out.append(a, '=');
        try out.appendSlice(a, v);
    }
    return out.toOwnedSlice(a);
}
fn decode(a: A, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%') {
            if (i + 2 >= s.len) return error.InvalidCallback;
            try out.append(a, try std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16));
            i += 2;
        } else try out.append(a, if (s[i] == '+') ' ' else s[i]);
    }
    return out.toOwnedSlice(a);
}
fn query(a: A, q: []const u8, key: []const u8) !?[]const u8 {
    var result: ?[]const u8 = null;
    var parts = std.mem.splitScalar(u8, q, '&');
    while (parts.next()) |part| {
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        if (std.mem.eql(u8, part[0..eq], key)) {
            if (result != null) return error.InvalidCallback;
            result = try decode(a, part[eq + 1 ..]);
        }
    }
    return result;
}

const Provider = struct { id: []const u8, issuer: []const u8, authorize: []const u8, token_url: []const u8, revoke: []const u8, userinfo: []const u8, scope: []const u8, env: []const u8 };
fn provider(id: []const u8) !Provider {
    if (std.mem.eql(u8, id, "grok")) return .{ .id = id, .issuer = "https://auth.x.ai", .authorize = "https://auth.x.ai/oauth2/authorize", .token_url = "https://auth.x.ai/oauth2/token", .revoke = "https://auth.x.ai/oauth2/revoke", .userinfo = "https://auth.x.ai/oauth2/userinfo", .scope = "openid profile email offline_access grok-cli:access api:access", .env = "DOIN_GROK_CLIENT_ID" };
    if (std.mem.eql(u8, id, "vercel")) return .{ .id = id, .issuer = "https://vercel.com", .authorize = "https://api.vercel.com/login/oauth/device-authorization", .token_url = "https://api.vercel.com/login/oauth/token", .revoke = "https://api.vercel.com/login/oauth/token/revoke", .userinfo = "https://api.vercel.com/login/oauth/userinfo", .scope = "openid offline_access", .env = "DOIN_VERCEL_CLIENT_ID" };
    if (std.mem.eql(u8, id, "openrouter")) return .{ .id = id, .issuer = "https://openrouter.ai", .authorize = "https://openrouter.ai/auth", .token_url = "https://openrouter.ai/api/v1/auth/keys", .revoke = "", .userinfo = "", .scope = "", .env = "" };
    return error.UnknownProvider;
}
fn filename(a: A, p: Provider) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}.json", .{p.id});
}
fn acquire(a: A, dir: []const u8) !std.fs.File {
    try std.fs.cwd().makePath(dir);
    const p = try path(a, dir, ".auth.lock");
    defer a.free(p);
    const f = try std.fs.cwd().createFile(p, .{ .truncate = false, .mode = 0o600 });
    errdefer f.close();
    if (!try platform.tryLockExclusive(f)) return error.AuthenticationBusy;
    return f;
}
fn bearer(a: A, url: []const u8, access: []const u8) ![]const u8 {
    for (access) |c| {
        if (c < 0x21 or c > 0x7e or c == '"' or c == '\\') return error.InvalidAuthResponse;
    }
    const config = try std.fmt.allocPrint(a, "header = \"Authorization: Bearer {s}\"\n", .{access});
    defer a.free(config);
    return run(a, &.{ "curl", "--disable", "--silent", "--show-error", "--fail", "--max-time", "30", "--proto", "=https", "--config", "-", url }, config);
}
fn persist(a: A, dir: []const u8, p: Provider, response: Json, client: []const u8, old: ?Json) !void {
    const access = try str(response, if (std.mem.eql(u8, p.id, "openrouter")) "key" else "access_token");
    if (access.len == 0) return error.InvalidAuthResponse;
    var expires: i64 = std.math.maxInt(i64);
    var refresh: []const u8 = "";
    var scope: []const u8 = "";
    var subject: []const u8 = "";
    if (!std.mem.eql(u8, p.id, "openrouter")) {
        if (!std.ascii.eqlIgnoreCase(try str(response, "token_type"), "Bearer")) return error.InvalidAuthResponse;
        const ttl = try number(response, "expires_in");
        if (ttl <= 0 or ttl > 365 * 86400) return error.InvalidAuthResponse;
        expires = std.time.timestamp() + ttl;
        refresh = opt(response, "refresh_token") orelse if (old) |v| try str(v, "refresh_token") else return error.InvalidAuthResponse;
        if (refresh.len == 0) return error.InvalidAuthResponse;
        if (std.mem.eql(u8, p.id, "vercel") and opt(response, "refresh_token") == null) return error.InvalidAuthResponse;
        scope = opt(response, "scope") orelse if (old) |v| try str(v, "scope") else return error.MissingGrantedScope;
        var wanted = std.mem.tokenizeScalar(u8, p.scope, ' ');
        while (wanted.next()) |word| {
            var granted = std.mem.tokenizeScalar(u8, scope, ' ');
            var found = false;
            while (granted.next()) |g| {
                if (std.mem.eql(u8, g, word)) found = true;
            }
            if (!found) return error.MissingGrantedScope;
        }
        const info = try bearer(a, p.userinfo, access);
        defer a.free(info);
        var user = try parse(a, info);
        defer user.deinit();
        subject = try str(user.value, "sub");
        if (subject.len == 0) return error.InvalidAccount;
        if (old) |v| {
            if (!std.mem.eql(u8, subject, try str(v, "subject"))) return error.AccountMismatch;
        }
        const bytes = try std.json.Stringify.valueAlloc(a, .{ .provider = p.id, .issuer = p.issuer, .client_id = client, .access_token = access, .refresh_token = refresh, .expires_at = expires, .scope = scope, .subject = subject }, .{});
        defer a.free(bytes);
        const name = try filename(a, p);
        defer a.free(name);
        return save(a, dir, name, bytes);
    }
    const bytes = try std.json.Stringify.valueAlloc(a, .{ .provider = p.id, .issuer = p.issuer, .client_id = client, .access_token = access, .refresh_token = refresh, .expires_at = expires, .scope = scope, .subject = subject }, .{});
    defer a.free(bytes);
    const name = try filename(a, p);
    defer a.free(name);
    try save(a, dir, name, bytes);
}
pub fn token(a: A, dir: []const u8, id: []const u8) ![]const u8 {
    const p = try provider(id);
    const lock = try acquire(a, dir);
    defer lock.close();
    const name = try filename(a, p);
    defer a.free(name);
    const bytes = read(a, dir, name) catch |err| {
        if (err == error.FileNotFound) return error.ProviderSignInRequired;
        return err;
    };
    defer a.free(bytes);
    var old = try parse(a, bytes);
    defer old.deinit();
    if (!std.mem.eql(u8, try str(old.value, "issuer"), p.issuer) or !std.mem.eql(u8, try str(old.value, "provider"), id)) return error.InvalidIssuer;
    if (try number(old.value, "expires_at") > std.time.timestamp() + 60) {
        const access = try str(old.value, "access_token");
        if (access.len == 0) return error.InvalidAuthResponse;
        return a.dupe(u8, access);
    }
    if (std.mem.eql(u8, id, "openrouter")) return error.ProviderSignInRequired;
    const client = try str(old.value, "client_id");
    const body = try form(a, &.{ .{ "grant_type", "refresh_token" }, .{ "client_id", client }, .{ "refresh_token", try str(old.value, "refresh_token") } });
    defer a.free(body);
    const response = http(a, p.token_url, body) catch |err| {
        if (err == error.InputClosed or terminal.cancelled()) return error.InputClosed;
        return error.ProviderRefreshFailed;
    };
    defer a.free(response);
    var fresh = try parse(a, response);
    defer fresh.deinit();
    try persist(a, dir, p, fresh.value, client, old.value);
    return a.dupe(u8, try str(fresh.value, "access_token"));
}
pub fn logout(a: A, dir: []const u8, id: []const u8) !void {
    if (terminal.cancelled()) return error.InputClosed;
    const p = try provider(id);
    const lock = try acquire(a, dir);
    defer lock.close();
    const name = try filename(a, p);
    defer a.free(name);
    const file = try path(a, dir, name);
    defer a.free(file);
    if (p.revoke.len > 0) {
        const bytes = read(a, dir, name) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer a.free(bytes);
        var old = try parse(a, bytes);
        defer old.deinit();
        if (!std.mem.eql(u8, try str(old.value, "issuer"), p.issuer)) return error.InvalidIssuer;
        const body = try form(a, &.{ .{ "token", try str(old.value, "refresh_token") }, .{ "token_type_hint", "refresh_token" }, .{ "client_id", try str(old.value, "client_id") } });
        defer a.free(body);
        const result = http(a, p.revoke, body) catch |err| blk: {
            if (err == error.InputClosed or terminal.cancelled()) return error.InputClosed;
            break :blk null;
        };
        if (result) |v| a.free(v) else std.debug.print("Remote revocation unconfirmed; disconnect doin in your provider account settings.\n", .{});
    } else std.debug.print("OpenRouter disconnected locally. Revoke the key in OpenRouter account settings if needed.\n", .{});
    if (terminal.cancelled()) return error.InputClosed;
    std.fs.cwd().deleteFile(file) catch |err| {
        if (err != error.FileNotFound) return err;
    };
}
pub fn login(a: A, dir: []const u8, id: []const u8) !void {
    const signal_guard = try platform.SignalGuard.install(authSignal);
    defer signal_guard.restore();
    if (terminal.cancelled()) return error.InputClosed;
    const p = try provider(id);
    const lock = try acquire(a, dir);
    defer lock.close();
    const router = std.mem.eql(u8, id, "openrouter");
    const client = if (router) try a.dupe(u8, "") else std.process.getEnvVarOwned(a, p.env) catch {
        std.debug.print("Register a public doin OAuth application with {s}, then set {s} to its client ID. No other app's identity is reused.\n", .{ id, p.env });
        return error.ProviderRegistrationRequired;
    };
    defer a.free(client);
    if (!router and client.len == 0) return error.ProviderRegistrationRequired;
    if (std.mem.eql(u8, id, "vercel")) return deviceLogin(a, dir, p, client);
    const state = try random(a);
    defer a.free(state);
    const verifier = try random(a);
    defer a.free(verifier);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    var challenge: [43]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&challenge, &digest);
    const address = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try address.listen(.{});
    defer server.deinit();
    const redirect = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/auth/callback", .{server.listen_address.getPort()});
    defer a.free(redirect);
    const params = if (router) try form(a, &.{ .{ "callback_url", redirect }, .{ "code_challenge", &challenge }, .{ "code_challenge_method", "S256" }, .{ "state", state }, .{ "key_label", "doin" } }) else try form(a, &.{ .{ "client_id", client }, .{ "redirect_uri", redirect }, .{ "response_type", "code" }, .{ "scope", p.scope }, .{ "code_challenge", &challenge }, .{ "code_challenge_method", "S256" }, .{ "state", state } });
    defer a.free(params);
    const url = try std.fmt.allocPrint(a, "{s}?{s}", .{ p.authorize, params });
    defer a.free(url);
    std.debug.print("Continue with {s}\n{s}\n", .{ id, url });
    platform.openUrl(a, url) catch {};
    const deadline = std.time.milliTimestamp() + 300000;
    while (std.time.milliTimestamp() < deadline) {
        if (terminal.cancelled()) return error.InputClosed;
        if (!try platform.socketReadable(server.stream.handle, 100)) continue;
        const conn = try server.accept();
        defer conn.stream.close();
        var buf: [16384]u8 = undefined;
        var n: usize = 0;
        const read_deadline = std.time.milliTimestamp() + 2000;
        while (n < buf.len and std.mem.indexOfScalar(u8, buf[0..n], '\n') == null) {
            if (std.time.milliTimestamp() > read_deadline) break;
            if (!try platform.socketReadable(conn.stream.handle, 100)) continue;
            const count = try conn.stream.read(buf[n..]);
            if (count == 0) break;
            n += count;
        }
        const start = "GET /auth/callback?";
        if (!std.mem.startsWith(u8, buf[0..n], start)) {
            conn.stream.writeAll("HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n") catch {};
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, buf[0..n], start.len, ' ') orelse continue;
        const q = buf[start.len..end];
        const got = try query(a, q, "state");
        defer if (got) |v| a.free(v);
        if (got == null or !std.mem.eql(u8, got.?, state)) {
            conn.stream.writeAll("HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n") catch {};
            continue;
        }
        const denial = try query(a, q, "error");
        defer if (denial) |v| a.free(v);
        if (denial != null) {
            conn.stream.writeAll("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 0\r\n\r\n") catch {};
            return error.AuthorizationDenied;
        }
        const code = try query(a, q, "code") orelse return error.InvalidCallback;
        defer a.free(code);
        const body = if (router) try std.json.Stringify.valueAlloc(a, .{ .code = code, .code_verifier = verifier, .code_challenge_method = "S256" }, .{}) else try form(a, &.{ .{ "grant_type", "authorization_code" }, .{ "client_id", client }, .{ "redirect_uri", redirect }, .{ "code", code }, .{ "code_verifier", verifier } });
        defer a.free(body);
        const response = if (router) try run(a, &.{ "curl", "--disable", "--silent", "--show-error", "--fail-with-body", "--max-time", "30", "--proto", "=https", "-H", "Content-Type: application/json", "--data-binary", "@-", p.token_url }, body) else try http(a, p.token_url, body);
        defer a.free(response);
        var fresh = try parse(a, response);
        defer fresh.deinit();
        try persist(a, dir, p, fresh.value, client, null);
        conn.stream.writeAll("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Type: text/plain\r\nContent-Length: 11\r\n\r\nConnected.\n") catch {};
        std.debug.print("{s} connected.\n", .{id});
        return;
    }
    return error.SignInTimedOut;
}
fn deviceLogin(a: A, dir: []const u8, p: Provider, client: []const u8) !void {
    const body = try form(a, &.{ .{ "client_id", client }, .{ "scope", p.scope } });
    defer a.free(body);
    const response = try http(a, p.authorize, body);
    defer a.free(response);
    var device = try parse(a, response);
    defer device.deinit();
    const url = opt(device.value, "verification_uri_complete") orelse try str(device.value, "verification_uri");
    if (!std.mem.startsWith(u8, url, "https://vercel.com/")) return error.InvalidIssuer;
    std.debug.print("Continue with Vercel\n{s}\nCode: {s}\n", .{ url, try str(device.value, "user_code") });
    platform.openUrl(a, url) catch {};
    const ttl = try number(device.value, "expires_in");
    if (ttl <= 0 or ttl > 1800) return error.InvalidAuthResponse;
    const deadline = std.time.milliTimestamp() + ttl * 1000;
    var interval = number(device.value, "interval") catch 5;
    if (interval < 1 or interval > 60) return error.InvalidAuthResponse;
    const poll_body = try form(a, &.{ .{ "client_id", client }, .{ "grant_type", "urn:ietf:params:oauth:grant-type:device_code" }, .{ "device_code", try str(device.value, "device_code") } });
    defer a.free(poll_body);
    while (std.time.milliTimestamp() < deadline) {
        const next = @min(deadline, std.time.milliTimestamp() + interval * 1000);
        while (std.time.milliTimestamp() < next) {
            if (terminal.cancelled()) return error.InputClosed;
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
        const result = try run(a, &.{ "curl", "--disable", "--silent", "--show-error", "--max-time", "30", "--proto", "=https", "-H", "Content-Type: application/x-www-form-urlencoded", "--data-binary", "@-", p.token_url }, poll_body);
        defer a.free(result);
        var parsed = try parse(a, result);
        defer parsed.deinit();
        if (opt(parsed.value, "error")) |err| {
            if (std.mem.eql(u8, err, "authorization_pending")) continue;
            if (std.mem.eql(u8, err, "slow_down")) {
                interval = @min(interval + 5, 60);
                continue;
            }
            if (std.mem.eql(u8, err, "access_denied")) return error.AuthorizationDenied;
            return error.ProviderSignInRequired;
        }
        try persist(a, dir, p, parsed.value, client, null);
        std.debug.print("Vercel connected.\n", .{});
        return;
    }
    return error.SignInTimedOut;
}
pub fn account(a: A, dir: []const u8, id: []const u8) ![]const u8 {
    const p = try provider(id);
    const name = try filename(a, p);
    defer a.free(name);
    const bytes = try read(a, dir, name);
    defer a.free(bytes);
    var record = try parse(a, bytes);
    defer record.deinit();
    if (!std.mem.eql(u8, try str(record.value, "issuer"), p.issuer) or !std.mem.eql(u8, try str(record.value, "provider"), id)) return error.InvalidIssuer;
    const subject = try str(record.value, "subject");
    if (subject.len == 0 or subject.len > 256) return error.InvalidAccount;
    for (subject) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return error.InvalidAccount;
    }
    return a.dupe(u8, subject);
}
pub fn grokVersion(a: A) ![]const u8 {
    const response = std.process.getEnvVarOwned(a, "DOIN_GROK_CLIENT_VERSION") catch try http(a, "https://x.ai/cli/stable", null);
    defer a.free(response);
    const version = std.mem.trim(u8, response, " \t\r\n");
    if (version.len == 0 or version.len > 64) return error.InvalidProviderVersion;
    var components = std.mem.splitScalar(u8, version, '.');
    var count: usize = 0;
    while (components.next()) |part| {
        if (part.len == 0 or part.len > 10) return error.InvalidProviderVersion;
        for (part) |c| if (!std.ascii.isDigit(c)) return error.InvalidProviderVersion;
        count += 1;
    }
    if (count != 3) return error.InvalidProviderVersion;
    return a.dupe(u8, version);
}
