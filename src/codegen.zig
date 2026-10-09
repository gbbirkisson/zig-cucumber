const std = @import("std");
const gherkin = @import("gherkin.zig");
const runner = @import("runner.zig");
const tags_mod = @import("tags.zig");

/// Re-exported so a generator needs only this module.
pub const gherkin_mod = gherkin;

const Allocator = std.mem.Allocator;

pub const Error = error{
    DuplicateScenarioName,
    UnknownPlaceholder,
    RaggedRow,
} || Allocator.Error;

/// Which mistake `emit` found and where, for a caller that renders it.
pub const Diagnostic = struct {
    path: []const u8,
    line: u32,
    tag: Tag,
    /// The other line a mistake spanning two of them involves.
    other_line: ?u32 = null,

    pub const Tag = enum {
        duplicate_scenario_name,
        unknown_placeholder,
        ragged_row,
    };

    pub fn format(self: Diagnostic, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s}:{d}: {s}", .{ self.path, self.line, self.message() });
        if (self.other_line) |other| try w.print(", first seen at {s}:{d}", .{ self.path, other });
    }

    fn message(self: Diagnostic) []const u8 {
        return switch (self.tag) {
            .duplicate_scenario_name => "two scenarios of this feature produce the same test name",
            .unknown_placeholder => "this step names a column its Examples table does not declare",
            .ragged_row => "this Examples row has fewer cells than its header",
        };
    }
};

/// Fills `diag` and returns the error the tag stands for.
fn fail(
    diag: ?*Diagnostic,
    path: []const u8,
    tag: Diagnostic.Tag,
    line: u32,
    other_line: ?u32,
) Error {
    if (diag) |d| d.* = .{ .path = path, .line = line, .tag = tag, .other_line = other_line };
    return switch (tag) {
        .duplicate_scenario_name => Error.DuplicateScenarioName,
        .unknown_placeholder => Error.UnknownPlaceholder,
        .ragged_row => Error.RaggedRow,
    };
}

/// A parsed tag expression. A caller parses one before walking the features so
/// that a malformed expression is reported once, against the option it came
/// from, rather than once per scenario.
pub const TagFilter = struct {
    nodes: []const tags_mod.Node,

    pub const ParseError = tags_mod.ParseError || Allocator.Error;

    /// A `buf` of `text.len` nodes is always enough; see `tags.parse`.
    pub fn parse(arena: Allocator, text: []const u8) ParseError!TagFilter {
        const buf = try arena.alloc(tags_mod.Node, text.len);
        return .{ .nodes = try tags_mod.parse(text, buf) };
    }

    fn admits(self: TagFilter, scenario_tags: []const []const u8) bool {
        return tags_mod.eval(self.nodes, scenario_tags);
    }
};

/// Whether a scenario's effective tag set satisfies `filter`. A null filter
/// admits everything.
fn admits(filter: ?TagFilter, scenario_tags: []const []const u8) bool {
    const f = filter orelse return true;
    return f.admits(scenario_tags);
}

/// One scenario ready to emit: its own tags plus every enclosing scope's, and
/// its own steps behind every enclosing Background's.
const Unit = struct {
    /// The composed Zig test name.
    test_name: []const u8,
    /// The scenario's own name, as written.
    name: []const u8,
    tags: []const []const u8,
    steps: []const gherkin.Step,
    line: u32,
};

/// Feature, then rule, then scenario, then examples tags, deduplicated.
fn effectiveTags(
    arena: Allocator,
    feature: []const []const u8,
    rule: []const []const u8,
    scenario: []const []const u8,
    examples: []const []const u8,
) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for ([_][]const []const u8{ feature, rule, scenario, examples }) |set| {
        for (set) |tag| {
            for (out.items) |seen| {
                if (std.mem.eql(u8, seen, tag)) break;
            } else try out.append(arena, tag);
        }
    }
    return out.items;
}

