const std = @import("std");

pub const World = struct {
    trace: [8][]const u8 = undefined,
    len: usize = 0,

    fn note(w: *World, s: []const u8) void {
        w.trace[w.len] = s;
        w.len += 1;
    }
};

pub const hooks = struct {
    pub fn @"before @rule"(w: *World) void {
        w.note("in-rule");
    }
};

pub const steps = struct {
    pub fn @"a feature background step"(w: *World) !void {
        w.note("feature");
    }
    pub fn @"a rule background step"(w: *World) !void {
        w.note("rule");
    }
    pub fn @"the trace is {string} and the row is {string}"(w: *World, want: []const u8, row: []const u8) !void {
        try @"the trace is {string}"(w, want);
        try std.testing.expect(std.mem.eql(u8, row, "one") or std.mem.eql(u8, row, "two"));
    }
    pub fn @"the trace is {string}"(w: *World, want: []const u8) !void {
        var buf: [64]u8 = undefined;
        var end: usize = 0;
        for (w.trace[0..w.len], 0..) |s, i| {
            if (i != 0) {
                buf[end] = ',';
                end += 1;
            }
            @memcpy(buf[end..][0..s.len], s);
            end += s.len;
        }
        try std.testing.expectEqualStrings(want, buf[0..end]);
    }
};
