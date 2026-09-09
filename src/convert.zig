const std = @import("std");

pub const Error = error{
    NotAnInteger,
    IntegerOutOfRange,
    NotAFloat,
    NotABool,
    UnknownEnumField,
    UnsupportedType,
};

/// Converts comptime-known text to `T`. An empty text yields null for an
/// optional and an error for anything else.
pub fn parse(comptime T: type, comptime text: []const u8) Error!T {
    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, text, 10) catch |e| switch (e) {
            error.Overflow => Error.IntegerOutOfRange,
            error.InvalidCharacter => Error.NotAnInteger,
        },
        .float => if (T == f16 or T == f32 or T == f64 or T == f80 or T == f128)
            std.fmt.parseFloat(T, text) catch Error.NotAFloat
        else
            Error.UnsupportedType,
        .bool => if (std.mem.eql(u8, text, "true"))
            true
        else if (std.mem.eql(u8, text, "false"))
            false
        else
            Error.NotABool,
        .@"enum" => |info| if (info.field_names.len == 0)
            Error.UnknownEnumField
        else
            std.meta.stringToEnum(T, text) orelse Error.UnknownEnumField,
        .optional => |o| if (text.len == 0) null else try parse(o.child, text),
        .pointer => if (T == []const u8) text else Error.UnsupportedType,
        else => Error.UnsupportedType,
    };
}

const Color = enum { red, green, blue };

test "every target type" {
    try std.testing.expectEqual(@as(u8, 200), comptime try parse(u8, "200"));
    try std.testing.expectEqual(@as(i64, -19), comptime try parse(i64, "-19"));
    try std.testing.expectEqual(@as(f64, -9.2), comptime try parse(f64, "-9.2"));
    try std.testing.expectEqual(@as(f32, 3.5), comptime try parse(f32, "3.5"));
    try std.testing.expectEqual(true, comptime try parse(bool, "true"));
    try std.testing.expectEqual(false, comptime try parse(bool, "false"));
    try std.testing.expectEqual(Color.green, comptime try parse(Color, "green"));
    try std.testing.expectEqualStrings("raw text", comptime try parse([]const u8, "raw text"));
}

test "an optional is null for an empty cell" {
    try std.testing.expectEqual(@as(?u8, null), comptime try parse(?u8, ""));
    try std.testing.expectEqual(@as(?u8, 7), comptime try parse(?u8, "7"));
    try std.testing.expectEqual(@as(?Color, null), comptime try parse(?Color, ""));
}

test "range violations at both ends" {
    try std.testing.expectError(Error.IntegerOutOfRange, comptime parse(u8, "300"));
    try std.testing.expectError(Error.IntegerOutOfRange, comptime parse(u8, "-1"));
    try std.testing.expectError(Error.IntegerOutOfRange, comptime parse(i8, "128"));
}

test "every error case" {
    try std.testing.expectError(Error.NotAnInteger, comptime parse(u8, "x"));
    try std.testing.expectError(Error.NotAnInteger, comptime parse(u8, ""));
    try std.testing.expectError(Error.NotAFloat, comptime parse(f64, "x"));
    try std.testing.expectError(Error.NotABool, comptime parse(bool, "yes"));
    try std.testing.expectError(Error.UnknownEnumField, comptime parse(Color, "mauve"));
    try std.testing.expectError(Error.UnsupportedType, comptime parse(struct {}, "x"));
    try std.testing.expectError(Error.UnsupportedType, comptime parse([]const u32, "x"));
    try std.testing.expectError(Error.UnsupportedType, comptime parse([]u8, "x"));
    try std.testing.expectError(Error.UnsupportedType, comptime parse([:0]const u8, "x"));
    try std.testing.expectError(Error.UnsupportedType, comptime parse(?[:0]const u8, "x"));
    try std.testing.expectError(Error.UnsupportedType, comptime parse(*const u8, "x"));
    try std.testing.expectError(Error.UnsupportedType, comptime parse(c_longdouble, "1.5"));
    const empty_enum = comptime if (parse(enum {}, "x")) |_| false else |e| e == Error.UnknownEnumField;
    try std.testing.expect(empty_enum);
}