/// Feature background, then rule background, then the scenario's own.
fn mergedSteps(
    arena: Allocator,
    feature_bg: ?gherkin.Background,
    rule_bg: ?gherkin.Background,
    own: []const gherkin.Step,
) Allocator.Error![]const gherkin.Step {
    var out: std.ArrayList(gherkin.Step) = .empty;
    if (feature_bg) |bg| try out.appendSlice(arena, bg.steps);
    if (rule_bg) |bg| try out.appendSlice(arena, bg.steps);
    try out.appendSlice(arena, own);
    return out.items;
}

/// Every scenario of a feature, outlines expanded, ready to emit.
fn units(arena: Allocator, feature: gherkin.Feature, diag: ?*Diagnostic) Error![]const Unit {
    var out: std.ArrayList(Unit) = .empty;
    try collect(arena, &out, feature, feature.background, null, feature.scenarios, diag);
    for (feature.rules) |rule| {
        try collect(arena, &out, feature, feature.background, rule, rule.scenarios, diag);
    }
    for (out.items, 0..) |a, ai| {
        for (out.items[ai + 1 ..]) |b| {
            if (std.mem.eql(u8, a.test_name, b.test_name)) {
                return fail(diag, feature.path, .duplicate_scenario_name, b.line, a.line);
            }
        }
    }
    return out.items;
}

fn collect(
    arena: Allocator,
    out: *std.ArrayList(Unit),
    feature: gherkin.Feature,
    feature_bg: ?gherkin.Background,
    rule: ?gherkin.Rule,
    scenarios: []const gherkin.Scenario,
    diag: ?*Diagnostic,
) Error!void {
    const rule_tags: []const []const u8 = if (rule) |r| r.tags else &.{};
    const rule_bg: ?gherkin.Background = if (rule) |r| r.background else null;
    for (scenarios) |scenario| {
        const steps = try mergedSteps(arena, feature_bg, rule_bg, scenario.steps);
        if (scenario.examples.len == 0) {
            const tags = try effectiveTags(arena, feature.tags, rule_tags, scenario.tags, &.{});
            try out.append(arena, .{
                .test_name = try testName(arena, feature.name, scenario.name, tags, null),
                .name = scenario.name,
                .tags = tags,
                .steps = steps,
                .line = scenario.line,
            });
            continue;
        }
        for (scenario.examples) |examples| {
            const tags = try effectiveTags(arena, feature.tags, rule_tags, scenario.tags, examples.tags);
            for (examples.rows, 0..) |row, index| {
                var expanded: std.ArrayList(gherkin.Step) = .empty;
                for (steps) |step| {
                    const site: Site = .{ .path = feature.path, .step_line = step.line, .diag = diag };
                    try expanded.append(arena, try substituteStep(arena, step, examples.header, row, site));
                }
                try out.append(arena, .{
                    .test_name = try testName(arena, feature.name, scenario.name, tags, .{
                        .index = index,
                        .header = examples.header,
                        .row = row,
                    }),
                    .name = scenario.name,
                    .tags = tags,
                    .steps = expanded.items,
                    .line = row.line,
                });
            }
        }
    }
}

/// The field names the generated source spells out as literal text. A field
/// added to, renamed in or removed from one of these types has to be reflected
/// in `emit`, so a mismatch is a compile error of this file rather than of the
/// source it writes.
const emitted_fields = struct {
    const scenario = [_][]const u8{ "name", "tags", "file", "line", "steps" };
    const step = [_][]const u8{ "keyword", "keyword_text", "text", "argument", "line" };
    const argument = [_][]const u8{ "doc_string", "data_table" };
    const doc_string = [_][]const u8{ "media_type", "content", "line" };
    const row = [_][]const u8{ "cells", "line" };
};

comptime {
    checkFields(runner.Scenario, &emitted_fields.scenario);
    checkFields(gherkin.Step, &emitted_fields.step);
    checkFields(gherkin.Argument, &emitted_fields.argument);
    checkFields(gherkin.DocString, &emitted_fields.doc_string);
    checkFields(gherkin.Row, &emitted_fields.row);
}

