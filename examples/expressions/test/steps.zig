const std = @import("std");
const cucumber = @import("zig_cucumber");

pub const Color = enum { red, green, blue };

const Person = struct { name: []const u8, age: u32 };

pub const World = struct {
    bindings: usize = 0,
    color: ?Color = null,
    oldest: []const u8 = "",
};

pub const steps = struct {
    pub fn @"the int {int}"(w: *World, n: i64) !void {
        try std.testing.expectEqual(@as(i64, 42), n);
        w.bindings += 1;
    }

    pub fn @"the float {float}"(w: *World, f: f64) !void {
        try std.testing.expectEqual(@as(f64, 1.5), f);
        w.bindings += 1;
    }

    pub fn @"the word {word}"(w: *World, s: []const u8) !void {
        try std.testing.expectEqualStrings("hello", s);
        w.bindings += 1;
    }

    pub fn @"the string {string}"(w: *World, s: []const u8) !void {
        try std.testing.expectEqualStrings("a b", s);
        w.bindings += 1;
    }

    pub fn @"the anonymous {}"(w: *World, s: []const u8) !void {
        try std.testing.expectEqualStrings("7", s);
        w.bindings += 1;
    }

    pub fn @"I have {int} bindings"(w: *World, want: usize) !void {
        try std.testing.expectEqual(want, w.bindings);
    }

    pub fn @"I press ok/cancel"(w: *World) !void {
        w.bindings += 1;
    }

    pub fn @"I add {int} item(s)"(w: *World, n: i64) !void {
        try std.testing.expectEqual(@as(i64, 1), n);
        w.bindings += 1;
    }

    pub fn @"a literal \\(paren) and \\{brace} and a\\/slash"(w: *World) !void {
        w.bindings += 1;
    }

    pub fn @"the color {Color}"(w: *World, c: Color) !void {
        w.color = c;
    }

    pub fn @"the color was {Color}"(w: *World, c: Color) !void {
        try std.testing.expectEqual(c, w.color.?);
    }

    pub fn @"the color was not {Color}"(w: *World, c: Color) !void {
        try std.testing.expect(w.color.? != c);
    }

    pub fn @"these people"(w: *World, people: []const Person) !void {
        var oldest: Person = people[0];
        for (people[1..]) |p| if (p.age > oldest.age) {
            oldest = p;
        };
        w.oldest = oldest.name;
    }

    pub fn @"the oldest is {string}"(w: *World, want: []const u8) !void {
        try std.testing.expectEqualStrings(want, w.oldest);
    }
};
