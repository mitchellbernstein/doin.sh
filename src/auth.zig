const std = @import("std");
const platform = @import("platform.zig");
const terminal = @import("terminal.zig");
const A = std.mem.Allocator;
const issuer = "https://auth.openai.com";
const resource = "https://api.openai.com/v1";
const requested_scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct";
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
fn isLegacyHostId(value: []const u8) bool {
    if (value.len != 43) return false;
    for (value) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}
fn newHostId(a: A) ![]const u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const out = try a.alloc(u8, 45);
    @memcpy(out[0..9], "urn:uuid:");
    const hex = "0123456789abcdef";
    var j: usize = 9;
    for (bytes, 0..) |byte, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[j] = '-';
            j += 1;
        }
        out[j] = hex[byte >> 4];
        out[j + 1] = hex[byte & 15];
        j += 2;
    }
    return out;
}
fn save(a: A, dir: []const u8, name: []const u8, bytes: []const u8) !void {
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
    try std.fs.cwd().rename(tmp, p);
}
fn run(a: A, argv: []const []const u8, input: ?[]const u8) ![]const u8 {
    if (terminal.cancelled()) return error.InputClosed;
    var child = std.process.Child.init(argv, a);
    child.stdin_behavior = if (input != null) .Pipe else .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch |err| {
        if (err == error.FileNotFound) return error.AuthDependencyMissing;
        return err;
    };
    if (argv.len > 0 and std.mem.eql(u8, argv[0], "curl")) terminal.trackHttp(child.id);
    defer terminal.clearHttp();
    errdefer {
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
fn b64(a: A, s: []const u8) ![]const u8 {
    const n = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(s);
    const out = try a.alloc(u8, n);
    errdefer a.free(out);
    try std.base64.url_safe_no_pad.Decoder.decode(out, s);
    return out;
}
fn der(a: A, tag: u8, bytes: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, tag);
    if (bytes.len < 128) try out.append(a, @intCast(bytes.len)) else {
        var n = bytes.len;
        var buf: [8]u8 = undefined;
        var i: usize = 8;
        while (n != 0) {
            i -= 1;
            buf[i] = @intCast(n & 255);
            n >>= 8;
        }
        try out.append(a, @as(u8, 128) | @as(u8, @intCast(8 - i)));
        try out.appendSlice(a, buf[i..]);
    }
    try out.appendSlice(a, bytes);
    return out.toOwnedSlice(a);
}
fn integer(a: A, bytes: []const u8) ![]const u8 {
    if (bytes.len == 0) return error.InvalidJwk;
    if (bytes[0] & 128 == 0) return der(a, 2, bytes);
    const padded = try std.mem.concat(a, u8, &.{ &.{0}, bytes });
    defer a.free(padded);
    return der(a, 2, padded);
}
fn verify(a: A, dir: []const u8, jwt: []const u8, client: []const u8, nonce: ?[]const u8, subject: ?[]const u8) !std.json.Parsed(Json) {
    var parts = std.mem.splitScalar(u8, jwt, '.');
    const h = parts.next() orelse return error.InvalidIdToken;
    const p = parts.next() orelse return error.InvalidIdToken;
    const s = parts.next() orelse return error.InvalidIdToken;
    if (parts.next() != null) return error.InvalidIdToken;
    const hb = try b64(a, h);
    defer a.free(hb);
    var header = try parse(a, hb);
    defer header.deinit();
    if (!std.mem.eql(u8, try str(header.value, "alg"), "RS256")) return error.InvalidSignature;
    const kid = try str(header.value, "kid");
    const jwks = try http(a, issuer ++ "/.well-known/jwks.json", null);
    defer a.free(jwks);
    var keys = try parse(a, jwks);
    defer keys.deinit();
    if (keys.value != .object) return error.InvalidJwk;
    const list = keys.value.object.get("keys") orelse return error.InvalidJwk;
    if (list != .array) return error.InvalidJwk;
    var chosen: ?Json = null;
    for (list.array.items) |key| {
        if (std.mem.eql(u8, opt(key, "kid") orelse "", kid) and std.mem.eql(u8, opt(key, "kty") orelse "", "RSA")) {
            chosen = key;
            break;
        }
    }
    const key = chosen orelse return error.InvalidSignature;
    if (!std.mem.eql(u8, opt(key, "use") orelse "sig", "sig") or !std.mem.eql(u8, opt(key, "alg") orelse "RS256", "RS256")) return error.InvalidJwk;
    const n = try b64(a, try str(key, "n"));
    defer a.free(n);
    const e = try b64(a, try str(key, "e"));
    defer a.free(e);
    const nd = try integer(a, n);
    defer a.free(nd);
    const ed = try integer(a, e);
    defer a.free(ed);
    const both = try std.mem.concat(a, u8, &.{ nd, ed });
    defer a.free(both);
    const rsa = try der(a, 48, both);
    defer a.free(rsa);
    const bitdata = try std.mem.concat(a, u8, &.{ &.{0}, rsa });
    defer a.free(bitdata);
    const bit = try der(a, 3, bitdata);
    defer a.free(bit);
    const alg = [_]u8{ 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00 };
    const inner = try std.mem.concat(a, u8, &.{ &alg, bit });
    defer a.free(inner);
    const spki = try der(a, 48, inner);
    defer a.free(spki);
    const signature = try b64(a, s);
    defer a.free(signature);
    const id = try random(a);
    defer a.free(id);
    const keyname = try std.fmt.allocPrint(a, ".verify-{s}.der", .{id});
    defer a.free(keyname);
    const signame = try std.fmt.allocPrint(a, ".verify-{s}.sig", .{id});
    defer a.free(signame);
    try save(a, dir, keyname, spki);
    try save(a, dir, signame, signature);
    const kp = try path(a, dir, keyname);
    defer a.free(kp);
    defer std.fs.cwd().deleteFile(kp) catch {};
    const sigp = try path(a, dir, signame);
    defer a.free(sigp);
    defer std.fs.cwd().deleteFile(sigp) catch {};
    const signed = jwt[0 .. h.len + 1 + p.len];
    const result = try run(a, &.{ "openssl", "dgst", "-sha256", "-verify", kp, "-keyform", "DER", "-signature", sigp }, signed);
    defer a.free(result);
    const pb = try b64(a, p);
    defer a.free(pb);
    var claims = try parse(a, pb);
    errdefer claims.deinit();
    if (!std.mem.eql(u8, try str(claims.value, "iss"), issuer)) return error.InvalidIssuer;
    const aud = claims.value.object.get("aud") orelse return error.InvalidAudience;
    var matches = false;
    if (aud == .string) matches = std.mem.eql(u8, aud.string, client) else if (aud == .array) {
        for (aud.array.items) |v| {
            if (v == .string and std.mem.eql(u8, v.string, client)) matches = true;
        }
    }
    if (!matches) return error.InvalidAudience;
    if (aud == .array and aud.array.items.len > 1 and !std.mem.eql(u8, opt(claims.value, "azp") orelse "", client)) return error.InvalidAudience;
    if (claims.value.object.get("nbf")) |v| {
        if (v != .integer or v.integer > std.time.timestamp() + 30) return error.InvalidIdToken;
    }
    if (try number(claims.value, "exp") <= std.time.timestamp()) return error.ExpiredIdToken;
    if (nonce) |expected| {
        if (!std.mem.eql(u8, try str(claims.value, "nonce"), expected)) return error.InvalidNonce;
    }
    const sub = try str(claims.value, "sub");
    if (sub.len == 0) return error.InvalidAccount;
    if (subject) |expected| {
        if (!std.mem.eql(u8, sub, expected)) return error.AccountMismatch;
    }
    return claims;
}
fn hasScope(scope: []const u8) bool {
    var words = std.mem.tokenizeScalar(u8, scope, ' ');
    while (words.next()) |word| {
        if (std.mem.eql(u8, word, "chatgpt.tokens.use.direct")) return true;
    }
    return false;
}
fn persist(a: A, dir: []const u8, response: Json, client: []const u8, host: []const u8, claims: Json, previous: ?Json) !void {
    const scope = opt(response, "scope") orelse if (previous) |v| try str(v, "scope") else return error.MissingGrantedScope;
    if (!hasScope(scope)) return error.ChatGPTPlanPermissionMissing;
    const id = opt(response, "id_token") orelse if (previous) |v| try str(v, "id_token") else return error.InvalidAuthResponse;
    const refresh = opt(response, "refresh_token") orelse if (previous) |v| try str(v, "refresh_token") else return error.InvalidAuthResponse;
    if (!std.ascii.eqlIgnoreCase(try str(response, "token_type"), "Bearer")) return error.InvalidAuthResponse;
    const ttl = try number(response, "expires_in");
    if (ttl <= 0 or ttl > 365 * 86400) return error.InvalidAuthResponse;
    const record = .{ .client_id = client, .ext_agent_host_id = host, .subject = try str(claims, "sub"), .email = opt(claims, "email") orelse "", .id_token = id, .access_token = try str(response, "access_token"), .refresh_token = refresh, .scope = scope, .expires_at = std.time.timestamp() + ttl };
    const bytes = try std.json.Stringify.valueAlloc(a, record, .{});
    defer a.free(bytes);
    try save(a, dir, "chatgpt.json", bytes);
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

pub fn login(a: A, dir: []const u8, app_name: []const u8) !void {
    const lock = try acquire(a, dir);
    defer lock.close();
    const saved_host = read(a, dir, "host-id") catch |err| blk: {
        if (err != error.FileNotFound) return err;
        break :blk null;
    };
    defer if (saved_host) |value| a.free(value);
    const host = if (saved_host) |value| if (!isLegacyHostId(value)) try a.dupe(u8, value) else blk: {
        const replacement = try newHostId(a);
        try save(a, dir, "host-id", replacement);
        break :blk replacement;
    } else blk: {
        const value = try newHostId(a);
        try save(a, dir, "host-id", value);
        break :blk value;
    };
    defer a.free(host);
    const oldbytes = read(a, dir, "chatgpt.json") catch |err| blk: {
        if (err != error.FileNotFound) return err;
        break :blk read(a, dir, "chatgpt-registration.json") catch |mapping_err| {
            if (mapping_err != error.FileNotFound) return mapping_err;
            break :blk null;
        };
    };
    defer if (oldbytes) |v| a.free(v);
    var old: ?std.json.Parsed(Json) = if (oldbytes) |v| try parse(a, v) else null;
    defer if (old) |*v| v.deinit();
    const client = if (old) |v| try str(v.value, "client_id") else "dynamic_agent_client";
    const state = try random(a);
    defer a.free(state);
    const nonce = try random(a);
    defer a.free(nonce);
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
    var fields: std.ArrayList([2][]const u8) = .empty;
    defer fields.deinit(a);
    try fields.appendSlice(a, &.{ .{ "client_id", client }, .{ "ext_agent_host_id", host }, .{ "response_type", "code" }, .{ "redirect_uri", redirect }, .{ "scope", requested_scope }, .{ "resource", resource }, .{ "state", state }, .{ "nonce", nonce }, .{ "code_challenge_method", "S256" }, .{ "code_challenge", &challenge } });
    if (old) |v| {
        if (opt(v.value, "email")) |email| try fields.append(a, .{ "login_hint", email });
    } else try fields.append(a, .{ "agent_name_hint", app_name });
    const params = try form(a, fields.items);
    defer a.free(params);
    const url = try std.fmt.allocPrint(a, issuer ++ "/api/accounts/authorize?{s}", .{params});
    defer a.free(url);
    std.debug.print("Continue with ChatGPT\nOpen this URL if your browser does not launch:\n{s}\n", .{url});
    platform.openUrl(a, url) catch {};
    const deadline = std.time.milliTimestamp() + 300000;
    while (std.time.milliTimestamp() < deadline) {
        if (terminal.cancelled()) return error.InputClosed;
        if (!try platform.socketReadable(server.stream.handle, @intCast(@min(100, @max(1, deadline - std.time.milliTimestamp()))))) continue;
        const conn = try server.accept();
        defer conn.stream.close();
        var buf: [16384]u8 = undefined;
        var nread: usize = 0;
        const request_deadline = @min(deadline, std.time.milliTimestamp() + 2000);
        while (nread < buf.len and std.mem.indexOfScalar(u8, buf[0..nread], '\n') == null) {
            const remaining = request_deadline - std.time.milliTimestamp();
            if (remaining <= 0) break;
            if (!try platform.socketReadable(conn.stream.handle, @intCast(remaining))) break;
            const count = try conn.stream.read(buf[nread..]);
            if (count == 0) break;
            nread += count;
        }
        if (std.mem.indexOfScalar(u8, buf[0..nread], '\n') == null) continue;
        const request = buf[0..nread];
        const start = "GET /auth/callback?";
        if (!std.mem.startsWith(u8, request, start)) {
            try conn.stream.writeAll("HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, request, start.len, ' ') orelse return error.InvalidCallback;
        const q = request[start.len..end];
        const gotstate = try query(a, q, "state") orelse return error.InvalidCallback;
        defer a.free(gotstate);
        if (!std.mem.eql(u8, gotstate, state)) {
            try conn.stream.writeAll("HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
            continue;
        }
        const denial = try query(a, q, "error");
        defer if (denial) |v| a.free(v);
        if (denial != null) {
            try conn.stream.writeAll("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Type: text/plain\r\nContent-Length: 51\r\n\r\nSign-in cancelled. You can return to the terminal.\n");
            return error.AuthorizationDenied;
        }
        const code = try query(a, q, "code") orelse return error.InvalidCallback;
        defer a.free(code);
        const issued = try query(a, q, "client_id");
        defer if (issued) |v| a.free(v);
        const actual = issued orelse if (old != null) client else return error.RegistrationIncomplete;
        if (std.mem.eql(u8, actual, "dynamic_agent_client") or actual.len == 0) return error.RegistrationIncomplete;
        if (old != null and !std.mem.eql(u8, client, actual)) return error.ClientMismatch;
        try conn.stream.writeAll("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Type: text/plain\r\nContent-Length: 46\r\n\r\nReturn to your terminal to finish signing in.\n");
        const body = try form(a, &.{ .{ "grant_type", "authorization_code" }, .{ "client_id", actual }, .{ "code", code }, .{ "code_verifier", verifier }, .{ "redirect_uri", redirect }, .{ "resource", resource } });
        defer a.free(body);
        const response = try http(a, issuer ++ "/api/accounts/oauth/token", body);
        defer a.free(response);
        var tokens = try parse(a, response);
        defer tokens.deinit();
        var claims = try verify(a, dir, try str(tokens.value, "id_token"), actual, nonce, if (old) |v| try str(v.value, "subject") else null);
        defer claims.deinit();
        try persist(a, dir, tokens.value, actual, host, claims.value, null);
        std.debug.print("ChatGPT connected. Use the model command to select ChatGPT and a model.\n", .{});
        return;
    }
    return error.SignInTimedOut;
}
pub fn token(a: A, dir: []const u8) ![]const u8 {
    const lock = try acquire(a, dir);
    defer lock.close();
    const bytes = read(a, dir, "chatgpt.json") catch |err| {
        if (err == error.FileNotFound) return error.ChatGPTSignInRequired;
        return err;
    };
    defer a.free(bytes);
    var old = try parse(a, bytes);
    defer old.deinit();
    if (!hasScope(try str(old.value, "scope"))) return error.ChatGPTPlanPermissionMissing;
    if (try number(old.value, "expires_at") > std.time.timestamp() + 60) return a.dupe(u8, try str(old.value, "access_token"));
    const client = try str(old.value, "client_id");
    const body = try form(a, &.{ .{ "grant_type", "refresh_token" }, .{ "client_id", client }, .{ "refresh_token", try str(old.value, "refresh_token") }, .{ "resource", resource } });
    defer a.free(body);
    const response = http(a, issuer ++ "/api/accounts/oauth/token", body) catch |err| {
        if (err == error.AuthDependencyMissing) return err;
        return error.ChatGPTRefreshFailed;
    };
    defer a.free(response);
    var fresh = try parse(a, response);
    defer fresh.deinit();
    var claims: ?std.json.Parsed(Json) = if (opt(fresh.value, "id_token")) |jwt| try verify(a, dir, jwt, client, null, try str(old.value, "subject")) else null;
    defer if (claims) |*v| v.deinit();
    var fallback = std.json.ObjectMap.init(a);
    defer fallback.deinit();
    try fallback.put("sub", .{ .string = try str(old.value, "subject") });
    try fallback.put("email", .{ .string = opt(old.value, "email") orelse "" });
    try persist(a, dir, fresh.value, client, try str(old.value, "ext_agent_host_id"), if (claims) |v| v.value else .{ .object = fallback }, old.value);
    return a.dupe(u8, try str(fresh.value, "access_token"));
}
pub fn logout(a: A, dir: []const u8) !void {
    const lock = try acquire(a, dir);
    defer lock.close();
    const bytes = read(a, dir, "chatgpt.json") catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer a.free(bytes);
    var record = try parse(a, bytes);
    defer record.deinit();
    const mapping = .{ .client_id = try str(record.value, "client_id"), .subject = try str(record.value, "subject"), .email = opt(record.value, "email") orelse "" };
    const mapping_bytes = try std.json.Stringify.valueAlloc(a, mapping, .{});
    defer a.free(mapping_bytes);
    try save(a, dir, "chatgpt-registration.json", mapping_bytes);
    const body = try form(a, &.{ .{ "token", try str(record.value, "refresh_token") }, .{ "token_type_hint", "refresh_token" }, .{ "client_id", mapping.client_id } });
    defer a.free(body);
    const revoked = http(a, issuer ++ "/api/accounts/oauth/revoke", body) catch null;
    if (revoked) |v| a.free(v) else std.debug.print("Remote revocation was not confirmed. Disconnect the app in ChatGPT Settings if needed.\n", .{});
    const p = try path(a, dir, "chatgpt.json");
    defer a.free(p);
    std.fs.cwd().deleteFile(p) catch |err| {
        if (err != error.FileNotFound) return err;
    };
}