/// Comptime only. Fails to compile when `T`'s fields and `names` differ.
fn checkFields(comptime T: type, comptime names: []const []const u8) void {
    const declared = std.meta.fieldNames(T);
    for (declared) |name| {
        for (names) |emitted| {
            if (std.mem.eql(u8, name, emitted)) break;
        } else @panic("codegen does not emit field '" ++ name ++ "' of " ++ @typeName(T));
    }
    for (names) |emitted| {
        for (declared) |name| {
            if (std.mem.eql(u8, name, emitted)) break;
        } else @panic("codegen emits '" ++ emitted ++ "', which " ++ @typeName(T) ++ " does not declare");
    }
}

/// One generated Zig source file, and how many Zig tests it declares. A caller
/// counts these to tell a run that selected nothing from one that ran.
pub const Generated = struct {
    source: []const u8,
    tests: usize,
};

/// One generated Zig source file for one parsed feature.
pub fn emit(
    arena: Allocator,
    feature: gherkin.Feature,
    filter: ?TagFilter,
    diag: ?*Diagnostic,
) Error!Generated {
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena,
        \\// Generated by cucumber-zig from {s}. Do not edit.
        \\const cucumber = @import("cucumber_zig");
        \\const user = @import("steps");
        \\
        \\
    , .{feature.path});
    var emitted: usize = 0;
    for (try units(arena, feature, diag)) |unit| {
        if (!admits(filter, unit.tags)) continue;
        const i = emitted;
        emitted += 1;
        try out.print(arena,
            \\test "{f}" {{
            \\    try cucumber.run(user, scenario_{d});
            \\}}
            \\
            \\const scenario_{d}: cucumber.Scenario = .{{
            \\    .name = "{f}",
            \\    .tags = &.{{
            \\
        , .{ std.zig.fmtString(unit.test_name), i, i, std.zig.fmtString(unit.name) });
        for (unit.tags) |tag| try out.print(arena, "        \"{f}\",\n", .{std.zig.fmtString(tag)});
        try out.print(arena,
            \\    }},
            \\    .file = "{f}",
            \\    .line = {d},
            \\    .steps = &.{{
            \\
        , .{ std.zig.fmtString(feature.path), unit.line });
        for (unit.steps) |step| {
            try out.print(arena, "        .{{ .keyword = .{s}, .keyword_text = \"{f}\", .text = \"{f}\", .argument = ", .{
                @tagName(step.keyword),
                std.zig.fmtString(step.keyword_text),
                std.zig.fmtString(step.text),
            });
            try emitArgument(arena, &out, step.argument);
            try out.print(arena, ", .line = {d} }},\n", .{step.line});
        }
        try out.appendSlice(arena, "    },\n};\n\n");
    }
    return .{ .source = out.items, .tests = emitted };
}

fn emitArgument(arena: Allocator, out: *std.ArrayList(u8), argument: ?gherkin.Argument) Error!void {
    const arg = argument orelse return out.appendSlice(arena, "null");
    switch (arg) {
        .doc_string => |d| {
            try out.appendSlice(arena, ".{ .doc_string = .{ .media_type = ");
            if (d.media_type) |mt| {
                try out.print(arena, "\"{f}\"", .{std.zig.fmtString(mt)});
            } else {
                try out.appendSlice(arena, "null");
            }
            try out.print(arena, ", .content = \"{f}\", .line = {d} }} }}", .{
                std.zig.fmtString(d.content),
                d.line,
            });
        },
        .data_table => |rows| {
            try out.appendSlice(arena, ".{ .data_table = &.{ ");
            for (rows) |row| {
                try out.appendSlice(arena, ".{ .cells = &.{ ");
                for (row.cells) |cell| try out.print(arena, "\"{f}\", ", .{std.zig.fmtString(cell)});
                try out.print(arena, "}}, .line = {d} }}, ", .{row.line});
            }
            try out.appendSlice(arena, "} }");
        },
    }
}

test "effective tags concatenate in scope order and deduplicate" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const got = try effectiveTags(a.allocator(), &.{ "feat", "shared" }, &.{"rule"}, &.{ "scen", "shared" }, &.{"ex"});
    try std.testing.expectEqualDeep(&[_][]const u8{ "feat", "shared", "rule", "scen", "ex" }, got);
}

test "merged steps put feature background first, then rule, then own" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const mk = struct {
        fn step(text: []const u8) gherkin.Step {
            return .{ .keyword = .given, .keyword_text = "Given", .text = text, .argument = null, .line = 1 };
        }
    };
    const fbg: gherkin.Background = .{ .name = "", .description = "", .steps = &.{mk.step("f1")}, .line = 1 };
    const rbg: gherkin.Background = .{ .name = "", .description = "", .steps = &.{mk.step("r1")}, .line = 1 };
    const got = try mergedSteps(a.allocator(), fbg, rbg, &.{mk.step("own")});
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqualStrings("f1", got[0].text);
    try std.testing.expectEqualStrings("r1", got[1].text);
    try std.testing.expectEqualStrings("own", got[2].text);
    const bare = try mergedSteps(a.allocator(), null, null, &.{mk.step("x")});
    try std.testing.expectEqual(@as(usize, 1), bare.len);
}

test "a tag filter selects which scenarios are emitted" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const of = struct {
        fn filter(al: Allocator, text: []const u8) !TagFilter {
            return TagFilter.parse(al, text);
        }
    }.filter;
    try std.testing.expect(admits(null, &.{}));
    try std.testing.expect(admits(try of(arena, "@db"), &.{"db"}));
    try std.testing.expect(!admits(try of(arena, "@db"), &.{"slow"}));
    try std.testing.expect(admits(try of(arena, "@a and not @b"), &.{"a"}));
    try std.testing.expect(!admits(try of(arena, "@a and not @b"), &.{ "a", "b" }));
    try std.testing.expectError(error.UnexpectedEnd, of(arena, "@a and"));
    try std.testing.expectError(error.EmptyExpression, of(arena, ""));
}

