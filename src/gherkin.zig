const std = @import("std");
const Allocator = std.mem.Allocator;

const Parser = @import("gherkin/Parser.zig");
const Tokenizer = @import("gherkin/Tokenizer.zig");

pub const Error = error{ InvalidGherkin, OutOfMemory };

/// `path` is an opaque label. It is never opened. It exists so a diagnostic and
/// a parsed tree can say which file they came from.
/// `source` and `path` must both outlive the returned tree.
pub fn parse(
    arena: Allocator,
    path: []const u8,
    source: []const u8,
    diag: ?*Diagnostic,
) Error!Feature {
    return Parser.parse(arena, path, source, diag);
}

pub const Keyword = Tokenizer.Keyword;

pub const Feature = struct {
    path: []const u8,
    tags: []const []const u8,
    name: []const u8,
    description: []const u8,
    background: ?Background,
    scenarios: []const Scenario,
    rules: []const Rule,
    line: u32,
};

pub const Rule = struct {
    tags: []const []const u8,
    name: []const u8,
    description: []const u8,
    background: ?Background,
    scenarios: []const Scenario,
    line: u32,
};

pub const Background = struct {
    name: []const u8,
    description: []const u8,
    steps: []const Step,
    line: u32,
};

pub const Scenario = struct {
    tags: []const []const u8,
    keyword_text: []const u8,
    name: []const u8,
    description: []const u8,
    steps: []const Step,
    examples: []const Examples,
    line: u32,
};

pub const Examples = struct {
    tags: []const []const u8,
    name: []const u8,
    description: []const u8,
    header: Row,
    rows: []const Row,
    line: u32,
};

pub const Row = struct {
    cells: []const []const u8,
    line: u32,
};

pub const Step = struct {
    keyword: Keyword,
    keyword_text: []const u8,
    text: []const u8,
    argument: ?Argument,
    line: u32,
};

pub const Argument = union(enum) {
    doc_string: DocString,
    data_table: []const Row,
};

pub const DocString = struct {
    media_type: ?[]const u8,
    content: []const u8,
    line: u32,
};

pub const Diagnostic = struct {
    path: []const u8,
    line: u32,
    tag: Tag,

    pub const Tag = enum {
        missing_feature,
        multiple_features,
        misplaced_background,
        step_outside_scenario,
        table_outside_step,
        doc_string_outside_step,
        multiple_step_arguments,
        conjunction_without_step,
        step_after_examples,
        unterminated_doc_string,
        ragged_table_row,
        examples_missing_header,
        tags_without_target,
        unexpected_line,
    };

    pub fn format(self: Diagnostic, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s}:{d}: {s}", .{ self.path, self.line, self.message() });
    }

    fn message(self: Diagnostic) []const u8 {
        return switch (self.tag) {
            .missing_feature => "expected a Feature",
            .multiple_features => "a file may hold only one Feature",
            .misplaced_background => "Background must come first in its Feature or Rule, and only once",
            .step_outside_scenario => "a step needs an enclosing Background or Scenario",
            .table_outside_step => "a table needs a preceding step or Examples",
            .doc_string_outside_step => "a doc string needs a preceding step",
            .multiple_step_arguments => "a step takes at most one argument",
            .conjunction_without_step => "And, But and * need a preceding step",
            .step_after_examples => "steps must come before Examples",
            .unterminated_doc_string => "unterminated doc string",
            .ragged_table_row => "this row has a different cell count from the first",
            .examples_missing_header => "Examples needs a header row",
            .tags_without_target => "tags need a Feature, Rule, Scenario or Examples after them",
            .unexpected_line => "expected a Scenario, Rule, Background or step",
        };
    }
};

test {
    _ = Parser;
    _ = Tokenizer;
}

fn expectDiag(source: []const u8, line: u32, tag: Diagnostic.Tag) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = undefined;
    try std.testing.expectError(
        error.InvalidGherkin,
        parse(arena.allocator(), "t.feature", source, &diag),
    );
    try std.testing.expectEqualStrings("t.feature", diag.path);
    try std.testing.expectEqual(line, diag.line);
    try std.testing.expectEqual(tag, diag.tag);
}

