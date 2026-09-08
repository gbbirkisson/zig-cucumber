const std = @import("std");

const Tokenizer = @This();

pub const Keyword = enum { given, when, then };

const block_keywords = std.StaticStringMap(Token.Tag).initComptime(.{
    .{ "Feature", .feature_line },
    .{ "Rule", .rule_line },
    .{ "Background", .background_line },
    .{ "Examples", .examples_line },
    .{ "Scenario", .scenario_line },
    .{ "Scenario Outline", .scenario_line },
    .{ "Example", .scenario_line },
});

const step_keywords = std.StaticStringMap(?Keyword).initComptime(.{
    .{ "Given", .given },
    .{ "When", .when },
    .{ "Then", .then },
    .{ "And", null },
    .{ "But", null },
    .{ "*", null },
});

/// Only valid for a `step_line` token's `keyword`, where `null` means the
/// keyword inherits from the preceding step.
pub fn resolveStepKeyword(keyword_text: []const u8) ?Keyword {
    return step_keywords.get(keyword_text) orelse null;
}

source: []const u8,
index: usize,
line: u32,

pub const Token = struct {
    tag: Tag,
    line: u32,
    indent: u32,
    offset: u32,
    keyword: []const u8,
    text: []const u8,

    pub const Tag = enum {
        tag_line,
        feature_line,
        rule_line,
        background_line,
        scenario_line,
        examples_line,
        step_line,
        table_row,
        docstring_delim,
        comment,
        empty,
        other,
        eof,
    };
};

const bom = "\xEF\xBB\xBF";

pub fn init(source: []const u8) Tokenizer {
    return .{
        .source = source,
        .index = if (std.mem.startsWith(u8, source, bom)) bom.len else 0,
        .line = 1,
    };
}

pub fn next(t: *Tokenizer) Token {
    const line = t.takeLine() orelse return .{
        .tag = .eof,
        .line = t.line,
        .indent = 0,
        .offset = @intCast(t.source.len),
        .keyword = "",
        .text = "",
    };
    return classify(line);
}

pub fn nextRaw(t: *Tokenizer) ?Token {
    const line = t.takeLine() orelse return null;
    const indent = indentOf(line.text);
    return .{
        .tag = .other,
        .line = line.number,
        .indent = indent,
        .offset = line.start + indent,
        .keyword = "",
        .text = line.text,
    };
}

const Line = struct {
    text: []const u8,
    start: u32,
    number: u32,
};

fn takeLine(t: *Tokenizer) ?Line {
    if (t.index >= t.source.len) return null;
    const start = t.index;
    const end = std.mem.findScalarPos(u8, t.source, start, '\n') orelse t.source.len;
    t.index = if (end < t.source.len) end + 1 else end;
    defer t.line += 1;
    return .{
        .text = std.mem.trimEnd(u8, t.source[start..end], "\r"),
        .start = @intCast(start),
        .number = t.line,
    };
}

fn indentOf(text: []const u8) u32 {
    return @intCast(std.mem.findNone(u8, text, &std.ascii.whitespace) orelse text.len);
}