/// The feature and step a substitution failure blames.
const Site = struct {
    path: []const u8,
    step_line: u32,
    diag: ?*Diagnostic,
};

/// Replaces every `<name>` with that row's value for column `name`.
/// A `<name>` with no matching column is an error.
fn substitute(
    arena: Allocator,
    text: []const u8,
    header: gherkin.Row,
    row: gherkin.Row,
    site: Site,
) Error![]const u8 {
    if (std.mem.findScalar(u8, text, '<') == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '<') {
            try out.append(arena, text[i]);
            i += 1;
            continue;
        }
        const close = std.mem.findScalarPos(u8, text, i, '>') orelse {
            try out.append(arena, text[i]);
            i += 1;
            continue;
        };
        const name = text[i + 1 .. close];
        const col = columnOf(header, name) orelse
            return fail(site.diag, site.path, .unknown_placeholder, site.step_line, null);
        if (col >= row.cells.len) return fail(site.diag, site.path, .ragged_row, row.line, null);
        try out.appendSlice(arena, row.cells[col]);
        i = close + 1;
    }
    return out.items;
}

fn columnOf(header: gherkin.Row, name: []const u8) ?usize {
    for (header.cells, 0..) |cell, i| {
        if (std.mem.eql(u8, cell, name)) return i;
    }
    return null;
}

