//! Optional, explicit whole-document sync. No calls from ordinary task operations.
const std = @import("std");
const platform = @import("platform.zig");
const A = std.mem.Allocator;
const max_document = 1024 * 1024;
const Credentials = struct { endpoint: []const u8, token: []const u8 };
const State = struct { identity: []const u8, revision: i64, base_hash: []const u8 };
const Document = struct { revision: i64, content: []const u8 };
const Response = struct { code: u16, body: []const u8 };
pub const ThemePreferences = struct {
    account_id: []const u8,
    endpoint_hash: []const u8,
    token_hash: []const u8,
    accent: ?[]const u8,
    revision: i64,
};
pub const ThemeCredential = struct { endpoint: []const u8, token_hash: []const u8 };
pub const LibraryCallbacks = struct {
    selected: *const fn (A, []const u8) anyerror!?[]const u8,
    select: *const fn (A, []const u8, []const u8) anyerror!void,
};
var library_credentials: ?Credentials = null;
fn libraryContext(a: A, config: []const u8) !Credentials {
    const pinned = library_credentials orelse return error.LibraryAdapterMissing;
    const current = try credentials(a, config);
    if (!std.mem.eql(u8, pinned.endpoint, current.endpoint) or !std.mem.eql(u8, pinned.token, current.token)) return error.LibraryAccountChanged;
    return pinned;
}
fn libraryRequest(a: A, config: []const u8, method: []const u8, route: []const u8, body: ?[]const u8) !@import("library_sync.zig").Response {
    const response = try http(a, config, try libraryContext(a, config), method, route, body);
    _ = try libraryContext(a, config);
    return .{ .code = response.code, .body = response.body };
}
fn libraryIdentity(a: A, config: []const u8) ![]const u8 {
    const c = try libraryContext(a, config);
    return hash(a, try std.fmt.allocPrint(a, "{s}\n{s}", .{ c.endpoint, c.token }));
}
pub fn runLibrary(a: A, args: []const []const u8, config: []const u8, root: []const u8, callbacks: LibraryCallbacks) !void {
    const previous = library_credentials;
    const offline_auto = args.len > 0 and std.mem.eql(u8, args[0], "auto") and (args.len == 1 or std.mem.eql(u8, args[1], "status") or std.mem.eql(u8, args[1], "disable"));
    library_credentials = if (offline_auto) null else try credentials(a, config);
    defer library_credentials = previous;
    return @import("library_sync.zig").run(a, args, config, root, .{ .request = libraryRequest, .identity = libraryIdentity, .selected = callbacks.selected, .select = callbacks.select });
}
var interrupted = std.atomic.Value(bool).init(false);
fn signal(_: c_int) callconv(.c) void {
    @import("terminal.zig").cancelSession();
    interrupted.store(true, .seq_cst);
}