test "feature with a name and a description" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const source =
        \\# a comment
        \\Feature: Calculator
        \\  It adds numbers.
        \\
        \\  Scenario without a colon is description too.
        \\
    ;
    const feature = try parse(arena.allocator(), "calc.feature", source, null);
    try std.testing.expectEqualStrings("calc.feature", feature.path);
    try std.testing.expectEqualStrings("Calculator", feature.name);
    try std.testing.expectEqual(@as(u32, 2), feature.line);
    try std.testing.expectEqualStrings(
        "It adds numbers.\n\n  Scenario without a colon is description too.",
        feature.description,
    );
    try std.testing.expectEqual(@as(usize, 0), feature.scenarios.len);
    try std.testing.expectEqual(@as(usize, 0), feature.rules.len);
    try std.testing.expect(feature.background == null);
}

test "feature with no description" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const feature = try parse(arena.allocator(), "t.feature", "Feature: X\n", null);
    try std.testing.expectEqualStrings("", feature.description);
}

test "missing_feature" {
    try expectDiag("Scenario: too early\n", 1, .missing_feature);
}

test "multiple_features" {
    try expectDiag("Feature: A\nFeature: B\n", 2, .multiple_features);
}

test "scenarios with steps and inheritance" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const source =
        \\Feature: Calculator
        \\
        \\  Scenario: Adding
        \\    Given I have 50
        \\    # a comment between steps
        \\    And I have 70
        \\    When I press add
        \\    But nothing breaks
        \\    Then the result is 120
        \\    * and it is shown
        \\
        \\  Example: Subtracting
        \\    When I press minus
        \\
    ;
    const feature = try parse(arena.allocator(), "t.feature", source, null);
    try std.testing.expectEqual(@as(usize, 2), feature.scenarios.len);

    const adding = feature.scenarios[0];
    try std.testing.expectEqualStrings("Scenario", adding.keyword_text);
    try std.testing.expectEqualStrings("Adding", adding.name);
    try std.testing.expectEqual(@as(u32, 3), adding.line);
    try std.testing.expectEqualDeep(&[_]Step{
        .{ .keyword = .given, .keyword_text = "Given", .text = "I have 50", .argument = null, .line = 4 },
        .{ .keyword = .given, .keyword_text = "And", .text = "I have 70", .argument = null, .line = 6 },
        .{ .keyword = .when, .keyword_text = "When", .text = "I press add", .argument = null, .line = 7 },
        .{ .keyword = .when, .keyword_text = "But", .text = "nothing breaks", .argument = null, .line = 8 },
        .{ .keyword = .then, .keyword_text = "Then", .text = "the result is 120", .argument = null, .line = 9 },
        .{ .keyword = .then, .keyword_text = "*", .text = "and it is shown", .argument = null, .line = 10 },
    }, adding.steps);

    try std.testing.expectEqualStrings("Example", feature.scenarios[1].keyword_text);
    try std.testing.expectEqualStrings("Subtracting", feature.scenarios[1].name);
}

test "scenario descriptions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const source =
        \\Feature: F
        \\  Scenario: S
        \\    why this matters
        \\    Given x
        \\
    ;
    const feature = try parse(arena.allocator(), "t.feature", source, null);
    try std.testing.expectEqualStrings("why this matters", feature.scenarios[0].description);
    try std.testing.expectEqual(@as(usize, 1), feature.scenarios[0].steps.len);
}

test "step_outside_scenario" {
    try expectDiag("Feature: F\n  Given x\n", 2, .step_outside_scenario);
}

test "conjunction_without_step" {
    try expectDiag("Feature: F\n  Scenario: S\n    And x\n", 3, .conjunction_without_step);
}

test "tags on features and scenarios" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const source =
        \\@slow
        \\@math @wip
        \\Feature: F
        \\
        \\  @smoke
        \\  Scenario: S
        \\    Given x
        \\
        \\  Scenario: untagged
        \\    Given y
        \\
    ;
    const feature = try parse(arena.allocator(), "t.feature", source, null);
    try std.testing.expectEqualDeep(
        &[_][]const u8{ "slow", "math", "wip" },
        feature.tags,
    );
    try std.testing.expectEqualDeep(&[_][]const u8{"smoke"}, feature.scenarios[0].tags);
    try std.testing.expectEqual(@as(usize, 0), feature.scenarios[1].tags.len);
}

test "tags_without_target" {
    try expectDiag("Feature: F\n  @orphan\n  Given x\n", 2, .tags_without_target);
    try expectDiag("@orphan\n", 1, .tags_without_target);
}