/// A step with every placeholder in its text and its argument substituted.
fn substituteStep(
    arena: Allocator,
    step: gherkin.Step,
    header: gherkin.Row,
    row: gherkin.Row,
    site: Site,
) Error!gherkin.Step {
    var out = step;
    out.text = try substitute(arena, step.text, header, row, site);
    if (step.argument) |arg| out.argument = switch (arg) {
        .doc_string => |d| .{ .doc_string = .{
            .media_type = d.media_type,
            .content = try substitute(arena, d.content, header, row, site),
            .line = d.line,
        } },
        .data_table => |rows| blk: {
            var table: std.ArrayList(gherkin.Row) = .empty;
            for (rows) |r| {
                var cells: std.ArrayList([]const u8) = .empty;
                for (r.cells) |c| try cells.append(arena, try substitute(arena, c, header, row, site));
                try table.append(arena, .{ .cells = cells.items, .line = r.line });
            }
            break :blk .{ .data_table = table.items };
        },
    };
    return out;
}

test "placeholders are substituted in text, doc strings and table cells" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const header: gherkin.Row = .{ .cells = &.{ "who", "n" }, .line = 1 };
    const row: gherkin.Row = .{ .cells = &.{ "Alice", "42" }, .line = 2 };
    const site: Site = .{ .path = "s.feature", .step_line = 2, .diag = null };

    try std.testing.expectEqualStrings("Alice has 42 cukes", try substitute(arena, "<who> has <n> cukes", header, row, site));
    try std.testing.expectEqualStrings("no placeholders", try substitute(arena, "no placeholders", header, row, site));
    try std.testing.expectEqualStrings("a < b", try substitute(arena, "a < b", header, row, site));
    try std.testing.expectError(Error.UnknownPlaceholder, substitute(arena, "<nope>", header, row, site));

    const doc: gherkin.Step = .{
        .keyword = .given,
        .keyword_text = "Given",
        .text = "payload",
        .argument = .{ .doc_string = .{ .media_type = "json", .content = "{\"who\": \"<who>\"}", .line = 3 } },
        .line = 2,
    };
    const sd = try substituteStep(arena, doc, header, row, site);
    try std.testing.expectEqualStrings("{\"who\": \"Alice\"}", sd.argument.?.doc_string.content);

    const tbl: gherkin.Step = .{
        .keyword = .given,
        .keyword_text = "Given",
        .text = "rows",
        .argument = .{ .data_table = &.{.{ .cells = &.{ "<who>", "fixed" }, .line = 4 }} },
        .line = 2,
    };
    const st = try substituteStep(arena, tbl, header, row, site);
    try std.testing.expectEqualStrings("Alice", st.argument.?.data_table[0].cells[0]);
    try std.testing.expectEqualStrings("fixed", st.argument.?.data_table[0].cells[1]);
}

/// `"<Feature>: <Scenario>"`, with the outline row and the tag set appended
/// when they apply.
fn testName(
    arena: Allocator,
    feature: []const u8,
    scenario: []const u8,
    tags: []const []const u8,
    outline: ?struct { index: usize, header: gherkin.Row, row: gherkin.Row },
) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "{s}: {s}", .{ feature, scenario });
    if (outline) |o| {
        try out.print(arena, " #{d} (", .{o.index + 1});
        for (o.header.cells, 0..) |col, i| {
            if (i > 0) try out.appendSlice(arena, ", ");
            const value = if (i < o.row.cells.len) o.row.cells[i] else "";
            try out.print(arena, "{s}={s}", .{ col, value });
        }
        try out.append(arena, ')');
    }
    if (tags.len > 0) {
        try out.appendSlice(arena, " [");
        for (tags, 0..) |tag, i| {
            if (i > 0) try out.append(arena, ' ');
            try out.print(arena, "@{s}", .{tag});
        }
        try out.append(arena, ']');
    }
    return out.items;
}