fn output(text: []const u8) !void {
    try std.fs.File.stdout().writeAll(text);
}
fn path(a: A, folder: []const u8, name: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ folder, name });
}
fn read(a: A, p: []const u8) ![]const u8 {
    return std.fs.cwd().readFileAlloc(a, p, max_document);
}
fn hash(a: A, bytes: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.allocPrint(a, "{x}", .{digest});
}
fn randomPath(a: A, p: []const u8) ![]const u8 {
    var nonce: [8]u8 = undefined;
    std.crypto.random.bytes(&nonce);
    return std.fmt.allocPrint(a, "{s}-{x}", .{ p, std.mem.readInt(u64, &nonce, .little) });
}
fn atomic(a: A, p: []const u8, bytes: []const u8) !void {
    const tmp = try randomPath(a, p);
    defer a.free(tmp);
    defer std.fs.cwd().deleteFile(tmp) catch {};
    const file = try std.fs.cwd().createFile(tmp, .{ .exclusive = true, .mode = 0o600 });
    defer file.close();
    try platform.privateFile(a, tmp);
    try file.writeAll(bytes);
    try file.sync();
    try std.fs.cwd().rename(tmp, p);
}
fn save(a: A, folder: []const u8, name: []const u8, item: anytype) !void {
    const p = try path(a, folder, name);
    defer a.free(p);
    const bytes = try std.json.Stringify.valueAlloc(a, item, .{});
    defer a.free(bytes);
    try atomic(a, p, bytes);
}
fn load(comptime T: type, a: A, folder: []const u8, name: []const u8) !T {
    const p = try path(a, folder, name);
    defer a.free(p);
    const bytes = try read(a, p);
    defer a.free(bytes);
    return (try std.json.parseFromSlice(T, a, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true })).value;
}
fn endpointCheck(url: []const u8) !void {
    for (url) |ch| if (ch <= 32 or ch == 127) return error.InvalidSyncEndpoint;
    const uri = std.Uri.parse(url) catch return error.InvalidSyncEndpoint;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidSyncEndpoint;
    const host = if (uri.host) |h| h.percent_encoded else return error.InvalidSyncEndpoint;
    const local = std.mem.eql(u8, host, "localhost") or std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "[::1]");
    if (!std.mem.eql(u8, uri.scheme, "https") and !(local and std.mem.eql(u8, uri.scheme, "http"))) return error.SyncEndpointNeedsHTTPS;
    if (uri.path.percent_encoded.len > 1) return error.SyncEndpointMustBeOrigin;
}
pub var prompt: ?*const fn (a: A, label: []const u8) anyerror![]const u8 = null;
fn input(a: A, label: []const u8) ![]const u8 {
    if (prompt) |read_prompt| return read_prompt(a, label);
    var editor = @import("terminal.zig").Editor.init(std.heap.c_allocator);
    defer editor.deinit();
    return editor.read(a, label, "Enter to continue · Ctrl+C to cancel", false);
}
fn cleanOutput(a: A, text: []const u8) !void {
    const clean = try @import("terminal.zig").clean(a, text, false);
    defer a.free(clean);
    try output(clean);
}
fn tokenCheck(token: []const u8) !void {
    if (token.len < 8 or token.len > 4096) return error.InvalidSyncToken;
    for (token) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_' and ch != '.') return error.InvalidSyncToken;
}
fn responseCheck(r: Response) !void {
    switch (r.code) {
        200, 201, 202 => {},
        401 => return error.SyncSignInExpired,
        402 => return error.SyncSubscriptionRequired,
        429 => return error.SyncRateLimited,
        503 => return error.SyncUnavailable,
        else => return error.SyncRequestFailed,
    }
}
fn value(a: A, r: Response) !std.json.Value {
    try responseCheck(r);
    return (std.json.parseFromSlice(std.json.Value, a, r.body, .{ .allocate = .alloc_always }) catch return error.InvalidSyncResponse).value;
}
fn success(a: A, r: Response) !std.json.Value {
    if (r.code == 202) return error.InvalidSyncResponse;
    return value(a, r);
}
fn string(v: std.json.Value, key: []const u8) ![]const u8 {
    const item = if (v == .object) v.object.get(key) else null;
    if (item) |x| if (x == .string) return x.string;
    return error.InvalidSyncResponse;
}
fn integer(v: std.json.Value, key: []const u8) !i64 {
    const item = if (v == .object) v.object.get(key) else null;
    if (item) |x| if (x == .integer) return x.integer;
    return error.InvalidSyncResponse;
}
fn emailCheck(email: []const u8) !void {
    if (email.len < 3 or email.len > 254) return error.InvalidEmail;
    const at = std.mem.indexOfScalar(u8, email, '@') orelse return error.InvalidEmail;
    if (at == 0 or at > 64 or at + 1 >= email.len or std.mem.indexOfScalar(u8, email[at + 1 ..], '@') != null) return error.InvalidEmail;
    if (email[0] == '.' or email[at - 1] == '.' or std.mem.indexOf(u8, email, "..") != null) return error.InvalidEmail;
    const dot = std.mem.lastIndexOfScalar(u8, email[at + 1 ..], '.') orelse return error.InvalidEmail;
    const suffix = email[at + 1 + dot + 1 ..];
    if (suffix.len < 2 or suffix.len > 63) return error.InvalidEmail;
    for (suffix) |ch| if (!std.ascii.isAlphabetic(ch)) return error.InvalidEmail;
    for (email) |ch| if (ch <= 32 or ch >= 127) return error.InvalidEmail;
}
fn randomProof(a: A) ![]const u8 {
    var random: [32]u8 = undefined;
    std.crypto.random.bytes(&random);
    return std.fmt.allocPrint(a, "{x}", .{random});
}
fn challenge(a: A, verifier: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    const result = try a.alloc(u8, 43);
    return std.base64.url_safe_no_pad.Encoder.encode(result, &digest);
}
fn login(a: A, args: []const []const u8, config_dir: []const u8) !void {
    var endpoint: []const u8 = "https://sync.doin.sh";
    var email: ?[]const u8 = null;
    var name: []const u8 = "This computer";
    var index: usize = 1;
    while (index < args.len) : (index += 2) {
        if (index + 1 >= args.len) return error.InvalidSyncArguments;
        if (std.mem.eql(u8, args[index], "--endpoint")) endpoint = args[index + 1] else if (std.mem.eql(u8, args[index], "--email")) email = args[index + 1] else if (std.mem.eql(u8, args[index], "--name")) name = args[index + 1] else return error.InvalidSyncArguments;
    }
    try endpointCheck(endpoint);
    const address = std.mem.trim(u8, email orelse try input(a, "Email"), " \r\n\t");
    try emailCheck(address);
    if (std.mem.trim(u8, name, " ").len == 0 or name.len > 80) return error.InvalidDeviceName;
    for (name) |ch| if (ch < 32 or ch == 127) return error.InvalidDeviceName;
    try std.fs.cwd().makePath(config_dir);
    const verifier = try randomProof(a);
    const c: Credentials = .{ .endpoint = std.mem.trimEnd(u8, endpoint, "/"), .token = "" };
    const body = try std.json.Stringify.valueAlloc(a, .{ .email = address, .name = name, .code_challenge = try challenge(a, verifier) }, .{});
    const start = try success(a, try http(a, config_dir, c, "POST", "/v1/auth/start", body));
    const request_id = try string(start, "request_id");
    const code = try string(start, "confirmation_code");
    if (request_id.len == 0 or request_id.len > 256 or code.len != 6) return error.InvalidSyncResponse;
    for (code) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidSyncResponse;
    const expires = try integer(start, "expires_in");
    const interval = try integer(start, "interval");
    if (expires < 1 or expires > 600 or interval < 1 or interval > 30) return error.InvalidSyncResponse;
    try output("Check your email. Open its verification link and enter this confirmation code: ");
    try output(code);
    try output("\nWaiting for verification · Ctrl+C cancels. Nothing uploaded.\n");
    interrupted.store(false, .seq_cst);
    const guard = try platform.SignalGuard.install(signal);
    defer guard.restore();
    const proof = try std.json.Stringify.valueAlloc(a, .{ .request_id = request_id, .code_verifier = verifier }, .{});
    var timer = try std.time.Timer.start();
    while (timer.read() < @as(u64, @intCast(expires)) * std.time.ns_per_s) {
        if (interrupted.load(.seq_cst)) return error.InputClosed;
        const response = http(a, config_dir, c, "POST", "/v1/auth/poll", proof) catch |err| {
            if (err != error.SyncOfflineOrAmbiguous) return err;
            // Poll claims are idempotent for this same proof: recover lost replies.
            if (interrupted.load(.seq_cst)) return error.InputClosed;
            std.Thread.sleep(@as(u64, @intCast(interval)) * std.time.ns_per_s);
            continue;
        };
        const poll = try value(a, response);
        if (interrupted.load(.seq_cst)) return error.InputClosed;
        if (response.code == 200) {
            const returned_account = if (poll == .object) poll.object.get("account") else null;
            const who = returned_account orelse return error.InvalidSyncResponse;
            if (!std.ascii.eqlIgnoreCase(try string(who, "email"), address) or (try string(who, "id")).len == 0) return error.SyncAccountMismatch;
            const token = try string(poll, "token");
            try tokenCheck(token);
            const expiry = try integer(poll, "expires_at");
            if (expiry <= std.time.timestamp()) return error.SyncSignInExpired;
            try save(a, config_dir, "sync.json", Credentials{ .endpoint = c.endpoint, .token = token });
            return output("Signed in. Account and sync stay in this terminal. Nothing uploaded.\n");
        }
        if (!std.mem.eql(u8, try string(poll, "status"), "pending")) return error.InvalidSyncResponse;
        std.Thread.sleep(@as(u64, @intCast(interval)) * std.time.ns_per_s);
    }
    return error.SyncLoginTimedOut;
}
fn yes(a: A, args: []const []const u8, label: []const u8) !bool {
    for (args) |arg| if (std.mem.eql(u8, arg, "--yes")) return true;
    const answer = std.mem.trim(u8, try input(a, label), " \r\n\t");
    return std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes");
}
fn account(a: A, config_dir: []const u8, c: Credentials) !void {
    const who = try success(a, try http(a, config_dir, c, "GET", "/v1/account", null));
    const billing = try success(a, try http(a, config_dir, c, "GET", "/v1/billing", null));
    const email = try string(who, "email");
    const status = try string(billing, "status");
    try output("Account: ");
    try cleanOutput(a, email);
    try output("\nSubscription: ");
    try cleanOutput(a, status);
    if (billing == .object) if (billing.object.get("cancel_at_period_end")) |cancel| if (cancel == .bool and cancel.bool) try output(" (renewal canceled)");
    const interval = optionalString(billing, "interval");
    if (interval) |value_| {
        try output("\nPlan interval: ");
        try cleanOutput(a, value_);
    }
    if (optionalInteger(billing, "amount")) |amount| {
        if (amount < 0 or !std.mem.eql(u8, try string(billing, "currency"), "usd")) return error.InvalidSyncResponse;
        const cents: u64 = @intCast(amount);
        try output("\nAmount: ");
        try output(try std.fmt.allocPrint(a, "${d}.{d:0>2} USD", .{ @divTrunc(cents, 100), @mod(cents, 100) }));
    }
    if (optionalBool(billing, "pending_update") orelse false) {
        try output("\nPayment pending");
        if (optionalString(billing, "pending_interval")) |pending| {
            try output(" for ");
            try cleanOutput(a, pending);
        }
        try output(" interval. Use account portal to update payment details.\n");
    } else try output("\n");
    try output("Use account change month|year, account portal, sync devices, or sync cancel here. No Markdown uploaded.\n");
}
fn optionalString(v: std.json.Value, key: []const u8) ?[]const u8 {
    const item = if (v == .object) v.object.get(key) else null;
    if (item) |value_| if (value_ == .string) return value_.string;
    return null;
}
fn optionalInteger(v: std.json.Value, key: []const u8) ?i64 {
    const item = if (v == .object) v.object.get(key) else null;
    if (item) |value_| if (value_ == .integer) return value_.integer;
    return null;
}
fn optionalBool(v: std.json.Value, key: []const u8) ?bool {
    const item = if (v == .object) v.object.get(key) else null;
    if (item) |value_| if (value_ == .bool) return value_.bool;
    return null;
}
fn devices(a: A, config_dir: []const u8, c: Credentials) !std.json.Value {
    const result = try success(a, try http(a, config_dir, c, "GET", "/v1/devices", null));
    const rows = if (result == .object) result.object.get("devices") else null;
    if (rows) |items| if (items == .array and items.array.items.len <= 1000) return items;
    return error.InvalidSyncResponse;
}
fn payment(result: std.json.Value, allowed_host: []const u8) !void {
    const url = try string(result, "url");
    for (url) |ch| if (ch <= 32 or ch == 127) return error.InvalidCheckoutURL;
    const uri = std.Uri.parse(url) catch return error.InvalidCheckoutURL;
    const host = if (uri.host) |h| h.percent_encoded else return error.InvalidCheckoutURL;
    if (!std.mem.eql(u8, uri.scheme, "https") or !std.mem.eql(u8, host, allowed_host) or uri.user != null or uri.password != null or (uri.port != null and uri.port.? != 443)) return error.InvalidCheckoutURL;
    try output("Secure payment entry only. Open:\n");
    try output(url);
    try output("\nReturn here and run sync status when payment completes.\n");
}
fn stripePortal(result: std.json.Value) ![]const u8 {
    const url = try string(result, "url");
    for (url) |ch| if (ch <= 32 or ch == 127) return error.InvalidCheckoutURL;
    const uri = std.Uri.parse(url) catch return error.InvalidCheckoutURL;
    const host = if (uri.host) |h| h.percent_encoded else return error.InvalidCheckoutURL;
    if (!std.mem.eql(u8, uri.scheme, "https") or !std.mem.eql(u8, host, "billing.stripe.com") or uri.user != null or uri.password != null or (uri.port != null and uri.port.? != 443)) return error.InvalidCheckoutURL;
    return url;
}
fn validInterval(value_: []const u8) bool {
    return std.mem.eql(u8, value_, "month") or std.mem.eql(u8, value_, "year");
}
fn billingChange(a: A, config_dir: []const u8, c: Credentials, interval: []const u8) !void {
    if (!validInterval(interval)) return error.InvalidSyncArguments;
    const current = try success(a, try http(a, config_dir, c, "GET", "/v1/billing", null));
    const pending = optionalBool(current, "pending_update") orelse return error.InvalidSyncResponse;
    if (pending) return error.SyncPaymentPending;
    if (optionalBool(current, "cancel_at_period_end") orelse return error.InvalidSyncResponse) return error.SyncRenewalCanceled;
    const current_interval = optionalString(current, "interval") orelse return error.InvalidSyncResponse;
    if (!validInterval(current_interval)) return error.InvalidSyncResponse;
    if (std.mem.eql(u8, current_interval, interval)) {
        try output(try std.fmt.allocPrint(a, "Already on the {s} interval. Subscription unchanged.\n", .{interval}));
        return;
    }
    const preview = try success(a, try http(a, config_dir, c, "POST", "/v1/billing/change", try std.json.Stringify.valueAlloc(a, .{ .interval = interval }, .{})));
    if (optionalBool(preview, "confirmation_required") != true) {
        const unchanged = optionalBool(preview, "changed") == false and optionalBool(preview, "payment_pending") == false;
        if (unchanged and std.mem.eql(u8, try string(preview, "interval"), interval) and optionalString(preview, "pending_interval") == null) {
            try output(try std.fmt.allocPrint(a, "Already on the {s} interval. Subscription unchanged.\n", .{interval}));
            return;
        }
        return error.InvalidSyncResponse;
    }
    const quote_id = try string(preview, "quote_id");
    const amount = try integer(preview, "amount_due");
    if (quote_id.len == 0 or quote_id.len > 256 or amount == std.math.minInt(i64) or !std.mem.eql(u8, try string(preview, "interval"), interval) or !std.mem.eql(u8, try string(preview, "currency"), "usd")) return error.InvalidSyncResponse;
    const absolute_amount: u64 = @intCast(if (amount < 0) -amount else amount);
    const detail = if (amount < 0) "credit" else "amount due now";
    try output(try std.fmt.allocPrint(a, "Change subscription to {s}; {s} ${d}.{d:0>2} USD.\n", .{ interval, detail, @divTrunc(absolute_amount, 100), @mod(absolute_amount, 100) }));
    if (!try yes(a, &.{}, "Confirm this subscription change and displayed charge? [y/N]")) return output("Subscription unchanged.\n");
    const body = try std.json.Stringify.valueAlloc(a, .{ .interval = interval, .quote_id = quote_id, .confirm_amount = amount }, .{});
    const result = try success(a, try http(a, config_dir, c, "POST", "/v1/billing/change", body));
    if (optionalBool(result, "confirmation_required") == true) {
        const replacement_quote = try string(result, "quote_id");
        const replacement_amount = try integer(result, "amount_due");
        if (replacement_quote.len == 0 or replacement_quote.len > 256 or replacement_amount == std.math.minInt(i64) or !std.mem.eql(u8, try string(result, "interval"), interval) or !std.mem.eql(u8, try string(result, "currency"), "usd")) return error.InvalidSyncResponse;
        return output("Charge changed. No subscription change made. Run account change again to review a fresh quote.\n");
    }
    const payment_pending = optionalBool(result, "payment_pending") orelse return error.InvalidSyncResponse;
    if (payment_pending) {
        if (optionalBool(result, "changed") != false or !validInterval(try string(result, "interval")) or !std.mem.eql(u8, try string(result, "pending_interval"), interval)) return error.InvalidSyncResponse;
        try output("Plan change is awaiting payment. Use account portal to update payment details, then account status to check it.\n");
        return;
    }
    if (optionalBool(result, "changed") != true or !std.mem.eql(u8, try string(result, "interval"), interval)) return error.InvalidSyncResponse;
    try output("Subscription interval changed.\n");
}
fn managed(a: A, args: []const []const u8, config_dir: []const u8, c: Credentials) !bool {
    const cmd = args[0];
    if (std.mem.eql(u8, cmd, "devices")) {
        if (args.len != 1) return error.InvalidSyncArguments;
        const rows = try devices(a, config_dir, c);
        for (rows.array.items) |item| {
            try output("  ");
            try cleanOutput(a, try string(item, "id"));
            try output("  ");
            try cleanOutput(a, try string(item, "name"));
            if (item == .object) if (item.object.get("current")) |current| if (current == .bool and current.bool) try output(" (this computer)");
            try output("\n");
        }
        return true;
    }
    if (std.mem.eql(u8, cmd, "revoke")) {
        if (args.len > 3 or (args.len == 3 and !std.mem.eql(u8, args[2], "--yes"))) return error.InvalidSyncArguments;
        const id = if (args.len > 1 and !std.mem.eql(u8, args[1], "--yes")) args[1] else try input(a, "Device ID to revoke");
        if (id.len == 0 or id.len > 256) return error.InvalidSyncArguments;
        if (!try yes(a, args, "Revoke this device? [y/N]")) {
            try output("Device kept.\n");
            return true;
        }
        const rows = try devices(a, config_dir, c);
        var current = false;
        var found = false;
        for (rows.array.items) |item| if (std.mem.eql(u8, try string(item, "id"), id)) {
            found = true;
            if (item == .object) if (item.object.get("current")) |flag| {
                current = flag == .bool and flag.bool;
            };
        };
        if (!found) return error.SyncDeviceNotFound;
        _ = try success(a, try http(a, config_dir, c, "POST", "/v1/devices/revoke", try std.json.Stringify.valueAlloc(a, .{ .id = id }, .{})));
        if (current) try std.fs.cwd().deleteFile(try path(a, config_dir, "sync.json"));
        try output("Device revoked. Local Markdown kept.\n");
        return true;
    }
    if (std.mem.eql(u8, cmd, "billing")) {
        if (args.len > 2) return error.InvalidSyncArguments;
        const interval = if (args.len == 2) args[1] else "month";
        if (!std.mem.eql(u8, interval, "month") and !std.mem.eql(u8, interval, "year")) return error.InvalidSyncArguments;
        const result = try success(a, try http(a, config_dir, c, "POST", "/v1/checkout", try std.json.Stringify.valueAlloc(a, .{ .interval = interval }, .{})));
        try payment(result, "checkout.stripe.com");
        return true;
    }
    if (std.mem.eql(u8, cmd, "change")) {
        if (args.len != 2) return error.InvalidSyncArguments;
        try billingChange(a, config_dir, c, args[1]);
        return true;
    }
    if (std.mem.eql(u8, cmd, "portal")) {
        if (args.len != 1) return error.InvalidSyncArguments;
        if (!try yes(a, args, "Open the Stripe billing portal to manage payment details? [y/N]")) {
            try output("Billing portal kept closed.\n");
            return true;
        }
        const result = try success(a, try http(a, config_dir, c, "POST", "/v1/billing/portal", "{}"));
        const url = try stripePortal(result);
        try output("Opening Stripe billing portal.\n");
        @import("platform.zig").openUrl(a, url) catch {
            try output("Browser could not open. Use this secure Stripe link:\n");
            try output(url);
            try output("\n");
        };
        return true;
    }
    if (std.mem.eql(u8, cmd, "cancel")) {
        if (args.len > 2 or (args.len == 2 and !std.mem.eql(u8, args[1], "--yes"))) return error.InvalidSyncArguments;
        if (!try yes(a, args, "Cancel subscription renewal? [y/N]")) {
            try output("Subscription kept.\n");
            return true;
        }
        _ = try success(a, try http(a, config_dir, c, "POST", "/v1/billing/cancel", "{}"));
        try output("Renewal canceled. Access continues through the paid period.\n");
        return true;
    }
    if (std.mem.eql(u8, cmd, "resume")) {
        if (args.len > 2 or (args.len == 2 and !std.mem.eql(u8, args[1], "--yes"))) return error.InvalidSyncArguments;
        if (!try yes(a, args, "Resume subscription renewal? [y/N]")) {
            try output("Renewal unchanged.\n");
            return true;
        }
        const result = try success(a, try http(a, config_dir, c, "POST", "/v1/billing/resume", "{}"));
        const canceled = if (result == .object) result.object.get("cancel_at_period_end") else null;
        if (canceled == null or canceled.? != .bool or canceled.?.bool) return error.InvalidSyncResponse;
        try output("Subscription renewal resumed.\n");
        return true;
    }
    if (std.mem.eql(u8, cmd, "recover")) {
        if (args.len != 1) return error.InvalidSyncArguments;
        const result = try success(a, try http(a, config_dir, c, "POST", "/v1/billing/recover", "{}"));
        try payment(result, "invoice.stripe.com");
        return true;
    }
    if (std.mem.eql(u8, cmd, "export")) {
        if (args.len != 1) return error.InvalidSyncArguments;
        const remote = try document(a, try http(a, config_dir, c, "GET", "/v1/export", null));
        if (std.fs.File.stdout().isTty()) {
            const clean = try @import("terminal.zig").clean(a, remote.content, true);
            defer a.free(clean);
            try output(clean);
        } else try output(remote.content);
        return true;
    }
    if (std.mem.eql(u8, cmd, "delete")) {
        if (args.len != 1) return error.InvalidSyncArguments;
        const answer = try input(a, "Permanently delete cloud account and cancel subscription? Type delete my account");
        if (!std.mem.eql(u8, std.mem.trim(u8, answer, " \r\n\t"), "delete my account")) {
            try output("Account kept.\n");
            return true;
        }
        const result = try success(a, try http(a, config_dir, c, "DELETE", "/v1/account", "{\"confirmation\":\"delete my account\"}"));
        const deleted = if (result == .object) result.object.get("deleted") else null;
        if (deleted == null or deleted.? != .bool or !deleted.?.bool) return error.InvalidSyncResponse;
        try std.fs.cwd().deleteFile(try path(a, config_dir, "sync.json"));
        try output("Cloud account deleted and subscription canceled. Local Markdown kept.\n");
        return true;
    }
    return false;
}
fn http(a: A, config_dir: []const u8, c: Credentials, method: []const u8, route: []const u8, body: ?[]const u8) !Response {
    return httpBudget(a, config_dir, c, method, route, body, null);
}
fn httpBudget(a: A, config_dir: []const u8, c: Credentials, method: []const u8, route: []const u8, body: ?[]const u8, deadline_ms: ?i64) !Response {
    const remaining = if (deadline_ms) |deadline| deadline - std.time.milliTimestamp() else 20000;
    if (remaining <= 0) return error.McpTimedOut;
    const budget = @min(remaining, 20000);
    const timeout = try std.fmt.allocPrint(a, "{d}.{d:0>3}", .{ @as(u64, @intCast(@divTrunc(budget, 1000))), @as(u64, @intCast(@mod(budget, 1000))) });
    defer a.free(timeout);
    try endpointCheck(c.endpoint);
    if (c.token.len > 0) try tokenCheck(c.token);
    const url = try std.fmt.allocPrint(a, "{s}{s}", .{ std.mem.trimEnd(u8, c.endpoint, "/"), route });
    defer a.free(url);
    const config = if (c.token.len > 0) try std.fmt.allocPrint(a, "header = \"Authorization: Bearer {s}\"\n", .{c.token}) else try a.dupe(u8, "");
    defer a.free(config);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(a);
    try argv.appendSlice(a, &.{ "curl", "--disable", "--silent", "--show-error", "--max-time", timeout, "--connect-timeout", "5", "--proto", "=https,http", "--config", "-", "--request", method, "--write-out", "\n%{http_code}", "--header", "Content-Type: application/json", url });
    var temp: ?[]const u8 = null;
    defer if (temp) |p| {
        std.fs.cwd().deleteFile(p) catch {};
        a.free(p);
    };
    if (body) |bytes| {
        temp = try randomPath(a, try path(a, config_dir, ".sync-request"));
        const f = try std.fs.cwd().createFile(temp.?, .{ .exclusive = true, .mode = 0o600 });
        {
            defer f.close();
            try platform.privateFile(a, temp.?);
            try f.writeAll(bytes);
        }
        try argv.appendSlice(a, &.{ "--data-binary", try std.fmt.allocPrint(a, "@{s}", .{temp.?}) });
    }
    if (@import("terminal.zig").cancelled()) return error.InputClosed;
    var child = std.process.Child.init(argv.items, a);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    var group = try platform.ChildGroup.spawn(&child);
    defer group.close();
    @import("terminal.zig").trackHttp(child.id);
    defer @import("terminal.zig").clearHttp();
    errdefer {
        group.terminate(&child);
        _ = child.kill() catch {};
    }
    try child.stdin.?.writeAll(config);
    child.stdin.?.close();
    child.stdin = null;
    var stdout: std.ArrayList(u8) = .empty;
    var stderr: std.ArrayList(u8) = .empty;
    defer stdout.deinit(a);
    defer stderr.deinit(a);
    try child.collectOutput(a, &stdout, &stderr, max_document * 8);
    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) {
        if (term == .Exited) try std.fs.File.stderr().writeAll(try std.fmt.allocPrint(a, "Sync HTTP helper exited {d}.\n", .{term.Exited}));
        return error.SyncOfflineOrAmbiguous;
    }
    const newline = std.mem.lastIndexOfScalar(u8, stdout.items, '\n') orelse return error.InvalidSyncResponse;
    return .{ .code = try std.fmt.parseInt(u16, stdout.items[newline + 1 ..], 10), .body = try a.dupe(u8, stdout.items[0..newline]) };
}
fn document(a: A, response: Response) !Document {
    switch (response.code) {
        200, 409 => {},
        401 => return error.SyncSignInExpired,
        402 => return error.SyncSubscriptionRequired,
        503 => return error.SyncUnavailable,
        else => return error.SyncRequestFailed,
    }
    const d = (std.json.parseFromSlice(Document, a, response.body, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch return error.InvalidSyncResponse).value;
    if (d.revision < 0 or d.revision > 9007199254740991 or d.content.len > max_document or !std.unicode.utf8ValidateSlice(d.content) or std.mem.indexOfScalar(u8, d.content, 0) != null) return error.InvalidSyncResponse;
    return d;
}
fn backup(a: A, storage: []const u8, prefix: []const u8, contents: []const u8) !void {
    const p = try randomPath(a, try path(a, storage, prefix));
    defer a.free(p);
    try atomic(a, p, contents);
}
fn credentials(a: A, config_dir: []const u8) !Credentials {
    return load(Credentials, a, config_dir, "sync.json") catch |err| switch (err) {
        error.FileNotFound => return error.SyncLoginRequired,
        else => return err,
    };
}
fn ensureThemeEndpoint(a: A, config_dir: []const u8, c: Credentials) !void {
    const selected = try configuredEndpoint(a, config_dir);
    const saved = std.mem.trimEnd(u8, c.endpoint, "/");
    if (!std.mem.eql(u8, saved, std.mem.trimEnd(u8, selected, "/"))) return error.SyncEndpointMismatch;
}

fn preferenceValue(a: A, response: Response) !std.json.Value {
    switch (response.code) {
        200 => {},
        401 => return error.SyncSignInExpired,
        402 => return error.SyncSubscriptionRequired,
        429 => return error.SyncRateLimited,
        503 => return error.SyncUnavailable,
        409 => {},
        else => return error.ThemePreferencesUnavailable,
    }
    return (std.json.parseFromSlice(std.json.Value, a, response.body, .{ .allocate = .alloc_always }) catch return error.InvalidSyncResponse).value;
}

fn preferenceFields(value_: std.json.Value) !struct { accent: ?[]const u8, revision: i64 } {
    const parsed_preferences = if (value_ == .object and value_.object.get("preferences") != null) value_.object.get("preferences").? else value_;
    if (parsed_preferences != .object) return error.InvalidSyncResponse;
    const revision_value = parsed_preferences.object.get("revision") orelse return error.InvalidSyncResponse;
    if (revision_value != .integer or revision_value.integer < 0 or revision_value.integer > 9007199254740991) return error.InvalidSyncResponse;
    const accent_value = parsed_preferences.object.get("accent") orelse return error.InvalidSyncResponse;
    var accent: ?[]const u8 = null;
    switch (accent_value) {
        .null => {},
        .string => |text| {
            if (text.len != 7 or text[0] != '#') return error.InvalidSyncResponse;
            for (text[1..]) |ch| if (!((ch >= '0' and ch <= '9') or (ch >= 'A' and ch <= 'F'))) return error.InvalidSyncResponse;
            accent = text;
        },
        else => return error.InvalidSyncResponse,
    }
    return .{ .accent = accent, .revision = revision_value.integer };
}

fn accountPreferencesUntil(a: A, config_dir: []const u8, c: Credentials, deadline: i64) !ThemePreferences {
    const identity = try preferenceValue(a, try httpBudget(a, config_dir, c, "GET", "/v1/account", null, deadline));
    const account_id = try string(identity, "id");
    if (account_id.len == 0 or account_id.len > 256) return error.InvalidSyncResponse;
    if (c.token.len == 0) return error.SyncLoginRequired;
    const response = try preferenceValue(a, try httpBudget(a, config_dir, c, "GET", "/v1/account/preferences", null, deadline));
    const fields = try preferenceFields(response);
    return .{ .account_id = account_id, .endpoint_hash = try hash(a, c.endpoint), .token_hash = try hash(a, c.token), .accent = fields.accent, .revision = fields.revision };
}

fn ensurePreferencesAccount(a: A, config_dir: []const u8, pinned: Credentials) !void {
    const current = try credentials(a, config_dir);
    if (!std.mem.eql(u8, current.endpoint, pinned.endpoint) or !std.mem.eql(u8, current.token, pinned.token)) return error.SyncAccountChanged;
}

pub fn getThemePreferences(a: A, config_dir: []const u8, budget_ms: i64) !ThemePreferences {
    if (budget_ms <= 0) return error.ThemePreferencesTimedOut;
    const c = try credentials(a, config_dir);
    try ensureThemeEndpoint(a, config_dir, c);
    const deadline = std.time.milliTimestamp() + budget_ms;
    const result = try accountPreferencesUntil(a, config_dir, c, deadline);
    try ensurePreferencesAccount(a, config_dir, c);
    return result;
}

pub fn themeCredential(a: A, config_dir: []const u8) !ThemeCredential {
    const c = try credentials(a, config_dir);
    try ensureThemeEndpoint(a, config_dir, c);
    try endpointCheck(c.endpoint);
    try tokenCheck(c.token);
    return .{ .endpoint = c.endpoint, .token_hash = try hash(a, c.token) };
}

pub fn setThemePreferences(a: A, config_dir: []const u8, accent_value: ?[]const u8, base_revision: ?i64, budget_ms: i64) !ThemePreferences {
    if (budget_ms <= 0) return error.ThemePreferencesTimedOut;
    if (accent_value) |text| {
        if (text.len != 7 or text[0] != '#') return error.InvalidThemeAccent;
        for (text[1..]) |ch| if (!((ch >= '0' and ch <= '9') or (ch >= 'A' and ch <= 'F'))) return error.InvalidThemeAccent;
    }
    const c = try credentials(a, config_dir);
    try ensureThemeEndpoint(a, config_dir, c);
    const deadline = std.time.milliTimestamp() + budget_ms;
    const identity = try preferenceValue(a, try httpBudget(a, config_dir, c, "GET", "/v1/account", null, deadline));
    const account_id = try string(identity, "id");
    if (account_id.len == 0 or account_id.len > 256) return error.InvalidSyncResponse;
    try ensurePreferencesAccount(a, config_dir, c);
    var revision = if (base_revision) |base_value| base_value else (try accountPreferencesUntil(a, config_dir, c, deadline)).revision;
    if (revision < 0 or revision > 9007199254740991) return error.InvalidSyncResponse;
    for (0..2) |attempt| {
        const body = try std.json.Stringify.valueAlloc(a, .{ .accent = accent_value, .revision = revision }, .{});
        const response = try httpBudget(a, config_dir, c, "PUT", "/v1/account/preferences", body, deadline);
        try ensurePreferencesAccount(a, config_dir, c);
        if (response.code == 409) {
            const conflict = try preferenceValue(a, response);
            const current = try preferenceFields(conflict);
            revision = current.revision;
            if (attempt == 1) return error.ThemePreferenceConflict;
            continue;
        }
        const saved_value = try preferenceValue(a, response);
        const saved = try preferenceFields(saved_value);
        if (saved.revision < revision or !std.mem.eql(u8, saved.accent orelse "", accent_value orelse "")) return error.InvalidSyncResponse;
        return .{ .account_id = account_id, .endpoint_hash = try hash(a, c.endpoint), .token_hash = try hash(a, c.token), .accent = saved.accent, .revision = saved.revision };
    }
    return error.ThemePreferenceConflict;
}

pub fn autoTick(a: A, config_dir: []const u8, storage: []const u8) !@import("sync_background.zig").Report {
    const c = try credentials(a, config_dir);
    const identity = try hash(a, try std.fmt.allocPrint(a, "{s}\n{s}", .{ c.endpoint, c.token }));
    var baseline: ?State = load(State, a, storage, ".doin-sync.json") catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (baseline) |b| {
        if (b.revision < 0 or b.revision >= 9007199254740991) return error.InvalidSyncState;
        if (!std.mem.eql(u8, b.identity, identity)) baseline = null;
    }
    const lock_path = try path(a, storage, ".tasks.lock");
    defer a.free(lock_path);
    const lock = try std.fs.cwd().createFile(lock_path, .{ .truncate = false, .mode = 0o600 });
    defer lock.close();
    if (!try platform.tryLockExclusive(lock)) return error.StorageBusy;
    const task_path = try path(a, storage, "tasks.md");
    defer a.free(task_path);
    const before = try read(a, task_path);
    defer a.free(before);
    if (!std.unicode.utf8ValidateSlice(before) or std.mem.indexOfScalar(u8, before, 0) != null) return error.InvalidSyncDocument;
    const before_hash = try hash(a, before);
    const fetched = try http(a, config_dir, c, "GET", "/v1/document", null);
    const remote = try document(a, fetched);
    if (fetched.code != 200) return error.SyncRequestFailed;
    if (!std.mem.eql(u8, before, try read(a, task_path))) return error.DocumentChanged;
    if (std.mem.eql(u8, before, remote.content)) {
        try save(a, storage, ".doin-sync.json", State{ .identity = identity, .revision = remote.revision, .base_hash = before_hash });
        return .{ .state = "unchanged" };
    }
    const b = baseline orelse {
        try backup(a, storage, ".doin-sync-conflict", remote.content);
        return .{ .state = "conflict" };
    };
    const local_changed = !std.mem.eql(u8, b.base_hash, before_hash);
    const remote_changed = !std.mem.eql(u8, b.base_hash, try hash(a, remote.content));
    if (local_changed and remote_changed) {
        try backup(a, storage, ".doin-sync-conflict", remote.content);
        return .{ .state = "conflict" };
    }
    if (local_changed) {
        const payload = try std.json.Stringify.valueAlloc(a, .{ .revision = remote.revision, .content = before }, .{});
        const response = try http(a, config_dir, c, "PUT", "/v1/document", payload);
        const pushed = try document(a, response);
        if (response.code == 409) {
            try backup(a, storage, ".doin-sync-conflict", pushed.content);
            return .{ .state = "conflict" };
        }
        if (pushed.revision <= remote.revision or !std.mem.eql(u8, pushed.content, before)) return error.SyncOfflineOrAmbiguous;
        if (!std.mem.eql(u8, before, try read(a, task_path))) return error.DocumentChanged;
        try save(a, storage, ".doin-sync.json", State{ .identity = identity, .revision = pushed.revision, .base_hash = before_hash });
        return .{ .state = "pushed" };
    }
    if (!remote_changed) {
        try backup(a, storage, ".doin-sync-conflict", remote.content);
        return .{ .state = "conflict" };
    }
    try backup(a, storage, ".doin-sync-local", before);
    try atomic(a, try path(a, storage, ".tasks.undo"), before);
    try atomic(a, try path(a, storage, ".tasks.undo-current"), remote.content);
    if (!std.mem.eql(u8, before, try read(a, task_path))) return error.DocumentChanged;
    try atomic(a, task_path, remote.content);
    try save(a, storage, ".doin-sync.json", State{ .identity = identity, .revision = remote.revision, .base_hash = try hash(a, remote.content) });
    return .{ .state = "pulled" };
}

pub fn run(a: A, args: []const []const u8, config_dir: []const u8, storage: []const u8) !void {
    const cmd = if (args.len > 0) args[0] else "status";
    if (std.mem.eql(u8, cmd, "auto")) {
        if (try platform.env(a, "DOIN_JOB_STORAGE")) |expected| {
            defer a.free(expected);
            if (!std.mem.eql(u8, expected, storage)) return error.SyncJobStorageChanged;
        }
        return @import("sync_background.zig").run(a, args[1..], config_dir, storage, .{ .tick = autoTick });
    }
    if (std.mem.eql(u8, cmd, "login")) return login(a, args, config_dir);
    if (std.mem.eql(u8, cmd, "logout")) {
        if (args.len != 1) return error.InvalidSyncArguments;
        const c = credentials(a, config_dir) catch |err| {
            if (err == error.SyncLoginRequired) return output("Already signed out. Markdown kept.\n");
            return err;
        };
        const response = try http(a, config_dir, c, "POST", "/v1/logout", "{}");
        if (response.code != 401) _ = try success(a, response);
        const p = try path(a, config_dir, "sync.json");
        defer a.free(p);
        try std.fs.cwd().deleteFile(p);
        return output("Signed out; this device session revoked. Local Markdown kept.\n");
    }
    if (args.len > 0 and (std.mem.eql(u8, cmd, "devices") or std.mem.eql(u8, cmd, "revoke") or std.mem.eql(u8, cmd, "billing") or std.mem.eql(u8, cmd, "change") or std.mem.eql(u8, cmd, "portal") or std.mem.eql(u8, cmd, "cancel") or std.mem.eql(u8, cmd, "resume") or std.mem.eql(u8, cmd, "recover") or std.mem.eql(u8, cmd, "export") or std.mem.eql(u8, cmd, "delete"))) {
        _ = try managed(a, args, config_dir, try credentials(a, config_dir));
        return;
    }
    const status = std.mem.eql(u8, cmd, "status") or std.mem.eql(u8, cmd, "account");
    const push = std.mem.eql(u8, cmd, "push");
    const pull = std.mem.eql(u8, cmd, "pull");
    if (!status and !push and !pull) return error.UnknownSyncCommand;
    const accept = pull and args.len == 2 and std.mem.eql(u8, args[1], "--accept-remote");
    if (args.len > 1 and !accept) return error.InvalidSyncArguments;
    const c = credentials(a, config_dir) catch |err| {
        if (status and err == error.SyncLoginRequired) return output("Sync off. Local Markdown only. Use sync login to opt in.\n");
        return err;
    };
    const identity = try hash(a, try std.fmt.allocPrint(a, "{s}\n{s}", .{ c.endpoint, c.token }));
    var baseline: ?State = load(State, a, storage, ".doin-sync.json") catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (baseline) |s| if (s.revision < 0 or s.revision >= 9007199254740991) return error.InvalidSyncState;
    if (baseline) |s| if (!std.mem.eql(u8, s.identity, identity)) {
        baseline = null;
    };
    if (status) return account(a, config_dir, c);
    const lock_path = try path(a, storage, ".tasks.lock");
    defer a.free(lock_path);
    const lock = try std.fs.cwd().createFile(lock_path, .{ .truncate = false, .mode = 0o600 });
    defer lock.close();
    if (!try platform.tryLockExclusive(lock)) return error.StorageBusy;
    const task_path = try path(a, storage, "tasks.md");
    defer a.free(task_path);
    const before = try read(a, task_path);
    defer a.free(before);
    const before_hash = try hash(a, before);
    if (!std.unicode.utf8ValidateSlice(before) or std.mem.indexOfScalar(u8, before, 0) != null) return error.InvalidSyncDocument;
    const revision = if (baseline) |s| s.revision else 0;
    const payload = if (push) try std.json.Stringify.valueAlloc(a, .{ .revision = revision, .content = before }, .{}) else null;
    const response = try http(a, config_dir, c, if (push) "PUT" else "GET", "/v1/document", payload);
    const remote = try document(a, response);
    // Independent editors need not obey our lock; compare immediately before writes.
    if (!std.mem.eql(u8, before, try read(a, task_path))) return error.DocumentChanged;
    if (response.code == 409) {
        try backup(a, storage, ".doin-sync-conflict", remote.content);
        try output("Cloud changed. Local Markdown kept; remote copy saved as .doin-sync-conflict-*. Merge manually, or sync pull --accept-remote to keep cloud and back up local.\n");
        return error.SyncRevisionConflict;
    }
    if (push) {
        if (remote.revision <= revision or !std.mem.eql(u8, remote.content, before)) return error.SyncOfflineOrAmbiguous;
        try save(a, storage, ".doin-sync.json", State{ .identity = identity, .revision = remote.revision, .base_hash = before_hash });
        return output("Pushed Markdown.\n");
    }
    const same = std.mem.eql(u8, before, remote.content);
    const clean = if (baseline) |s| std.mem.eql(u8, s.base_hash, before_hash) else before.len == 0 or std.mem.eql(u8, before, "# Tasks\n\n");
    if (!same and !clean and !accept) {
        try backup(a, storage, ".doin-sync-conflict", remote.content);
        try output("Local changes kept; remote copy saved as .doin-sync-conflict-*. Use sync pull --accept-remote only to replace local with cloud (local backup kept).\n");
        return error.SyncLocalChanges;
    }
    if (!same) {
        try backup(a, storage, ".doin-sync-local", before);
        try atomic(a, try path(a, storage, ".tasks.undo"), before);
        try atomic(a, try path(a, storage, ".tasks.undo-current"), remote.content);
        if (!std.mem.eql(u8, before, try read(a, task_path))) return error.DocumentChanged;
        try atomic(a, task_path, remote.content);
    }
    try save(a, storage, ".doin-sync.json", State{ .identity = identity, .revision = remote.revision, .base_hash = try hash(a, remote.content) });
    try output("Pulled Markdown. Previous local copy kept; undo available.\n");
}

fn mcpId(value_: []const u8, hex_only: bool) !void {
    if (value_.len == 0 or value_.len > 80 or (hex_only and value_.len != 64)) return error.InvalidMcpArguments;
    for (value_) |ch| {
        if (hex_only) {
            if (!std.ascii.isHex(ch) or std.ascii.isUpper(ch)) return error.InvalidMcpArguments;
        } else if (!std.ascii.isAlphanumeric(ch) and ch != '-') return error.InvalidMcpArguments;
    }
}
fn mcpGrants(a: A, args: []const []const u8, config_dir: []const u8) !void {
    const command = if (args.len == 0) "list" else args[0];
    if (std.mem.eql(u8, command, "list")) {
        if (args.len > 1) return error.InvalidMcpArguments;
        const result = try query(a, config_dir, "GET", "/v1/mcp/grants", null);
        try cleanOutput(a, try std.json.Stringify.valueAlloc(a, result, .{ .whitespace = .indent_2 }));
        return output("\n");
    }
    if (args.len < 2) return error.InvalidMcpArguments;
    try mcpId(args[1], true);
    if (std.mem.eql(u8, command, "revoke")) {
        if (args.len != 2) return error.InvalidMcpArguments;
        _ = try query(a, config_dir, "DELETE", try std.fmt.allocPrint(a, "/v1/mcp/grants/{s}", .{args[1]}), null);
        return output("Remote MCP access revoked.\n");
    }
    if (!std.mem.eql(u8, command, "review")) return error.InvalidMcpArguments;
    var team: ?[]const u8 = null;
    var folder: ?[]const u8 = null;
    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.InvalidMcpArguments;
        try mcpId(args[i + 1], false);
        if (std.mem.eql(u8, args[i], "--team") and team == null) team = args[i + 1] else if (std.mem.eql(u8, args[i], "--folder") and folder == null) folder = args[i + 1] else return error.InvalidMcpArguments;
    }
    if (team != null and folder == null) return error.InvalidMcpArguments;
    const reviewed = try query(a, config_dir, "GET", try std.fmt.allocPrint(a, "/v1/mcp/grants/requests/{s}", .{args[1]}), null);
    if (!std.mem.eql(u8, try string(reviewed, "request_id"), args[1]) or !std.mem.eql(u8, try string(reviewed, "status"), "pending")) return error.InvalidSyncResponse;
    try output("Review remote MCP access. Only approve a connection you started.\n");
    try cleanOutput(a, try std.json.Stringify.valueAlloc(a, reviewed, .{ .whitespace = .indent_2 }));
    try output("\n");
    if (reviewed.object.get("redirect_is_loopback")) |local| {
        if (local == .bool and local.bool) try output("Redirect goes to a local app; another local process could listen at that address.\n");
    }
    if (team) |t| {
        try cleanOutput(a, try std.fmt.allocPrint(a, "Grant target: team {s}, folder {s}.\n", .{ t, folder.? }));
    } else if (folder) |f| {
        try cleanOutput(a, try std.fmt.allocPrint(a, "Grant target: personal folder {s}.\n", .{f}));
    } else try output("Grant target: your personal Home folder.\n");
    const choice = std.mem.trim(u8, try input(a, "Choose approve, deny, or cancel:"), " \t\r\n");
    if (std.mem.eql(u8, choice, "cancel") or choice.len == 0) return output("Authorization canceled.\n");
    if (std.mem.eql(u8, choice, "deny")) {
        _ = try query(a, config_dir, "POST", "/v1/mcp/grants/deny", try std.json.Stringify.valueAlloc(a, .{ .request_id = args[1], .confirmation = true }, .{}));
        return output("Authorization denied.\n");
    }
    if (!std.mem.eql(u8, choice, "approve")) return error.InvalidMcpArguments;
    const requested = reviewed.object.get("scopes") orelse return error.InvalidSyncResponse;
    if (requested != .array) return error.InvalidSyncResponse;
    const typed = try input(a, "Type the scopes to grant, separated by spaces (tasks:read tasks:write):");
    var scopes: std.ArrayList([]const u8) = .empty;
    defer scopes.deinit(a);
    var words = std.mem.tokenizeAny(u8, typed, " \t\r\n");
    while (words.next()) |scope| {
        if (!std.mem.eql(u8, scope, "tasks:read") and !std.mem.eql(u8, scope, "tasks:write")) return error.InvalidMcpArguments;
        var found = false;
        for (requested.array.items) |item| if (item == .string and std.mem.eql(u8, item.string, scope)) {
            found = true;
            break;
        };
        if (!found or scopes.items.len >= 2) return error.InvalidMcpArguments;
        for (scopes.items) |old| if (std.mem.eql(u8, old, scope)) return error.InvalidMcpArguments;
        try scopes.append(a, scope);
    }
    if (scopes.items.len == 0) return error.InvalidMcpArguments;
    const payload = try std.json.Stringify.valueAlloc(a, .{ .request_id = args[1], .client_id = try string(reviewed, "client_id"), .redirect_uri = try string(reviewed, "redirect_uri"), .scopes = scopes.items, .team_id = team, .folder_id = folder, .confirmation = true }, .{ .emit_null_optional_fields = false });
    _ = try query(a, config_dir, "POST", "/v1/mcp/grants/approve", payload);
    try output("Approved selected scopes. Return to the requesting client's browser.\n");
}
fn mcpAuthorizationUrl(url: []const u8) !void {
    if (url.len == 0 or url.len > 8192) return error.InvalidSyncResponse;
    for (url) |ch| if (ch <= 32 or ch == 127) return error.InvalidSyncResponse;
    const uri = std.Uri.parse(url) catch return error.InvalidSyncResponse;
    if (!std.mem.eql(u8, uri.scheme, "https") or uri.user != null or uri.password != null or uri.fragment != null or uri.port != null) return error.InvalidSyncResponse;
    const host = if (uri.host) |h| h.percent_encoded else return error.InvalidSyncResponse;
    if (host.len < 3 or std.mem.indexOfScalar(u8, host, '.') == null or std.mem.eql(u8, host, "doin.sh") or std.mem.endsWith(u8, host, ".doin.sh") or std.mem.endsWith(u8, host, ".local")) return error.InvalidSyncResponse;
    for (host) |ch| if (!std.ascii.isAlphabetic(ch) and !std.ascii.isDigit(ch) and ch != '.' and ch != '-') return error.InvalidSyncResponse;
}

