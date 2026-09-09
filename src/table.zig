const std = @import("std");
const gherkin = @import("gherkin.zig");
const convert = @import("convert.zig");

pub const Table = struct {
    header: gherkin.Row,
    rows: []const gherkin.Row,

    /// Index of the named column, or null.
    pub fn column(t: Table, name: []const u8) ?usize {
        for (t.header.cells, 0..) |c, i| {
            if (std.mem.eql(u8, c, name)) return i;
        }
        return null;
    }

    /// Cell at `row` in the named column, or null when either is out of range.
    pub fn cell(t: Table, row: usize, name: []const u8) ?[]const u8 {
        if (row >= t.rows.len) return null;
        const col = t.column(name) orelse return null;
        const cells = t.rows[row].cells;
        return if (col < cells.len) cells[col] else null;
    }
};

pub const RowsError = error{
    MissingColumn,
    UnmappedColumn,
    RaggedRow,
} || convert.Error;

/// One `T` per data row, fields filled from the header by name. Comptime only.
pub fn rows(comptime T: type, comptime table: Table) RowsError![]const T {
    @setEvalBranchQuota(1_000_000);
    const info = switch (@typeInfo(T)) {
        .@"struct" => |s| if (s.is_tuple) return RowsError.UnsupportedType else s,
        else => return RowsError.UnsupportedType,
    };

    var indexes: [info.field_names.len]usize = undefined;
    for (info.field_names, info.field_attrs, 0..) |name, attrs, i| {
        if (attrs.@"comptime") return RowsError.UnsupportedType;
        indexes[i] = table.column(name) orelse return RowsError.MissingColumn;
    }

    for (table.header.cells) |col| {
        var mapped = false;
        for (info.field_names) |name| {
            if (std.mem.eql(u8, col, name)) mapped = true;
        }
        if (!mapped) return RowsError.UnmappedColumn;
    }

    var out: []const T = &.{};
    for (table.rows) |row| {
        if (row.cells.len != table.header.cells.len) return RowsError.RaggedRow;
        var value: T = undefined;
        for (info.field_names, info.field_types, 0..) |name, FieldType, i| {
            @field(value, name) = try convert.parse(FieldType, row.cells[indexes[i]]);
        }
        out = out ++ [_]T{value};
    }
    return out;
}

const example: Table = .{
    .header = .{ .cells = &.{ "name", "age" }, .line = 4 },
    .rows = &.{
        .{ .cells = &.{ "Alice", "30" }, .line = 5 },
        .{ .cells = &.{ "Bob", "41" }, .line = 6 },
    },
};

test "column finds a header index" {
    try std.testing.expectEqual(@as(?usize, 0), example.column("name"));
    try std.testing.expectEqual(@as(?usize, 1), example.column("age"));
    try std.testing.expectEqual(@as(?usize, null), example.column("rank"));
}

test "cell reads by row and column name" {
    try std.testing.expectEqualStrings("Alice", example.cell(0, "name").?);
    try std.testing.expectEqualStrings("41", example.cell(1, "age").?);
}

test "an absent column or row yields null rather than an error" {
    try std.testing.expectEqual(@as(?[]const u8, null), example.cell(0, "rank"));
    try std.testing.expectEqual(@as(?[]const u8, null), example.cell(2, "name"));

    const ragged: Table = .{
        .header = .{ .cells = &.{ "name", "age" }, .line = 1 },
        .rows = &.{.{ .cells = &.{"Alice"}, .line = 2 }},
    };
    try std.testing.expectEqual(@as(?[]const u8, null), ragged.cell(0, "age"));
}

test "rows keep their line numbers, which conversion errors need" {
    try std.testing.expectEqual(@as(u32, 4), example.header.line);
    try std.testing.expectEqual(@as(u32, 6), example.rows[1].line);
}

const User = struct {
    name: []const u8,
    age: u32,
    role: enum { admin, guest },
};

const users: Table = .{
    .header = .{ .cells = &.{ "name", "age", "role" }, .line = 4 },
    .rows = &.{
        .{ .cells = &.{ "Alice", "30", "admin" }, .line = 5 },
        .{ .cells = &.{ "Bob", "41", "guest" }, .line = 6 },
    },
};

test "rows map onto struct fields by header name" {
    const parsed = comptime try rows(User, users);
    try std.testing.expectEqualDeep(&[_]User{
        .{ .name = "Alice", .age = 30, .role = .admin },
        .{ .name = "Bob", .age = 41, .role = .guest },
    }, parsed);
}