test "test names cover the plain, outline and tagged shapes" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const header: gherkin.Row = .{ .cells = &.{ "a", "b" }, .line = 1 };
    const row: gherkin.Row = .{ .cells = &.{ "1", "2" }, .line = 2 };

    try std.testing.expectEqualStrings(
        "Calculator: Adding two numbers",
        try testName(arena, "Calculator", "Adding two numbers", &.{}, null),
    );
    try std.testing.expectEqualStrings(
        "Calculator: Adding [@math @smoke]",
        try testName(arena, "Calculator", "Adding", &.{ "math", "smoke" }, null),
    );
    try std.testing.expectEqualStrings(
        "F: S #1 (a=1, b=2)",
        try testName(arena, "F", "S", &.{}, .{ .index = 0, .header = header, .row = row }),
    );
    try std.testing.expectEqualStrings(
        "F: S #3 (a=1, b=2) [@x]",
        try testName(arena, "F", "S", &.{"x"}, .{ .index = 2, .header = header, .row = row }),
    );
}

/// The rendered diagnostic, for a test to compare against.
fn rendered(arena: Allocator, diag: Diagnostic) ![]const u8 {
    return std.fmt.allocPrint(arena, "{f}", .{diag});
}

test "two scenarios sharing a name are rejected, naming both lines" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const src =
        \\Feature: F
        \\
        \\  Scenario: same
        \\    Given a
        \\
        \\  Scenario: same
        \\    Given a
        \\
    ;
    const feature = try gherkin.parse(arena, "d.feature", src, null);
    var diag: Diagnostic = undefined;
    try std.testing.expectError(Error.DuplicateScenarioName, units(arena, feature, &diag));
    try std.testing.expectEqual(Diagnostic.Tag.duplicate_scenario_name, diag.tag);
    try std.testing.expectEqualStrings(
        "d.feature:6: two scenarios of this feature produce the same test name, first seen at d.feature:3",
        try rendered(arena, diag),
    );
}

test "a placeholder with no matching column is rejected, naming the step" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const src =
        \\Feature: F
        \\
        \\  Scenario Outline: o
        \\    Given <nope>
        \\
        \\    Examples:
        \\      | n |
        \\      | 1 |
        \\
    ;
    const feature = try gherkin.parse(arena, "p.feature", src, null);
    var diag: Diagnostic = undefined;
    try std.testing.expectError(Error.UnknownPlaceholder, units(arena, feature, &diag));
    try std.testing.expectEqualStrings(
        "p.feature:4: this step names a column its Examples table does not declare",
        try rendered(arena, diag),
    );
}

test "the emitted source for a background plus an outline" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const src =
        \\@math
        \\Feature: Calc
        \\
        \\  Background:
        \\    Given a fresh calculator
        \\
        \\  Scenario Outline: adding
        \\    When I add <n>
        \\
        \\    Examples:
        \\      | n |
        \\      | 7 |
        \\
    ;
    const feature = try gherkin.parse(arena, "calc.feature", src, null);
    const got = try emit(arena, feature, null, null);
    try std.testing.expectEqual(@as(usize, 1), got.tests);
    try std.testing.expectEqualStrings(
        \\// Generated by cucumber-zig from calc.feature. Do not edit.
        \\const cucumber = @import("cucumber_zig");
        \\const user = @import("steps");
        \\
        \\test "Calc: adding #1 (n=7) [@math]" {
        \\    try cucumber.run(user, scenario_0);
        \\}
        \\
        \\const scenario_0: cucumber.Scenario = .{
        \\    .name = "adding",
        \\    .tags = &.{
        \\        "math",
        \\    },
        \\    .file = "calc.feature",
        \\    .line = 12,
        \\    .steps = &.{
        \\        .{ .keyword = .given, .keyword_text = "Given", .text = "a fresh calculator", .argument = null, .line = 5 },
        \\        .{ .keyword = .when, .keyword_text = "When", .text = "I add 7", .argument = null, .line = 8 },
        \\    },
        \\};
        \\
        \\
    , got.source);
}

