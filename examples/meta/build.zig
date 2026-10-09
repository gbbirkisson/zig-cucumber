const std = @import("std");
const cucumber_build = @import("cucumber_zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run feature tests");
    const dep = b.dependency("cucumber_zig", .{ .target = target, .optimize = optimize });

    _ = cucumber_build.addFeatureTests(b, test_step, dep, .{
        .features = b.path("test/features"),
        .steps = b.path("test/steps.zig"),
        .target = target,
        .optimize = optimize,
        .tags = b.option([]const u8, "tags", "Tag expression selecting scenarios"),
        .filter = b.option([]const u8, "filter", "Test name substring"),
    });
}
