const std = @import("std");
const myapp = @import("myapp");

pub const World = struct {
    total: i64 = 0,
};

pub const steps = struct {
    pub fn @"a fresh calculator"(w: *World) !void {
        w.total = 0;
    }
    pub fn @"I add {int}"(w: *World, n: i64) !void {
        w.total = myapp.add(w.total, n);
    }
    pub fn @"the total is {int}"(w: *World, want: i64) !void {
        try std.testing.expectEqual(want, w.total);
    }
};
