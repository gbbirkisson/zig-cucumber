const std = @import("std");
const cucumber = @import("zig_cucumber");

pub const World = struct {
    count: i64 = 0,
};

pub const steps = struct {
    pub fn @"a fresh counter"(w: *World) !void {
        w.count = 0;
    }
    pub fn @"I add {int}"(w: *World, n: i64) !void {
        w.count += n;
    }
    pub fn @"the count is {int}"(w: *World, want: i64) !void {
        try std.testing.expectEqual(want, w.count);
    }
    pub fn @"the rows"(t: cucumber.Table) !void {
        try std.testing.expectEqualStrings("Alice", t.cell(0, "name").?);
        try std.testing.expectEqualStrings("a\\b \"quoted\"", t.cell(0, "note").?);
    }
    pub fn @"the payload"(doc: cucumber.DocString) !void {
        try std.testing.expectEqualStrings("json", doc.media_type.?);
        try std.testing.expectEqualStrings("{\"a\": 1}", doc.content);
    }
};
