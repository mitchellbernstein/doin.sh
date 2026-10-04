//! Explicit team administration and Markdown exchange; personal task paths remain separate.
const std = @import("std");
const A = std.mem.Allocator;
const V = std.json.Value;
pub const Adapter = struct {
    request: *const fn (A, []const u8, []const u8, []const u8, ?[]const u8) anyerror!V,
    prompt: *const fn (A, []const u8) anyerror![]const u8,
    output: *const fn (A, []const u8) anyerror!void,
    open: *const fn (A, []const u8) anyerror!void,
    activate: ?*const fn (A, []const u8, []const u8, []const u8, []const u8, []const u8) anyerror!void = null,
    personal: ?*const fn (A, []const u8) anyerror!void = null,
};
const State = struct { id: []const u8, team_name: []const u8 = "Team", folder_name: []const u8 = "Home", folder: ?[]const u8 = null, folder_id: []const u8 = "root", revision: ?i64 = null, base_hash: ?[]const u8 = null };
fn str(v: V, key: []const u8) ![]const u8 {
    if (v != .object) return error.InvalidTeamResponse;
    const item = v.object.get(key) orelse return error.InvalidTeamResponse;
    if (item != .string) return error.InvalidTeamResponse;
    return item.string;
}
fn int(v: V, key: []const u8) !i64 {
    if (v != .object) return error.InvalidTeamResponse;
    const item = v.object.get(key) orelse return error.InvalidTeamResponse;
    if (item != .integer) return error.InvalidTeamResponse;
    return item.integer;
}
fn flag(v: V, key: []const u8) bool {
    if (v != .object) return false;
    const item = v.object.get(key) orelse return false;
    return item == .bool and item.bool;
}
fn equal(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn show(a: A, io: Adapter, v: V) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, v, .{ .whitespace = .indent_2 });
    try io.output(a, try std.fmt.allocPrint(a, "{s}\n", .{bytes}));
}
fn send(a: A, config: []const u8, io: Adapter, method: []const u8, endpoint: []const u8, data: anytype) !V {
    return io.request(a, config, method, endpoint, try std.json.Stringify.valueAlloc(a, data, .{}));
}
fn file(a: A, config: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ config, "team.json" });
}
fn atomic(a: A, p: []const u8, data: []const u8) !void {
    var nonce: [8]u8 = undefined;
    std.crypto.random.bytes(&nonce);
    const tmp = try std.fmt.allocPrint(a, "{s}.{x}.tmp", .{ p, nonce });
    defer std.fs.cwd().deleteFile(tmp) catch {};
    const f = try std.fs.cwd().createFile(tmp, .{ .exclusive = true, .mode = 0o600 });
    defer f.close();
    try @import("platform.zig").privateFile(a, tmp);
    try f.writeAll(data);
    try f.sync();
    try std.fs.cwd().rename(tmp, p);
}
fn save(a: A, config: []const u8, s: State) !void {
    try std.fs.cwd().makePath(config);
    const bytes = try std.json.Stringify.valueAlloc(a, s, .{});
    try atomic(a, try mappingFile(a, config, s.id, s.folder_id), bytes);
    try atomic(a, try file(a, config), bytes);
}
fn mappingFile(a: A, config: []const u8, team_id: []const u8, folder_id: []const u8) ![]const u8 {
    try idCheck(team_id);
    try idCheck(folder_id);
    const identity = try std.json.Stringify.valueAlloc(a, .{ .team = team_id, .folder = folder_id }, .{});
    return std.fs.path.join(a, &.{ config, try std.fmt.allocPrint(a, "team-map-{s}.json", .{try digest(a, identity)}) });
}
fn selectWorkspace(a: A, config: []const u8, io: Adapter, initial: State) !void {
    var selected = initial;
    const mapping = try mappingFile(a, config, initial.id, initial.folder_id);
    if (std.fs.cwd().readFileAlloc(a, mapping, 8192)) |raw| {
        try @import("platform.zig").requirePrivateFile(a, mapping);
        selected = (try std.json.parseFromSlice(State, a, raw, .{ .allocate = .alloc_always })).value;
        if (!equal(selected.id, initial.id) or !equal(selected.folder_id, initial.folder_id)) return error.InvalidTeamResponse;
    } else |err| if (err != error.FileNotFound) return err;
    if (selected.folder == null) {
        const path = try std.fs.path.join(a, &.{ config, "team-workspaces", selected.id, selected.folder_id });
        try std.fs.cwd().makePath(path);
        selected.folder = try std.fs.cwd().realpathAlloc(a, path);
    }
    const teams = try io.request(a, config, "GET", "/v1/teams", null);
    if (teams == .object) if (teams.object.get("teams")) |rows| {
        if (rows == .array) for (rows.array.items) |row| {
            if (equal(try str(row, "id"), selected.id)) selected.team_name = try str(row, "name");
        };
    };
    const metadata = try io.request(a, config, "GET", try std.fmt.allocPrint(a, "/v1/teams/{s}/folders/{s}", .{ selected.id, selected.folder_id }), null);
    selected.folder_name = try str(metadata, "name");
    const resolved = try std.fs.cwd().realpathAlloc(a, selected.folder.?);
    const same_path = if (@import("builtin").os.tag == .windows) std.ascii.eqlIgnoreCase(resolved, selected.folder.?) else equal(resolved, selected.folder.?);
    if (!same_path) return error.TeamFolderMappingChanged;
    try folderGuard(a, config, resolved);
    const task_path = try std.fs.path.join(a, &.{ resolved, "tasks.md" });
    const task = std.fs.cwd().openFile(task_path, .{}) catch |err| blk: {
        if (err != error.FileNotFound) return err;
        try atomic(a, task_path, "");
        break :blk try std.fs.cwd().openFile(task_path, .{});
    };
    task.close();
    try save(a, config, selected);
    if (io.activate) |activate| try activate(a, config, selected.id, selected.folder_id, resolved, try std.fmt.allocPrint(a, "{s} / {s}", .{ selected.team_name, selected.folder_name }));
}
pub fn availableFolders(a: A, config: []const u8, io: Adapter) !V {
    const state = try load(a, config);
    return io.request(a, config, "GET", try std.fmt.allocPrint(a, "/v1/teams/{s}/folders", .{state.id}), null);
}
pub fn eligibleMembers(a: A, config: []const u8, io: Adapter) !V {
    const state = try load(a, config);
    return io.request(a, config, "GET", try std.fmt.allocPrint(a, "/v1/teams/{s}/folders/{s}/members", .{ state.id, state.folder_id }), null);
}
fn load(a: A, config: []const u8) !State {
    try @import("platform.zig").requirePrivateFile(a, try file(a, config));
    const raw = std.fs.cwd().readFileAlloc(a, try file(a, config), 8192) catch return error.SelectTeamFirst;
    const s = (try std.json.parseFromSlice(State, a, raw, .{ .allocate = .alloc_always })).value;
    try idCheck(s.id);
    try idCheck(s.folder_id);
    return s;
}
fn idCheck(id: []const u8) !void {
    if (id.len == 0 or id.len > 80) return error.InvalidTeamId;
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return error.InvalidTeamId;
}
fn askYes(a: A, io: Adapter, label: []const u8) !bool {
    return equal(std.mem.trim(u8, try io.prompt(a, label), " \r\n"), "yes");
}
fn digest(a: A, data: []const u8) ![]const u8 {
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &h, .{});
    return std.fmt.allocPrint(a, "{x}", .{h});
}
fn urlCheck(url: []const u8, host: []const u8) !void {
    const u = try std.Uri.parse(url);
    if (!equal(u.scheme, "https") or u.host == null or !equal(u.host.?.percent_encoded, host) or u.user != null or u.password != null or u.port != null) return error.InvalidTeamCheckoutUrl;
}
fn seatsParse(raw: []const u8) !u32 {
    const n = std.fmt.parseInt(u32, raw, 10) catch return error.InvalidTeamSeats;
    if (n < 1 or n > 10000) return error.InvalidTeamSeats;
    return n;
}
fn folderGuard(a: A, config: []const u8, resolved: []const u8) !void {
    const config_path = try std.fs.path.join(a, &.{ config, "config.json" });
    const config_raw = std.fs.cwd().readFileAlloc(a, config_path, 65536) catch |err| if (err == error.FileNotFound) null else return err;
    if (config_raw) |raw| {
        const personal = (try std.json.parseFromSlice(V, a, raw, .{})).value;
        const team_active = if (personal.object.get("workspace_kind")) |kind| kind == .string and equal(kind.string, "team") else false;
        var personal_paths: [2]?[]const u8 = .{ if (team_active) try str(personal, "personal_storage") else try str(personal, "storage"), null };
        if (personal.object.get("library_root")) |library| {
            if (library == .string) personal_paths[1] = library.string else if (library != .null) return error.InvalidTeamResponse;
        }
        for (personal_paths) |optional_path| {
            const personal_path = optional_path orelse continue;
            const personal_real = std.fs.cwd().realpathAlloc(a, personal_path) catch |err| if (err == error.FileNotFound) try std.fs.path.resolve(a, &.{personal_path}) else return err;
            if (equal(resolved, personal_real) or (std.mem.startsWith(u8, resolved, personal_real) and resolved.len > personal_real.len and std.fs.path.isSep(resolved[personal_real.len])) or (std.mem.startsWith(u8, personal_real, resolved) and personal_real.len > resolved.len and std.fs.path.isSep(personal_real[resolved.len]))) return error.TeamFolderOverlapsPersonalStorage;
        }
    }
    const task_path = try std.fs.path.join(a, &.{ resolved, "tasks.md" });
    const actual = std.fs.cwd().realpathAlloc(a, task_path) catch |err| if (err == error.FileNotFound) return else return err;
    if (!equal(actual, task_path)) return error.TeamTaskSymlinkNotAllowed;
}
pub fn run(a: A, config: []const u8, args: []const []const u8, io: Adapter) !void {
    const command = if (args.len == 0) "list" else args[0];
    if (equal(command, "personal")) {
        const restore = io.personal orelse return error.PersonalWorkspaceUnavailable;
        try restore(a, config);
        try io.output(a, "Personal workspace selected.\n");
        return;
    }
    if (equal(command, "help")) {
        try io.output(a, "doinWITH · $99/user/year · shared team workspaces\n\nteam list · create · switch <id> · members · invite <email> [admin] · accept\nteam remove <account> · transfer <account> · leave · billing · subscribe <seats>\nteam seats <count> · seats-reset · cancel · resume · recover · receipt <file>\nteam folders · folder-create <name> [parent] · folder-select <id>\nteam folder-grant <folder> <account> [read|write] · folder-revoke <folder> <account>\nteam folder <local path> · push · pull · export <file> · delete\n");
        return;
    }
    if (equal(command, "list")) {
        try show(a, io, try io.request(a, config, "GET", "/v1/teams", null));
        return;
    }
    if (equal(command, "create")) {
        const terms = try io.request(a, config, "GET", "/v1/teams/terms", null);
        try io.output(a, try std.fmt.allocPrint(a, "{s}\n", .{try str(terms, "text")}));
        const name = try io.prompt(a, "Team name");
        const entity = try io.prompt(a, "Licensed legal entity");
        const deployment = try io.prompt(a, "Hosting: hosted or self_hosted [hosted]");
        if (!try askYes(a, io, "Accept commercial terms for this entity? Type yes")) return;
        const result = try send(a, config, io, "POST", "/v1/teams", .{ .name = name, .legal_entity = entity, .deployment = if (deployment.len == 0) "hosted" else deployment, .accepted_terms = try str(terms, "version") });
        try selectWorkspace(a, config, io, .{ .id = try str(result, "id") });
        try show(a, io, result);
        return;
    }
    if (equal(command, "switch")) {
        if (args.len != 2) return error.TeamIdRequired;
        try idCheck(args[1]);
        _ = try io.request(a, config, "GET", try std.fmt.allocPrint(a, "/v1/teams/{s}/members", .{args[1]}), null);
        try selectWorkspace(a, config, io, .{ .id = args[1] });
        try io.output(a, "Team selected. Edit this workspace; push/pull remain explicit.\n");
        return;
    }
    if (equal(command, "accept")) {
        if (args.len != 1) return error.InvitationTokenMustUsePrompt;
        const token = try io.prompt(a, "Invitation token from email");
        const result = try send(a, config, io, "POST", "/v1/teams/accept", .{ .token = token });
        try save(a, config, .{ .id = try str(result, "team_id") });
        try io.output(a, "Joined team. No local tasks uploaded.\n");
        return;
    }
    var state = try load(a, config);
    const base = try std.fmt.allocPrint(a, "/v1/teams/{s}", .{state.id});
    if (equal(command, "folders")) {
        try show(a, io, try io.request(a, config, "GET", try std.fmt.allocPrint(a, "{s}/folders", .{base}), null));
        return;
    }
    if (equal(command, "folder-create")) {
        if (args.len < 2 or args.len > 3) return error.TeamFolderNameRequired;
        try show(a, io, try send(a, config, io, "POST", try std.fmt.allocPrint(a, "{s}/folders", .{base}), .{ .name = args[1], .parent_id = if (args.len == 3) args[2] else "root" }));
        return;
    }
    if (equal(command, "folder-select")) {
        if (args.len != 2) return error.TeamFolderIdRequired;
        try idCheck(args[1]);
        _ = try io.request(a, config, "GET", try std.fmt.allocPrint(a, "{s}/folders/{s}", .{ base, args[1] }), null);
        try selectWorkspace(a, config, io, .{ .id = state.id, .folder_id = args[1] });
        try io.output(a, "Cloud folder selected. Pull before pushing; existing local files are preserved.\n");
        return;
    }
    if (equal(command, "folder-grant") or equal(command, "folder-revoke")) {
        if (args.len < 3 or args.len > 4) return error.TeamFolderGrantRequired;
        try idCheck(args[1]);
        if (!try askYes(a, io, "Change this member's folder access? Type yes")) return;
        try show(a, io, try send(a, config, io, if (equal(command, "folder-revoke")) "DELETE" else "POST", try std.fmt.allocPrint(a, "{s}/folders/{s}/grants", .{ base, args[1] }), .{ .account_id = args[2], .access = if (args.len == 4) args[3] else "read" }));
        return;
    }
    if (equal(command, "members") or equal(command, "billing") or equal(command, "audit") or equal(command, "invites")) {
        try show(a, io, try io.request(a, config, "GET", try std.fmt.allocPrint(a, "{s}/{s}", .{ base, command }), null));
        return;
    }
    if (equal(command, "revoke-invite")) {
        if (args.len != 2) return error.TeamInvitationRequired;
        try show(a, io, try send(a, config, io, "POST", try std.fmt.allocPrint(a, "{s}/invites/revoke", .{base}), .{ .invitation_id = args[1] }));
        return;
    }
    if (equal(command, "recover")) {
        const result = try send(a, config, io, "POST", try std.fmt.allocPrint(a, "{s}/recover", .{base}), .{});
        const url = try str(result, "url");
        try urlCheck(url, "invoice.stripe.com");
        if (try askYes(a, io, "Open Stripe invoice to recover team payment? Type yes")) try io.open(a, url);
        return;
    }
    if (equal(command, "invite")) {
        if (args.len < 2 or args.len > 3) return error.TeamEmailRequired;
        const admin_global = args.len == 3 and equal(args[2], "admin");
        if (admin_global) {
            try io.output(a, "Admin role grants access to every team folder, including future folders.\n");
            if (!try askYes(a, io, "Invite with global admin access? Type yes")) return;
        }
        const folder_input = try io.prompt(a, "Invite to cloud folder ID [root]");
        const folder_id = if (folder_input.len == 0) "root" else folder_input;
        try idCheck(folder_id);
        const access_input = try io.prompt(a, "Folder access: read or write [read]");
        const access = if (access_input.len == 0) "read" else access_input;
        if (!equal(access, "read") and !equal(access, "write")) return error.InvalidTeamFolderAccess;
        try show(a, io, try send(a, config, io, "POST", try std.fmt.allocPrint(a, "{s}/invites", .{base}), .{ .email = args[1], .role = if (args.len == 3) args[2] else "member", .folder_id = folder_id, .folder_access = access, .ack_admin_global = admin_global }));
        return;
    }
    if (equal(command, "remove") or equal(command, "transfer")) {
        if (args.len != 2) return error.TeamAccountRequired;
        if (!try askYes(a, io, try std.fmt.allocPrint(a, "{s} account {s}? Type yes", .{ command, args[1] }))) return;
        try show(a, io, try send(a, config, io, "POST", try std.fmt.allocPrint(a, "{s}/{s}", .{ base, if (equal(command, "remove")) "members/remove" else "transfer" }), .{ .account_id = args[1] }));
        return;
    }
    if (equal(command, "leave") or equal(command, "cancel") or equal(command, "resume") or equal(command, "delete") or equal(command, "seats-reset")) {
        if (equal(command, "delete")) try io.output(a, "Permanently deletes cloud team folders and memberships and cancels billing immediately. Local copies remain.\n");
        if (!try askYes(a, io, try std.fmt.allocPrint(a, "{s} selected team? Type yes", .{command}))) return;
        try show(a, io, try send(a, config, io, if (equal(command, "delete")) "DELETE" else "POST", if (equal(command, "delete")) base else try std.fmt.allocPrint(a, "{s}/{s}", .{ base, if (equal(command, "seats-reset")) "seats/reset" else command }), .{}));
        return;
    }
    if (equal(command, "subscribe")) {
        if (args.len != 2) return error.TeamSeatsRequired;
        const seats = try seatsParse(args[1]);
        const terms = try io.request(a, config, "GET", "/v1/teams/terms", null);
        const mode = try str(terms, "billing_mode");
        if (equal(mode, "test")) try io.output(a, "Stripe sandbox: test payments only. Test receipts grant no production commercial rights.\n") else if (!equal(mode, "live")) return error.TeamBillingUnavailable;
        try io.output(a, try std.fmt.allocPrint(a, "{s}\n{s} seats: ${d}.00 USD/year, annual only. Checkout shows applicable taxes.\n", .{ try str(terms, "text"), args[1], @as(u64, seats) * 99 }));
        if (!try askYes(a, io, "Accept terms and open team checkout? Type yes")) return;
        const result = try send(a, config, io, "POST", try std.fmt.allocPrint(a, "{s}/checkout", .{base}), .{ .seats = seats, .accepted_terms = try str(terms, "version") });
        const url = try str(result, "url");
        try urlCheck(url, "checkout.stripe.com");
        try io.open(a, url);
        return;
    }
    if (equal(command, "seats")) {
        if (args.len != 2) return error.TeamSeatsRequired;
        const seats = try seatsParse(args[1]);
        const endpoint = try std.fmt.allocPrint(a, "{s}/seats", .{base});
        const preview = try send(a, config, io, "POST", endpoint, .{ .seats = seats });
        if (!flag(preview, "confirmation_required")) {
            try show(a, io, preview);
            return;
        }
        try show(a, io, preview);
        if (!try askYes(a, io, "Accept this seat change and displayed charge/renewal terms? Type yes")) return;
        if (flag(preview, "renewal_only")) try show(a, io, try send(a, config, io, "POST", endpoint, .{ .seats = seats, .confirm_renewal_reduction = true })) else try show(a, io, try send(a, config, io, "POST", endpoint, .{ .seats = seats, .confirm_amount = try int(preview, "amount_due"), .proration_date = try int(preview, "proration_date") }));
        return;
    }
    if (equal(command, "receipt") or equal(command, "export")) {
        if (args.len != 2) return error.TeamOutputPathRequired;
        if (std.fs.cwd().access(args[1], .{})) |_| {
            if (!try askYes(a, io, "Replace existing export file? Type yes")) return;
        } else |err| {
            if (err != error.FileNotFound) return err;
        }
        const result = try io.request(a, config, "GET", if (equal(command, "export")) try std.fmt.allocPrint(a, "{s}/folders/{s}/document", .{ base, state.folder_id }) else try std.fmt.allocPrint(a, "{s}/{s}", .{ base, command }), null);
        try atomic(a, args[1], if (equal(command, "receipt")) try str(result, "receipt") else try str(result, "content"));
        try io.output(a, "Saved private file. Sandbox receipts grant no production commercial rights.\n");
        return;
    }
    if (equal(command, "folder")) {
        if (args.len != 2) return error.TeamFolderRequired;
        try std.fs.cwd().makePath(args[1]);
        const resolved = try std.fs.cwd().realpathAlloc(a, args[1]);
        try folderGuard(a, config, resolved);
        state.folder = resolved;
        state.revision = null;
        state.base_hash = null;
        try save(a, config, state);
        if (io.activate) |activate| try activate(a, config, state.id, state.folder_id, resolved, try std.fmt.allocPrint(a, "{s} / {s}", .{ state.team_name, state.folder_name }));
        try io.output(a, "Team folder linked. Use a separate folder from personal tasks. Push/pull remain explicit.\n");
        return;
    }
    if (equal(command, "push") or equal(command, "pull")) {
        const saved_folder = state.folder orelse return error.TeamFolderRequired;
        const folder = try std.fs.cwd().realpathAlloc(a, saved_folder);
        const same_path = if (@import("builtin").os.tag == .windows) std.ascii.eqlIgnoreCase(folder, saved_folder) else equal(folder, saved_folder);
        if (!same_path) return error.TeamFolderMappingChanged;
        try folderGuard(a, config, folder);
        const lock_path = try std.fs.path.join(a, &.{ folder, ".tasks.lock" });
        const lock = try std.fs.cwd().createFile(lock_path, .{ .truncate = false, .mode = 0o600 });
        defer lock.close();
        if (!try @import("platform.zig").tryLockExclusive(lock)) return error.StorageBusy;
        const document_path = try std.fs.path.join(a, &.{ folder, "tasks.md" });
        const local = std.fs.cwd().readFileAlloc(a, document_path, 524288) catch |err| if (err == error.FileNotFound) "" else return err;
        if (equal(command, "push")) {
            const revision = state.revision orelse return error.PullTeamBeforePush;
            if (!try askYes(a, io, "Upload this folder's tasks.md to selected team? Type yes")) return;
            const result = try send(a, config, io, "PUT", try std.fmt.allocPrint(a, "{s}/folders/{s}/document", .{ base, state.folder_id }), .{ .revision = revision, .content = local });
            state.revision = try int(result, "revision");
            state.base_hash = try digest(a, local);
            try save(a, config, state);
            try io.output(a, "Team document pushed.\n");
            return;
        }
        const result = try io.request(a, config, "GET", try std.fmt.allocPrint(a, "{s}/folders/{s}/document", .{ base, state.folder_id }), null);
        const remote = try str(result, "content");
        if (local.len > 0 and (state.base_hash == null or !equal(try digest(a, local), state.base_hash.?))) {
            try io.output(a, "Local edits differ from last sync. Pull preserves a backup and needs explicit replacement.\n");
            if (!try askYes(a, io, "Replace tasks.md with cloud copy? Type yes")) return;
            const current = std.fs.cwd().readFileAlloc(a, document_path, 524288) catch |err| if (err == error.FileNotFound) "" else return err;
            if (!equal(current, local)) return error.TeamLocalEditsChanged;
            try atomic(a, try std.fmt.allocPrint(a, "{s}.backup-{d}", .{ document_path, std.time.milliTimestamp() }), current);
        }
        try folderGuard(a, config, folder);
        const latest = std.fs.cwd().readFileAlloc(a, document_path, 524288) catch |err| if (err == error.FileNotFound) "" else return err;
        if (!equal(latest, local)) return error.TeamLocalEditsChanged;
        try atomic(a, document_path, remote);
        state.revision = try int(result, "revision");
        state.base_hash = try digest(a, remote);
        try save(a, config, state);
        try io.output(a, "Team document pulled.\n");
        return;
    }
    return error.UnknownTeamCommand;
}
