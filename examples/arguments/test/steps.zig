const std = @import("std");
const cucumber = @import("zig_cucumber");

const Person = struct { name: []const u8, age: u32 };

pub const World = struct {
    table: ?cucumber.Table = null,
    doc: ?cucumber.DocString = null,
    oldest: []const u8 = "",
    oldest_age: u32 = 0,
};

pub const steps = struct {
    pub fn @"the table"(w: *World, t: cucumber.Table) !void {
        w.table = t;
    }

    pub fn @"cell {int} {string} is {string}"(
        w: *World,
        row: usize,
        column: []const u8,
        want: []const u8,
    ) !void {
        try std.testing.expectEqualStrings(want, w.table.?.cell(row, column).?);
    }

    pub fn @"the {string} column is {string}"(
        w: *World,
        column: []const u8,
        want: []const u8,
    ) !void {
        var buf: [64]u8 = undefined;
        var end: usize = 0;
        for (0..w.table.?.rows.len) |row| {
            const c = w.table.?.cell(row, column).?;
            if (row != 0) {
                buf[end] = ',';
                end += 1;
            }
            @memcpy(buf[end..][0..c.len], c);
            end += c.len;
        }
        try std.testing.expectEqualStrings(want, buf[0..end]);
    }

    pub fn @"the note cell keeps its escapes"(w: *World) !void {
        try std.testing.expectEqualStrings("a\\b \"quoted\"", w.table.?.cell(0, "note").?);
    }

    pub fn @"these people"(w: *World, people: []const Person) !void {
        var oldest: Person = people[0];
        for (people[1..]) |p| if (p.age > oldest.age) {
            oldest = p;
        };
        w.oldest = oldest.name;
        w.oldest_age = oldest.age;
    }

    pub fn @"the oldest is {string} aged {int}"(w: *World, want: []const u8, age: u32) !void {
        try std.testing.expectEqualStrings(want, w.oldest);
        try std.testing.expectEqual(age, w.oldest_age);
    }

    pub fn @"the payload"(w: *World, doc: cucumber.DocString) !void {
        w.doc = doc;
    }

    pub fn @"the payload has {int} lines"(w: *World, want: usize) !void {
        var it = std.mem.splitScalar(u8, w.doc.?.content, '\n');
        var n: usize = 0;
        while (it.next()) |_| n += 1;
        try std.testing.expectEqual(want, n);
    }

    pub fn @"the payload media type is unset"(w: *World) !void {
        try std.testing.expect(w.doc.?.media_type == null);
    }

    pub fn @"the payload media type is {string}"(w: *World, want: []const u8) !void {
        try std.testing.expectEqualStrings(want, w.doc.?.media_type.?);
    }
};