pub const PlanOption = struct { interval: []const u8, amount: i64 };
pub fn mcp(a: A, args: []const []const u8, config_dir: []const u8) !void {
    const command = if (args.len == 0) "list" else args[0];
    if (std.mem.eql(u8, command, "grants")) return mcpGrants(a, args[1..], config_dir);
    const c = try credentials(a, config_dir);
    var method: []const u8 = "GET";
    var route: []const u8 = "/v1/mcp/connections";
    var payload: ?[]const u8 = null;
    if (std.mem.eql(u8, command, "list")) {
        if (args.len == 3 and std.mem.eql(u8, args[1], "--team")) {
            try mcpId(args[2], false);
            route = try std.fmt.allocPrint(a, "/v1/mcp/connections?team_id={s}", .{args[2]});
        } else if (args.len > 1) return error.InvalidMcpArguments;
    } else {
        if (args.len < 2 or args[1].len == 0 or args[1].len > 64) return error.InvalidMcpArguments;
        for (args[1]) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return error.InvalidMcpArguments;
        route = try std.fmt.allocPrint(a, "/v1/mcp/connections/{s}", .{args[1]});
        if (std.mem.eql(u8, command, "add")) {
            if (args.len < 3) return error.InvalidMcpArguments;
            var token: ?[]const u8 = null;
            var team: ?[]const u8 = null;
            var index: usize = 3;
            while (index < args.len) : (index += 2) {
                if (index + 1 >= args.len) return error.InvalidMcpArguments;
                if (std.mem.eql(u8, args[index], "--team") and team == null) {
                    try mcpId(args[index + 1], false);
                    team = args[index + 1];
                } else if (std.mem.eql(u8, args[index], "--token-env") and token == null) {
                    for (args[index + 1]) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return error.InvalidMcpArguments;
                    token = std.process.getEnvVarOwned(a, args[index + 1]) catch return error.McpTokenMissing;
                    if (token.?.len == 0 or token.?.len > 4096) return error.InvalidMcpArguments;
                } else return error.InvalidMcpArguments;
            }
            if (team) |t| try cleanOutput(a, try std.fmt.allocPrint(a, "Integration license: team {s}; connection stays private to your account.\n", .{t})) else try output("Integration license: personal doinMORE.\n");
            method = "POST";
            route = "/v1/mcp/connections";
            payload = try std.json.Stringify.valueAlloc(a, .{ .name = args[1], .url = args[2], .token = token, .team_id = team }, .{ .emit_null_optional_fields = false });
        } else if (std.mem.eql(u8, command, "oauth")) {
            var scope: ?[]const u8 = null;
            var client_id: ?[]const u8 = null;
            var client_secret: ?[]const u8 = null;
            var index: usize = 2;
            while (index < args.len) : (index += 2) {
                if (index + 1 >= args.len) return error.InvalidMcpArguments;
                if (std.mem.eql(u8, args[index], "--scope") and scope == null) scope = args[index + 1] else if (std.mem.eql(u8, args[index], "--client-id") and client_id == null) client_id = args[index + 1] else if (std.mem.eql(u8, args[index], "--client-secret-env") and client_secret == null) {
                    for (args[index + 1]) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return error.InvalidMcpArguments;
                    client_secret = std.process.getEnvVarOwned(a, args[index + 1]) catch return error.McpTokenMissing;
                    if (client_secret.?.len == 0 or client_secret.?.len > 4096) return error.InvalidMcpArguments;
                } else return error.InvalidMcpArguments;
            }
            if (client_secret != null and client_id == null) return error.InvalidMcpArguments;
            const oauth_body = try std.json.Stringify.valueAlloc(a, .{ .scope = scope, .client_id = client_id, .client_secret = client_secret }, .{ .emit_null_optional_fields = false });
            const result = try success(a, try http(a, config_dir, c, "POST", try std.fmt.allocPrint(a, "{s}/oauth", .{route}), oauth_body));
            const url = try string(result, "authorization_url");
            try mcpAuthorizationUrl(url);
            if (result.object.get("license_team_id")) |selected| {
                if (selected == .string) try cleanOutput(a, try std.fmt.allocPrint(a, "OAuth license: team {s}; connection stays private to your account.\n", .{selected.string})) else try output("OAuth license: personal doinMORE.\n");
            }
            try output("Connect this integration in your browser:\n");
            try cleanOutput(a, url);
            try output("\n");
            platform.openUrl(a, url) catch return output("Browser could not open. Use the secure link above.\n");
            return;
        } else if (std.mem.eql(u8, command, "oauth-revoke")) {
            if (args.len != 2) return error.InvalidMcpArguments;
            method = "DELETE";
            route = try std.fmt.allocPrint(a, "{s}/oauth", .{route});
        } else if (std.mem.eql(u8, command, "remove")) {
            if (args.len != 2) return error.InvalidMcpArguments;
            method = "DELETE";
        } else if (std.mem.eql(u8, command, "tools")) {
            if (args.len != 2) return error.InvalidMcpArguments;
            route = try std.fmt.allocPrint(a, "{s}/tools", .{route});
        } else if (std.mem.eql(u8, command, "call")) {
            if (args.len != 4 or args[3].len > 65536) return error.InvalidMcpArguments;
            const arguments = (std.json.parseFromSlice(std.json.Value, a, args[3], .{}) catch return error.InvalidMcpArguments).value;
            if (arguments != .object) return error.InvalidMcpArguments;
            method = "POST";
            route = try std.fmt.allocPrint(a, "{s}/call", .{route});
            payload = try std.json.Stringify.valueAlloc(a, .{ .tool = args[2], .arguments = arguments, .confirmation = true }, .{});
        } else return error.InvalidMcpArguments;
    }
    const result = try success(a, try http(a, config_dir, c, method, route, payload));
    try cleanOutput(a, try std.json.Stringify.valueAlloc(a, result, .{ .whitespace = .indent_2 }));
    try output("\n");
}
pub const Plan = struct {
    endpoint: []const u8 = "",
    options: []const PlanOption = &.{},
    name: []const u8,
    amount: i64,
    currency: []const u8,
    interval: []const u8,
    billing_mode: []const u8,
    email_ready: bool,
    billing_ready: bool,
};
fn configuredEndpoint(a: A, config_dir: []const u8) ![]const u8 {
    if (std.process.getEnvVarOwned(a, "DOIN_SYNC_ENDPOINT")) |endpoint| {
        try endpointCheck(endpoint);
        return endpoint;
    } else |_| {}
    const c = credentials(a, config_dir) catch |err| {
        if (err != error.SyncLoginRequired) return err;
        return "https://sync.doin.sh";
    };
    return c.endpoint;
}
pub fn plan(a: A, config_dir: []const u8) !Plan {
    const c: Credentials = .{ .endpoint = try configuredEndpoint(a, config_dir), .token = "" };
    const result = try success(a, try http(a, config_dir, c, "GET", "/v1/plan", null));
    var parsed = (try std.json.parseFromValue(Plan, a, result, .{ .ignore_unknown_fields = true })).value;
    parsed.endpoint = c.endpoint;
    if (!std.mem.eql(u8, parsed.name, "doinMORE") or parsed.amount != 499 or !std.mem.eql(u8, parsed.currency, "usd") or !std.mem.eql(u8, parsed.interval, "month")) return error.InvalidSyncResponse;
    if (!std.mem.eql(u8, parsed.billing_mode, "test") and !std.mem.eql(u8, parsed.billing_mode, "live") and !std.mem.eql(u8, parsed.billing_mode, "unavailable")) return error.InvalidSyncResponse;
    if (parsed.options.len == 0) {
        if (result == .object and result.object.contains("options")) return error.InvalidSyncResponse;
        parsed.options = try a.dupe(PlanOption, &.{.{ .interval = "month", .amount = parsed.amount }});
    }
    if (parsed.options.len > 2) return error.InvalidSyncResponse;
    var monthly = false;
    var yearly = false;
    for (parsed.options) |offer| {
        if (offer.amount != (if (std.mem.eql(u8, offer.interval, "month")) @as(i64, 499) else 4999)) return error.InvalidSyncResponse;
        if (std.mem.eql(u8, offer.interval, "month")) {
            if (monthly or offer.amount != parsed.amount) return error.InvalidSyncResponse;
            monthly = true;
        } else if (std.mem.eql(u8, offer.interval, "year")) {
            if (yearly) return error.InvalidSyncResponse;
            yearly = true;
        } else return error.InvalidSyncResponse;
    }
    if (!monthly) return error.InvalidSyncResponse;
    return parsed;
}
pub fn upgrade(a: A, config_dir: []const u8, chosen_plan: Plan, chosen_offer: PlanOption) !void {
    if (!std.mem.eql(u8, chosen_offer.interval, "month") and !std.mem.eql(u8, chosen_offer.interval, "year")) return error.InvalidSyncArguments;
    if (chosen_offer.amount != (if (std.mem.eql(u8, chosen_offer.interval, "month")) @as(i64, 499) else 4999)) return error.InvalidSyncArguments;
    var offered = false;
    for (chosen_plan.options) |offer| if (std.mem.eql(u8, offer.interval, chosen_offer.interval) and offer.amount == chosen_offer.amount) {
        offered = true;
        break;
    };
    if (!offered) return error.InvalidSyncArguments;
    const endpoint = chosen_plan.endpoint;
    try endpointCheck(endpoint);
    var c = credentials(a, config_dir) catch |err| blk: {
        if (err != error.SyncLoginRequired) return err;
        try login(a, &.{ "login", "--endpoint", endpoint }, config_dir);
        break :blk try credentials(a, config_dir);
    };
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, c.endpoint, "/"), std.mem.trimEnd(u8, endpoint, "/"))) {
        try output("The selected plan uses a different sync server. Sign in there before payment. Your previous session is kept if sign-in fails.\n");
        try login(a, &.{ "login", "--endpoint", endpoint }, config_dir);
        c = try credentials(a, config_dir);
    }
    const account_response = try http(a, config_dir, c, "GET", "/v1/account", null);
    if (account_response.code == 401) {
        try login(a, &.{ "login", "--endpoint", endpoint }, config_dir);
        c = try credentials(a, config_dir);
        _ = try success(a, try http(a, config_dir, c, "GET", "/v1/account", null));
    } else _ = try success(a, account_response);
    const checkout_response = try http(a, config_dir, c, "POST", "/v1/checkout", try std.json.Stringify.valueAlloc(a, .{ .interval = chosen_offer.interval }, .{}));
    if (checkout_response.code == 409) {
        const body = (try std.json.parseFromSlice(std.json.Value, a, checkout_response.body, .{})).value;
        if (std.mem.eql(u8, try string(body, "error"), "manage_existing_subscription")) return error.SyncExistingSubscription;
    }
    const checkout = try success(a, checkout_response);
    try payment(checkout, "checkout.stripe.com");
    const url = try string(checkout, "url");
    const executable = if (@import("builtin").os.tag == .macos) "open" else "xdg-open";
    var child = std.process.Child.init(&.{ executable, url }, a);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    const status = child.spawnAndWait() catch {
        return output("Browser could not open. Use the secure link above.\n");
    };
    if (status != .Exited or status.Exited != 0) try output("Browser could not open. Use the secure link above.\n");
}

