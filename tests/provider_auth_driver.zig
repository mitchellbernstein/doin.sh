const std = @import("std");
const auth = @import("auth");
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len != 4) return error.Arguments;
    if (std.mem.eql(u8, args[1], "token")) {
        const secret = try auth.token(a, args[2], args[3]);
        try std.fs.File.stdout().writeAll(secret);
        return;
    }
    if (std.mem.eql(u8, args[1], "login")) return auth.login(a, args[2], args[3]);
    if (std.mem.eql(u8, args[1], "logout")) return auth.logout(a, args[2], args[3]);
    return error.Arguments;
}