test "a tagged Rule claims its tags once Rule support exists" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const feature = try parse(
        arena.allocator(),
        "t.feature",
        "Feature: F\n  @nightly\n  Rule: R\n",
        null,
    );
    try std.testing.expectEqualDeep(&[_][]const u8{"nightly"}, feature.rules[0].tags);
    try std.testing.expectEqual(@as(usize, 0), feature.rules[0].scenarios.len);
}

test "background" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const source =
        \\Feature: F
        \\
        \\  Background: shared setup
        \\    the description
        \\    Given a fresh calculator
        \\
        \\  Scenario: S
        \\    Given x
        \\
    ;
    const feature = try parse(arena.allocator(), "t.feature", source, null);
    const bg = feature.background.?;
    try std.testing.expectEqualStrings("shared setup", bg.name);
    try std.testing.expectEqualStrings("the description", bg.description);
    try std.testing.expectEqual(@as(u32, 3), bg.line);
    try std.testing.expectEqual(@as(usize, 1), bg.steps.len);
    try std.testing.expectEqual(@as(usize, 1), feature.scenarios.len);
}

test "misplaced_background" {
    try expectDiag(
        "Feature: F\n  Scenario: S\n    Given x\n  Background:\n    Given y\n",
        4,
        .misplaced_background,
    );
    try expectDiag(
        "Feature: F\n  Background:\n    Given x\n  Background:\n    Given y\n",
        4,
        .misplaced_background,
    );
}

test "data table with escapes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const source =
        \\Feature: F
        \\  Scenario: S
        \\    Given these rows:
        \\      | name  | note      |
        \\      | a\|b  | one\ntwo  |
        \\      | c\\nd | plain     |
        \\
    ;
    const feature = try parse(arena.allocator(), "t.feature", source, null);
    const rows = feature.scenarios[0].steps[0].argument.?.data_table;
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqualDeep(&[_][]const u8{ "name", "note" }, rows[0].cells);
    try std.testing.expectEqualDeep(&[_][]const u8{ "a|b", "one\ntwo" }, rows[1].cells);
    try std.testing.expectEqualDeep(&[_][]const u8{ "c\\nd", "plain" }, rows[2].cells);
    try std.testing.expectEqual(@as(u32, 4), rows[0].line);
}

test "an escaped backslash leaves the next pipe a real separator" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const source =
        \\Feature: F
        \\  Scenario: S
        \\    Given these rows:
        \\      | x    | y | z |
        \\      | a\\|b | c |
        \\
    ;
    const feature = try parse(arena.allocator(), "t.feature", source, null);
    const rows = feature.scenarios[0].steps[0].argument.?.data_table;
    try std.testing.expectEqualDeep(&[_][]const u8{ "x", "y", "z" }, rows[0].cells);
    try std.testing.expectEqualDeep(&[_][]const u8{ "a\\", "b", "c" }, rows[1].cells);
}

test "ragged_table_row" {
    try expectDiag(
        "Feature: F\n  Scenario: S\n    Given x:\n      | a | b |\n      | c |\n",
        5,
        .ragged_table_row,
    );
}

test "table_outside_step" {
    try expectDiag("Feature: F\n  Scenario: S\n    | a |\n", 3, .table_outside_step);
    try expectDiag("Feature: F\n  | a |\n", 2, .table_outside_step);
    try expectDiag(
        "Feature: F\n  Background: B\n    | a |\n\n  Scenario: S\n    Given x\n",
        3,
        .table_outside_step,
    );
}