test "the emitted source for a data table, escapes and all" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const src =
        "Feature: T\n" ++
        "\n" ++
        "  Scenario: table\n" ++
        "    Given the users are\n" ++
        "      | name      | note        |\n" ++
        "      | \"Alice\" | a\\\\b backslash |\n";
    const feature = try gherkin.parse(arena, "t.feature", src, null);
    const got = try emit(arena, feature, null, null);
    try std.testing.expectEqual(@as(usize, 1), got.tests);
    try std.testing.expectEqualStrings(
        \\// Generated by cucumber-zig from t.feature. Do not edit.
        \\const cucumber = @import("cucumber_zig");
        \\const user = @import("steps");
        \\
        \\test "T: table" {
        \\    try cucumber.run(user, scenario_0);
        \\}
        \\
        \\const scenario_0: cucumber.Scenario = .{
        \\    .name = "table",
        \\    .tags = &.{
        \\    },
        \\    .file = "t.feature",
        \\    .line = 3,
        \\    .steps = &.{
        \\        .{ .keyword = .given, .keyword_text = "Given", .text = "the users are", .argument = .{ .data_table = &.{ .{ .cells = &.{ "name", "note", }, .line = 5 }, .{ .cells = &.{ "\"Alice\"", "a\\b backslash", }, .line = 6 }, } }, .line = 4 },
        \\    },
        \\};
        \\
        \\
    , got.source);
}

test "the emitted source for a doc string" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const src =
        \\Feature: D
        \\
        \\  Scenario: doc
        \\    Given the payload
        \\      """json
        \\      {"a": 1}
        \\      """
        \\
    ;
    const feature = try gherkin.parse(arena, "d.feature", src, null);
    const got = try emit(arena, feature, null, null);
    try std.testing.expectEqual(@as(usize, 1), got.tests);
    try std.testing.expectEqualStrings(
        \\// Generated by cucumber-zig from d.feature. Do not edit.
        \\const cucumber = @import("cucumber_zig");
        \\const user = @import("steps");
        \\
        \\test "D: doc" {
        \\    try cucumber.run(user, scenario_0);
        \\}
        \\
        \\const scenario_0: cucumber.Scenario = .{
        \\    .name = "doc",
        \\    .tags = &.{
        \\    },
        \\    .file = "d.feature",
        \\    .line = 3,
        \\    .steps = &.{
        \\        .{ .keyword = .given, .keyword_text = "Given", .text = "the payload", .argument = .{ .doc_string = .{ .media_type = "json", .content = "{\"a\": 1}", .line = 5 } }, .line = 4 },
        \\    },
        \\};
        \\
        \\
    , got.source);
}

test "a filtered-out scenario is not emitted at all" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const src =
        \\Feature: F
        \\
        \\  @slow
        \\  Scenario: excluded
        \\    Given a
        \\
        \\  Scenario: kept
        \\    Given a
        \\
    ;
    const feature = try gherkin.parse(arena, "f.feature", src, null);
    const got = try emit(arena, feature, try TagFilter.parse(arena, "not @slow"), null);
    try std.testing.expectEqual(@as(usize, 1), got.tests);
    try std.testing.expect(std.mem.find(u8, got.source, "kept") != null);
    try std.testing.expect(std.mem.find(u8, got.source, "excluded") == null);
    try std.testing.expect(std.mem.find(u8, got.source, "scenario_1") == null);
}

test "a filter that matches nothing emits no tests" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const feature = try gherkin.parse(arena, "n.feature", "Feature: F\n\n  Scenario: s\n    Given a\n", null);
    const got = try emit(arena, feature, try TagFilter.parse(arena, "@nope"), null);
    try std.testing.expectEqual(@as(usize, 0), got.tests);
}

test "a row shorter than its header is reported, not a crash" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const header: gherkin.Row = .{ .cells = &.{ "a", "b" }, .line = 1 };
    const short: gherkin.Row = .{ .cells = &.{"1"}, .line = 2 };
    const site: Site = .{ .path = "r.feature", .step_line = 3, .diag = null };
    try std.testing.expectError(Error.RaggedRow, substitute(arena, "<b>", header, short, site));
    try std.testing.expectEqualStrings("1", try substitute(arena, "<a>", header, short, site));
}