pub fn query(a: A, config_dir: []const u8, method: []const u8, route: []const u8, body: ?[]const u8) !std.json.Value {
    if (!(std.mem.startsWith(u8, route, "/v1/teams") or std.mem.startsWith(u8, route, "/v1/mcp/"))) return error.InvalidSyncArguments;
    for (route) |ch| if (ch <= 32 or ch == 127) return error.InvalidSyncArguments;
    return success(a, try http(a, config_dir, try credentials(a, config_dir), method, route, body));
}

fn cloudConnectionName(name: []const u8) !void {
    if (name.len == 0 or name.len > 64 or !std.ascii.isAlphanumeric(name[0])) return error.InvalidMcpArguments;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return error.InvalidMcpArguments;
}
pub fn cloudTools(a: A, config_dir: []const u8, name: []const u8, deadline_ms: i64) !std.json.Value {
    try cloudConnectionName(name);
    const route = try std.fmt.allocPrint(a, "/v1/mcp/connections/{s}/tools", .{name});
    return success(a, try httpBudget(a, config_dir, try credentials(a, config_dir), "GET", route, null, deadline_ms));
}
pub fn cloudInvoke(a: A, config_dir: []const u8, name: []const u8, tool: []const u8, arguments: std.json.Value, deadline_ms: i64) !std.json.Value {
    try cloudConnectionName(name);
    if (tool.len == 0 or tool.len > 128 or arguments != .object) return error.InvalidMcpArguments;
    const payload = try std.json.Stringify.valueAlloc(a, .{ .tool = tool, .arguments = arguments, .confirmation = true }, .{});
    if (payload.len > 65536) return error.InvalidMcpArguments;
    const route = try std.fmt.allocPrint(a, "/v1/mcp/connections/{s}/call", .{name});
    return success(a, try httpBudget(a, config_dir, try credentials(a, config_dir), "POST", route, payload, deadline_ms));
}
