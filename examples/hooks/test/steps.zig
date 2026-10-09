const std = @import("std");
const cucumber = @import("cucumber_zig");

pub const World = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    tmp: ?std.testing.TmpDir = null,
    trace: std.ArrayList(u8) = .empty,
    records: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) World {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(w: *World) void {
        w.trace.deinit(w.gpa);
        w.records.deinit(w.gpa);
        if (w.tmp) |*t| t.cleanup();
    }

    fn note(w: *World, s: []const u8) void {
        if (w.trace.items.len != 0) w.trace.append(w.gpa, ',') catch return;
        w.trace.appendSlice(w.gpa, s) catch return;
    }
};

pub const hooks = struct {
    pub fn @"before @io"(w: *World) void {
        w.note("io");
    }

    pub fn before(w: *World) void {
        w.note("before");
    }

    pub fn before_step(w: *World) void {
        w.note("+step");
    }

    pub fn after_step(w: *World, r: cucumber.Result) void {
        w.note(switch (r) {
            .passed => "-step",
            .failed => "-fail",
            .skipped => "-skip",
        });
    }

    pub fn after(w: *World) void {
        w.note("after");
    }
};

pub const steps = struct {
    pub fn @"a report file"(w: *World) !void {
        w.tmp = std.testing.tmpDir(.{});
    }

    pub fn @"I record {string}"(w: *World, line: []const u8) !void {
        if (w.records.items.len != 0) try w.records.append(w.gpa, ',');
        try w.records.appendSlice(w.gpa, line);
        try w.tmp.?.dir.writeFile(w.io, .{ .sub_path = "report.txt", .data = w.records.items });
    }

    pub fn @"the report reads {string}"(w: *World, want: []const u8) !void {
        const got = try w.tmp.?.dir.readFileAlloc(w.io, "report.txt", w.gpa, .unlimited);
        defer w.gpa.free(got);
        try std.testing.expectEqualStrings(want, got);
    }

    pub fn @"the trace is {string}"(w: *World, want: []const u8) !void {
        try std.testing.expectEqualStrings(want, w.trace.items);
    }

    pub fn @"I skip here"() !void {
        return error.SkipZigTest;
    }

    pub fn @"this never runs"() !void {
        return error.ShouldNotReachHere;
    }
};
