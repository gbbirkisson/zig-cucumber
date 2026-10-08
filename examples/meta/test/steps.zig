const std = @import("std");
const cucumber = @import("zig_cucumber");

pub const World = struct {
    arena: std.heap.ArenaAllocator,
    source: []const u8 = "",
    feature: ?cucumber.ast.Feature = null,

    pub fn init(gpa: std.mem.Allocator) World {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(w: *World) void {
        w.arena.deinit();
    }
};

pub const steps = struct {
    pub fn @"the feature file"(w: *World, doc: cucumber.DocString) !void {
        w.source = doc.content;
    }

    pub fn @"I parse it"(w: *World) !void {
        w.feature = try cucumber.ast.parse(w.arena.allocator(), "inline.feature", w.source, null);
    }

    pub fn @"it has {int} scenario"(w: *World, n: usize) !void {
        try std.testing.expectEqual(n, w.feature.?.scenarios.len);
    }

    pub fn @"the feature is named {string}"(w: *World, want: []const u8) !void {
        try std.testing.expectEqualStrings(want, w.feature.?.name);
    }

    pub fn @"the scenario is named {string}"(w: *World, want: []const u8) !void {
        try std.testing.expectEqualStrings(want, w.feature.?.scenarios[0].name);
    }

    pub fn @"the first step's doc string media type is {string}"(w: *World, want: []const u8) !void {
        const sc = w.feature.?.scenarios[0];
        try std.testing.expectEqualStrings(want, sc.steps[0].argument.?.doc_string.media_type.?);
    }

    pub fn @"the inner doc string round trips"(w: *World) !void {
        const doc = w.feature.?.scenarios[0].steps[0].argument.?.doc_string;
        try std.testing.expectEqualStrings("{\n  \"hello\": \"world\"\n}", doc.content);
    }
};
