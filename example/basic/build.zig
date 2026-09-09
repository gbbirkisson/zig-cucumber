const std = @import("std");
const cucumber_build = @import("zig_cucumber");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run feature tests");

    const dep = b.dependency("zig_cucumber", .{ .target = target, .optimize = optimize });

    _ = cucumber_build.addFeatureTests(b, test_step, dep, .{
        .features = b.path("features"),
        .steps = b.path("test/steps.zig"),
        .imports = &.{.{ .name = "myapp", .module = mod }},
        .target = target,
        .optimize = optimize,
        .tags = b.option([]const u8, "tags", "Tag expression selecting scenarios"),
        .filter = b.option([]const u8, "filter", "Test name substring"),
    });
}