test "column order in the header need not match field order" {
    const shuffled: Table = .{
        .header = .{ .cells = &.{ "role", "name", "age" }, .line = 1 },
        .rows = &.{.{ .cells = &.{ "guest", "Carol", "22" }, .line = 2 }},
    };
    const parsed = comptime try rows(User, shuffled);
    try std.testing.expectEqualDeep(
        &[_]User{.{ .name = "Carol", .age = 22, .role = .guest }},
        parsed,
    );
}

test "an optional field is null for an empty cell" {
    const Maybe = struct { name: []const u8, age: ?u32 };
    const t: Table = .{
        .header = .{ .cells = &.{ "name", "age" }, .line = 1 },
        .rows = &.{
            .{ .cells = &.{ "Dave", "" }, .line = 2 },
            .{ .cells = &.{ "Erin", "9" }, .line = 3 },
        },
    };
    const parsed = comptime try rows(Maybe, t);
    try std.testing.expectEqual(@as(?u32, null), parsed[0].age);
    try std.testing.expectEqual(@as(?u32, 9), parsed[1].age);
}

test "a header with no data rows yields an empty slice" {
    const t: Table = .{
        .header = .{ .cells = &.{ "name", "age", "role" }, .line = 1 },
        .rows = &.{},
    };
    try std.testing.expectEqual(@as(usize, 0), (comptime try rows(User, t)).len);
}

test "a field with no header column" {
    const t: Table = .{
        .header = .{ .cells = &.{ "name", "age" }, .line = 1 },
        .rows = &.{.{ .cells = &.{ "Alice", "30" }, .line = 2 }},
    };
    try std.testing.expectError(RowsError.MissingColumn, comptime rows(User, t));
}

test "a header column with no field" {
    const t: Table = .{
        .header = .{ .cells = &.{ "name", "age", "role", "rank" }, .line = 1 },
        .rows = &.{.{ .cells = &.{ "Alice", "30", "admin", "1" }, .line = 2 }},
    };
    try std.testing.expectError(RowsError.UnmappedColumn, comptime rows(User, t));
}

test "a target that is not a named struct" {
    try std.testing.expectError(RowsError.UnsupportedType, comptime rows(u32, users));
    try std.testing.expectError(RowsError.UnsupportedType, comptime rows([]const u8, users));
    try std.testing.expectError(RowsError.UnsupportedType, comptime rows(struct { u8, u8, u8 }, users));
}

test "a comptime field cannot be filled from a cell" {
    const Tagged = struct { name: []const u8, comptime age: u32 = 5 };
    try std.testing.expectError(RowsError.UnsupportedType, comptime rows(Tagged, users));
}

test "a row narrower than the header" {
    const t: Table = .{
        .header = .{ .cells = &.{ "name", "age" }, .line = 1 },
        .rows = &.{.{ .cells = &.{"Alice"}, .line = 2 }},
    };
    const R = struct { name: []const u8, age: u32 };
    try std.testing.expectError(RowsError.RaggedRow, comptime rows(R, t));
}

test "a table larger than the default branch quota allows" {
    const n = 40;
    const many = comptime blk: {
        var out: [n]gherkin.Row = undefined;
        for (&out, 0..) |*r, i| r.* = .{ .cells = &.{ "n", "7" }, .line = @intCast(i + 2) };
        break :blk out;
    };
    const t: Table = .{
        .header = .{ .cells = &.{ "name", "age" }, .line = 1 },
        .rows = &many,
    };
    const R = struct { name: []const u8, age: u32 };
    const parsed = comptime try rows(R, t);
    try std.testing.expectEqual(@as(usize, n), parsed.len);
    try std.testing.expectEqual(@as(u32, 7), parsed[n - 1].age);
}

test "a cell that does not convert" {
    const t: Table = .{
        .header = .{ .cells = &.{ "name", "age", "role" }, .line = 1 },
        .rows = &.{.{ .cells = &.{ "Alice", "not a number", "admin" }, .line = 2 }},
    };
    try std.testing.expectError(RowsError.NotAnInteger, comptime rows(User, t));

    const bad_enum: Table = .{
        .header = .{ .cells = &.{ "name", "age", "role" }, .line = 1 },
        .rows = &.{.{ .cells = &.{ "Alice", "30", "wizard" }, .line = 2 }},
    };
    try std.testing.expectError(RowsError.UnknownEnumField, comptime rows(User, bad_enum));
}