test "doc string dedent and escapes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const source =
        "Feature: F\n" ++
        "  Scenario: S\n" ++
        "    Given this:\n" ++
        "      \"\"\"json\n" ++
        "      {\n" ++
        "        \"a\": 1\n" ++
        "  outdented\n" ++
        "      Feature: not a keyword\n" ++
        "      \\\"\"\"\n" ++
        "      }\n" ++
        "      \"\"\"\n";
    const feature = try parse(arena.allocator(), "t.feature", source, null);
    const doc = feature.scenarios[0].steps[0].argument.?.doc_string;
    try std.testing.expectEqualStrings("json", doc.media_type.?);
    try std.testing.expectEqual(@as(u32, 4), doc.line);
    try std.testing.expectEqualStrings(
        \\{
        \\  "a": 1
        \\outdented
        \\Feature: not a keyword
        \\"""
        \\}
    , doc.content);
}

test "doc string with a backtick fence and no media type" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const source =
        "Feature: F\n" ++
        "  Scenario: S\n" ++
        "    Given this:\n" ++
        "      ```\n" ++
        "      \"\"\"\n" ++
        "      ```\n";
    const feature = try parse(arena.allocator(), "t.feature", source, null);
    const doc = feature.scenarios[0].steps[0].argument.?.doc_string;
    try std.testing.expect(doc.media_type == null);
    try std.testing.expectEqualStrings("\"\"\"", doc.content);
}

test "empty doc string" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const source =
        "Feature: F\n  Scenario: S\n    Given x:\n      \"\"\"\n      \"\"\"\n";
    const feature = try parse(arena.allocator(), "t.feature", source, null);
    try std.testing.expectEqualStrings(
        "",
        feature.scenarios[0].steps[0].argument.?.doc_string.content,
    );
}

test "doc string body on a CRLF file keeps no carriage returns" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const source =
        "Feature: F\r\n  Scenario: S\r\n    Given x:\r\n" ++
        "      \"\"\"\r\n      one\r\n      two\r\n      \"\"\"\r\n";
    const feature = try parse(arena.allocator(), "t.feature", source, null);
    try std.testing.expectEqualStrings(
        "one\ntwo",
        feature.scenarios[0].steps[0].argument.?.doc_string.content,
    );
}

test "a CRLF file matches its LF twin except in multi-line description spans" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const lf =
        "Feature: F\nfirst line\nsecond line\n\n  Scenario: S\n    Given x\n    And y\n";
    const crlf =
        "Feature: F\r\nfirst line\r\nsecond line\r\n\r\n  Scenario: S\r\n    Given x\r\n    And y\r\n";
    const a = try parse(arena.allocator(), "t.feature", lf, null);
    const b = try parse(arena.allocator(), "t.feature", crlf, null);

    // Everything token-derived is identical across the two encodings.
    try std.testing.expectEqualDeep(a.scenarios[0].steps, b.scenarios[0].steps);
    try std.testing.expectEqualStrings(a.scenarios[0].name, b.scenarios[0].name);

    // The description span is the documented exception: it keeps the source's
    // own line terminators.
    try std.testing.expectEqualStrings("first line\nsecond line", a.description);
    try std.testing.expectEqualStrings("first line\r\nsecond line", b.description);
}

test "unterminated_doc_string" {
    try expectDiag(
        "Feature: F\n  Scenario: S\n    Given x:\n      \"\"\"\n      body\n",
        4,
        .unterminated_doc_string,
    );
}

test "doc_string_outside_step" {
    try expectDiag(
        "Feature: F\n  Scenario: S\n    \"\"\"\n    \"\"\"\n",
        3,
        .doc_string_outside_step,
    );
    try expectDiag("Feature: F\n  \"\"\"\n  \"\"\"\n", 2, .doc_string_outside_step);
}

test "multiple_step_arguments" {
    try expectDiag(
        "Feature: F\n  Scenario: S\n    Given x:\n      | a |\n      \"\"\"\n      \"\"\"\n",
        5,
        .multiple_step_arguments,
    );
}

test "outline with two examples blocks" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const source =
        \\Feature: F
        \\  Scenario Outline: Adding
        \\    When I add <a> and <b>
        \\
        \\    @small
        \\    Examples: little ones
        \\      about small numbers
        \\      | a | b |
        \\      | 1 | 2 |
        \\      | 3 | 4 |
        \\
        \\    Examples:
        \\      | a  | b  |
        \\      | 10 | 20 |
        \\
    ;
    const feature = try parse(arena.allocator(), "t.feature", source, null);
    const outline = feature.scenarios[0];
    try std.testing.expectEqualStrings("Scenario Outline", outline.keyword_text);
    try std.testing.expectEqual(@as(usize, 2), outline.examples.len);

    const little = outline.examples[0];
    try std.testing.expectEqualDeep(&[_][]const u8{"small"}, little.tags);
    try std.testing.expectEqualStrings("little ones", little.name);
    try std.testing.expectEqualStrings("about small numbers", little.description);
    try std.testing.expectEqual(@as(u32, 6), little.line);
    try std.testing.expectEqualDeep(&[_][]const u8{ "a", "b" }, little.header.cells);
    try std.testing.expectEqual(@as(usize, 2), little.rows.len);
    try std.testing.expectEqualDeep(&[_][]const u8{ "3", "4" }, little.rows[1].cells);

    try std.testing.expectEqual(@as(usize, 1), outline.examples[1].rows.len);
}

test "examples under a plain Scenario is a valid outline" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const source =
        \\Feature: F
        \\  Scenario: S
        \\    When I add <a>
        \\    Examples:
        \\      | a |
        \\      | 1 |
        \\
    ;
    const feature = try parse(arena.allocator(), "t.feature", source, null);
    try std.testing.expectEqual(@as(usize, 1), feature.scenarios[0].examples.len);
}

test "examples header with no data rows is legal" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const source =
        "Feature: F\n  Scenario: S\n    When x\n    Examples:\n      | a |\n";
    const feature = try parse(arena.allocator(), "t.feature", source, null);
    try std.testing.expectEqual(@as(usize, 0), feature.scenarios[0].examples[0].rows.len);
}

test "examples_missing_header" {
    try expectDiag(
        "Feature: F\n  Scenario: S\n    When x\n    Examples:\n",
        4,
        .examples_missing_header,
    );
}

test "step_after_examples" {
    try expectDiag(
        "Feature: F\n  Scenario: S\n    When x\n    Examples:\n      | a |\n    Then y\n",
        6,
        .step_after_examples,
    );
}

test "rules with their own backgrounds" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const source =
        \\Feature: F
        \\
        \\  Background:
        \\    Given the feature setup
        \\
        \\  Scenario: bare
        \\    Given x
        \\
        \\  @addition
        \\  Rule: Addition
        \\    only for adding
        \\
        \\    Background:
        \\      Given the rule setup
        \\
        \\    Example: one
        \\      Given a
        \\
        \\    Example: two
        \\      Given b
        \\
        \\  Rule: Subtraction
        \\    Example: three
        \\      Given c
        \\
    ;
    const feature = try parse(arena.allocator(), "t.feature", source, null);
    try std.testing.expectEqual(@as(usize, 1), feature.scenarios.len);
    try std.testing.expectEqual(@as(usize, 2), feature.rules.len);
    try std.testing.expectEqualStrings("the feature setup", feature.background.?.steps[0].text);

    const addition = feature.rules[0];
    try std.testing.expectEqualDeep(&[_][]const u8{"addition"}, addition.tags);
    try std.testing.expectEqualStrings("Addition", addition.name);
    try std.testing.expectEqualStrings("only for adding", addition.description);
    try std.testing.expectEqual(@as(u32, 10), addition.line);
    try std.testing.expectEqualStrings("the rule setup", addition.background.?.steps[0].text);
    try std.testing.expectEqual(@as(usize, 2), addition.scenarios.len);

    const subtraction = feature.rules[1];
    try std.testing.expect(subtraction.background == null);
    try std.testing.expectEqualStrings("", subtraction.description);
    try std.testing.expectEqual(@as(usize, 1), subtraction.scenarios.len);
}

test "an indented Rule is a sibling, not a nesting" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const feature = try parse(
        arena.allocator(),
        "t.feature",
        "Feature: F\n  Rule: A\n    Rule: B\n      Example: x\n        Given y\n",
        null,
    );
    try std.testing.expectEqual(@as(usize, 2), feature.rules.len);
    try std.testing.expectEqualStrings("A", feature.rules[0].name);
    try std.testing.expectEqual(@as(usize, 0), feature.rules[0].scenarios.len);
    try std.testing.expectEqualStrings("B", feature.rules[1].name);
    try std.testing.expectEqual(@as(usize, 1), feature.rules[1].scenarios.len);
}

test "a Scenario after a Rule belongs to that Rule, however it is indented" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const feature = try parse(
        arena.allocator(),
        "t.feature",
        "Feature: F\n  Rule: R\n    Example: inside\n      Given a\nScenario: also_inside\n  Given b\n",
        null,
    );
    try std.testing.expectEqual(@as(usize, 0), feature.scenarios.len);
    try std.testing.expectEqual(@as(usize, 2), feature.rules[0].scenarios.len);
    try std.testing.expectEqualStrings("also_inside", feature.rules[0].scenarios[1].name);
}

test "misplaced_background inside a rule" {
    try expectDiag(
        "Feature: F\n  Rule: A\n    Example: x\n      Given y\n    Background:\n      Given z\n",
        5,
        .misplaced_background,
    );
}

test "unexpected_line" {
    try expectDiag("Feature: F\n  Scenario: S\n    Given x\n    Gvien y\n", 4, .unexpected_line);
    try expectDiag("Feature: F\n  Examples:\n      | a |\n", 2, .unexpected_line);
}

test "diagnostic renders as path, line and message" {
    const diag: Diagnostic = .{
        .path = "features/calc.feature",
        .line = 12,
        .tag = .unterminated_doc_string,
    };
    try std.testing.expectFmt(
        "features/calc.feature:12: unterminated doc string",
        "{f}",
        .{diag},
    );
}

test "every diagnostic tag has a message" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // A copy-pasted arm is the realistic failure, so check distinctness.
    var seen: [32][]const u8 = undefined;
    var count: usize = 0;
    for (std.meta.tags(Diagnostic.Tag)) |tag| {
        const diag: Diagnostic = .{ .path = "t.feature", .line = 1, .tag = tag };
        var buffer: [256]u8 = undefined;
        const rendered = try std.fmt.bufPrint(&buffer, "{f}", .{diag});
        try std.testing.expect(rendered.len > "t.feature:1: ".len);
        const msg = rendered["t.feature:1: ".len..];
        for (seen[0..count]) |prior| try std.testing.expect(!std.mem.eql(u8, prior, msg));
        seen[count] = try arena.allocator().dupe(u8, msg);
        count += 1;
    }
}

test "a full feature file" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const source =
        \\@math
        \\Feature: Calculator
        \\  Everything about adding.
        \\
        \\  Background:
        \\    Given a fresh calculator
        \\
        \\  @smoke
        \\  Scenario: Adding two numbers
        \\    Given I have entered 50
        \\    And I have entered 70
        \\    When I press add
        \\    Then the result is 120
        \\
        \\  Rule: Pasting
        \\    Example: Pasting an expression
        \\      When I paste:
        \\        """
        \\        1 + 2
        \\        """
        \\      Then the result is 3
        \\
        \\    Scenario Outline: Pasting many
        \\      When I paste <text>
        \\      Then the result is <sum>
        \\
        \\      Examples:
        \\        | text  | sum |
        \\        | 1 + 1 | 2   |
        \\        | 2 + 2 | 4   |
        \\
    ;
    const feature = try parse(arena.allocator(), "calc.feature", source, null);

    try std.testing.expectEqualDeep(&[_][]const u8{"math"}, feature.tags);
    try std.testing.expectEqualStrings("Everything about adding.", feature.description);
    try std.testing.expectEqualStrings("a fresh calculator", feature.background.?.steps[0].text);
    try std.testing.expectEqual(@as(usize, 1), feature.scenarios.len);
    try std.testing.expectEqual(@as(usize, 1), feature.rules.len);

    const adding = feature.scenarios[0];
    try std.testing.expectEqualDeep(&[_][]const u8{"smoke"}, adding.tags);
    try std.testing.expectEqual(@as(usize, 4), adding.steps.len);
    try std.testing.expectEqual(Keyword.given, adding.steps[1].keyword);
    try std.testing.expectEqualStrings("And", adding.steps[1].keyword_text);

    const rule = feature.rules[0];
    try std.testing.expectEqualStrings("Pasting", rule.name);
    try std.testing.expectEqual(@as(usize, 2), rule.scenarios.len);
    try std.testing.expectEqualStrings(
        "1 + 2",
        rule.scenarios[0].steps[0].argument.?.doc_string.content,
    );
    try std.testing.expectEqual(Keyword.then, rule.scenarios[0].steps[1].keyword);
    try std.testing.expectEqualStrings("I paste <text>", rule.scenarios[1].steps[0].text);
    try std.testing.expectEqualDeep(
        &[_][]const u8{ "text", "sum" },
        rule.scenarios[1].examples[0].header.cells,
    );
    try std.testing.expectEqualDeep(
        &[_][]const u8{ "1 + 1", "2" },
        rule.scenarios[1].examples[0].rows[0].cells,
    );
    try std.testing.expectEqual(@as(usize, 2), rule.scenarios[1].examples[0].rows.len);
}