fn classify(line: Line) Token {
    const rest = std.mem.trim(u8, line.text, &std.ascii.whitespace);
    const indent = indentOf(line.text);
    var tok: Token = .{
        .tag = .other,
        .line = line.number,
        .indent = indent,
        .offset = line.start + indent,
        .keyword = "",
        .text = rest,
    };

    if (rest.len == 0) {
        tok.tag = .empty;
        return tok;
    }

    switch (rest[0]) {
        '#' => {
            tok.tag = .comment;
            tok.keyword = rest[0..1];
            tok.text = std.mem.trim(u8, rest[1..], &std.ascii.whitespace);
        },
        '@' => {
            tok.tag = .tag_line;
            tok.keyword = rest[0..1];
        },
        '|' => {
            tok.tag = .table_row;
            tok.keyword = rest[0..1];
        },
        '"', '`' => {
            if (rest.len >= 3 and rest[1] == rest[0] and rest[2] == rest[0]) {
                tok.tag = .docstring_delim;
                tok.keyword = rest[0..3];
                tok.text = std.mem.trim(u8, rest[3..], &std.ascii.whitespace);
            }
        },
        else => {},
    }

    if (tok.tag != .other) return tok;

    if (std.mem.findScalar(u8, rest, ':')) |colon| {
        const prefix = std.mem.trim(u8, rest[0..colon], &std.ascii.whitespace);
        if (block_keywords.get(prefix)) |tag| {
            tok.tag = tag;
            tok.keyword = prefix;
            tok.text = std.mem.trim(u8, rest[colon + 1 ..], &std.ascii.whitespace);
            return tok;
        }
    }

    const space = std.mem.findScalar(u8, rest, ' ') orelse rest.len;
    if (space < rest.len and step_keywords.has(rest[0..space])) {
        tok.tag = .step_line;
        tok.keyword = rest[0..space];
        tok.text = std.mem.trim(u8, rest[space..], &std.ascii.whitespace);
    }
    return tok;
}

