const std = @import("std");
pub fn build(b: *std.Build) void {
    const name = b.option([]const u8, "name", "Executable name") orelse "doin";
    const version = b.option([]const u8, "version", "Release version") orelse "0.3.0";
    const options = b.addOptions();
    options.addOption([]const u8, "app_name", name);
    options.addOption([]const u8, "app_version", version);
    const exe = b.addExecutable(.{ .name = name, .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .link_libc = true,
    }) });
    exe.root_module.addOptions("build_options", options);
    if (exe.root_module.resolved_target.?.result.os.tag == .windows) {
        exe.linkSystemLibrary("advapi32");
        exe.linkSystemLibrary("shell32");
    }
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the CLI").dependOn(&run.step);
}