test "sigil lines" {
    const source =
        \\
        \\# a comment
        \\@smoke @math
        \\  | a | b |
        \\"""json
        \\```
        \\
    ;
    var t: Tokenizer = .init(source);

    try std.testing.expectEqual(Token.Tag.empty, t.next().tag);

    const comment = t.next();
    try std.testing.expectEqual(Token.Tag.comment, comment.tag);
    try std.testing.expectEqualStrings("a comment", comment.text);
    try std.testing.expectEqual(@as(u32, 2), comment.line);

    const tags = t.next();
    try std.testing.expectEqual(Token.Tag.tag_line, tags.tag);
    try std.testing.expectEqualStrings("@smoke @math", tags.text);

    const row = t.next();
    try std.testing.expectEqual(Token.Tag.table_row, row.tag);
    try std.testing.expectEqualStrings("| a | b |", row.text);
    try std.testing.expectEqual(@as(u32, 2), row.indent);
    try std.testing.expectEqual(@as(u32, 4), row.line);

    const doc = t.next();
    try std.testing.expectEqual(Token.Tag.docstring_delim, doc.tag);
    try std.testing.expectEqualStrings("\"\"\"", doc.keyword);
    try std.testing.expectEqualStrings("json", doc.text);

    const fence = t.next();
    try std.testing.expectEqual(Token.Tag.docstring_delim, fence.tag);
    try std.testing.expectEqualStrings("```", fence.keyword);
    try std.testing.expectEqualStrings("", fence.text);

    try std.testing.expectEqual(Token.Tag.eof, t.next().tag);
    try std.testing.expectEqual(Token.Tag.eof, t.next().tag);
}

test "offset points at the trimmed line" {
    const source = "Feature: x\n    hello\n";
    var t: Tokenizer = .init(source);
    _ = t.next();
    const other = t.next();
    try std.testing.expectEqual(@as(u32, 15), other.offset);
    try std.testing.expectEqualStrings("hello", source[other.offset..][0..5]);
}

test "a leading BOM is skipped" {
    var t: Tokenizer = .init("\xEF\xBB\xBFhello world\n");
    const tok = t.next();
    try std.testing.expectEqual(@as(u32, 1), tok.line);
    try std.testing.expectEqualStrings("hello world", tok.text);
}

test "CRLF and a missing trailing newline" {
    var t: Tokenizer = .init("| a |\r\n| b |");
    try std.testing.expectEqualStrings("| a |", t.next().text);
    try std.testing.expectEqualStrings("| b |", t.next().text);
    try std.testing.expectEqual(Token.Tag.eof, t.next().tag);
}

test "block keywords" {
    const source =
        \\Feature: Calculator
        \\Rule: Addition
        \\  Background:
        \\  Scenario: Adding
        \\  Scenario Outline: Adding many
        \\  Example: Adding once
        \\    Examples:
        \\
    ;
    var t: Tokenizer = .init(source);

    const feature = t.next();
    try std.testing.expectEqual(Token.Tag.feature_line, feature.tag);
    try std.testing.expectEqualStrings("Feature", feature.keyword);
    try std.testing.expectEqualStrings("Calculator", feature.text);

    try std.testing.expectEqual(Token.Tag.rule_line, t.next().tag);

    const background = t.next();
    try std.testing.expectEqual(Token.Tag.background_line, background.tag);
    try std.testing.expectEqualStrings("", background.text);

    const scenario = t.next();
    try std.testing.expectEqual(Token.Tag.scenario_line, scenario.tag);
    try std.testing.expectEqualStrings("Scenario", scenario.keyword);

    const outline = t.next();
    try std.testing.expectEqual(Token.Tag.scenario_line, outline.tag);
    try std.testing.expectEqualStrings("Scenario Outline", outline.keyword);

    const example = t.next();
    try std.testing.expectEqual(Token.Tag.scenario_line, example.tag);
    try std.testing.expectEqualStrings("Example", example.keyword);

    const examples = t.next();
    try std.testing.expectEqual(Token.Tag.examples_line, examples.tag);
    try std.testing.expectEqualStrings("Examples", examples.keyword);
}

test "step keywords" {
    const source =
        \\Given I have 50
        \\When I press add
        \\Then the result is 120
        \\And another
        \\But not this
        \\* a bullet
        \\
    ;
    var t: Tokenizer = .init(source);

    const given = t.next();
    try std.testing.expectEqual(Token.Tag.step_line, given.tag);
    try std.testing.expectEqualStrings("Given", given.keyword);
    try std.testing.expectEqualStrings("I have 50", given.text);
    try std.testing.expectEqual(Keyword.given, resolveStepKeyword(given.keyword).?);

    try std.testing.expectEqual(Keyword.when, resolveStepKeyword(t.next().keyword).?);
    try std.testing.expectEqual(Keyword.then, resolveStepKeyword(t.next().keyword).?);

    for ([_][]const u8{ "And", "But", "*" }) |expected| {
        const tok = t.next();
        try std.testing.expectEqual(Token.Tag.step_line, tok.tag);
        try std.testing.expectEqualStrings(expected, tok.keyword);
        try std.testing.expect(resolveStepKeyword(tok.keyword) == null);
    }
}

test "keyword lookalikes are other" {
    const source =
        \\Givens are nice
        \\Rules are nice
        \\Scenario without a colon
        \\Given
        \\Note: not a keyword
        \\
    ;
    var t: Tokenizer = .init(source);
    for (0..5) |_| {
        try std.testing.expectEqual(Token.Tag.other, t.next().tag);
    }
}

test "a colon in step text does not misfire" {
    var t: Tokenizer = .init("Given a: b\n");
    const tok = t.next();
    try std.testing.expectEqual(Token.Tag.step_line, tok.tag);
    try std.testing.expectEqualStrings("Given", tok.keyword);
    try std.testing.expectEqualStrings("a: b", tok.text);
}

test "Examples is not Example" {
    var t: Tokenizer = .init("Examples:\nExample:\n");
    try std.testing.expectEqual(Token.Tag.examples_line, t.next().tag);
    try std.testing.expectEqual(Token.Tag.scenario_line, t.next().tag);
}

test "nextRaw does not interpret" {
    var t: Tokenizer = .init("  Feature: x\n  \"\"\"\n");
    const raw = t.nextRaw().?;
    try std.testing.expectEqual(Token.Tag.other, raw.tag);
    try std.testing.expectEqualStrings("  Feature: x", raw.text);
    try std.testing.expectEqual(@as(u32, 2), raw.indent);
    try std.testing.expect(t.nextRaw() != null);
    try std.testing.expect(t.nextRaw() == null);
}
