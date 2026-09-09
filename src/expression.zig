const std = @import("std");

pub const Capture = union(enum) {
    int,
    float,
    word,
    string,
    anything,
    custom: []const u8,
};

pub const Segment = union(enum) {
    literal: []const u8,
    capture: Capture,
};

/// One expansion of a pattern, with optional groups and alternations resolved.
pub const Alternative = []const Segment;

pub const CompileError = error{
    StrayBackslash,
    UnterminatedCapture,
    UnterminatedOptional,
    EmptyGroup,
    IllegalGroupContent,
    TooManyAlternatives,
};

pub const max_alternatives: usize = 64;

/// A pattern part before expansion. `choice` holds literal options, which for
/// an optional group includes the empty string.
const Part = union(enum) {
    fixed: Segment,
    choice: []const []const u8,
};

const builtin_captures = std.StaticStringMap(Capture).initComptime(.{
    .{ "int", .int },
    .{ "float", .float },
    .{ "word", .word },
    .{ "string", .string },
    .{ "", .anything },
});

/// The byte an escape starting at `pattern[i]` stands for.
fn escaped(comptime pattern: []const u8, comptime i: usize) CompileError!u8 {
    if (i + 1 >= pattern.len) return CompileError.StrayBackslash;
    const c = pattern[i + 1];
    if (c != '(' and c != '{' and c != '/' and c != '\\') return CompileError.StrayBackslash;
    return c;
}

fn isBoundary(c: u8) bool {
    return std.ascii.isWhitespace(c) or c == '/' or c == '{' or c == '(';
}

fn parseParts(comptime pattern: []const u8) CompileError![]const Part {
    var out: []const Part = &.{};
    var lit: []const u8 = "";
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) switch (pattern[i]) {
        '\\' => {
            lit = lit ++ [_]u8{try escaped(pattern, i)};
            i += 1;
        },
        '{' => {
            if (lit.len > 0) {
                out = out ++ [_]Part{.{ .fixed = .{ .literal = lit } }};
                lit = "";
            }
            const close = std.mem.findScalarPos(u8, pattern, i, '}') orelse
                return CompileError.UnterminatedCapture;
            const name = pattern[i + 1 .. close];
            out = out ++ [_]Part{.{ .fixed = .{
                .capture = builtin_captures.get(name) orelse Capture{ .custom = name },
            } }};
            i = close;
        },
        '(' => {
            if (lit.len > 0) {
                out = out ++ [_]Part{.{ .fixed = .{ .literal = lit } }};
                lit = "";
            }
            const close = std.mem.findScalarPos(u8, pattern, i, ')') orelse
                return CompileError.UnterminatedOptional;
            const inner = pattern[i + 1 .. close];
            if (inner.len == 0) return CompileError.EmptyGroup;
            for (inner) |c| if (std.mem.findScalar(u8, "{}()/\\", c) != null)
                return CompileError.IllegalGroupContent;
            out = out ++ [_]Part{.{ .choice = &[_][]const u8{ "", inner } }};
            i = close;
        },
        '/' => {
            var cut = lit.len;
            while (cut > 0 and !std.ascii.isWhitespace(lit[cut - 1])) cut -= 1;
            if (lit[cut..].len == 0) return CompileError.EmptyGroup;
            if (cut > 0) out = out ++ [_]Part{.{ .fixed = .{ .literal = lit[0..cut] } }};
            var options: []const []const u8 = &[_][]const u8{lit[cut..]};
            lit = "";
            var j = i;
            while (j < pattern.len and pattern[j] == '/') {
                var opt: []const u8 = "";
                var k = j + 1;
                while (k < pattern.len and !isBoundary(pattern[k])) {
                    if (pattern[k] == '\\') {
                        opt = opt ++ [_]u8{try escaped(pattern, k)};
                        k += 2;
                        continue;
                    }
                    opt = opt ++ pattern[k .. k + 1];
                    k += 1;
                }
                if (opt.len == 0) return CompileError.EmptyGroup;
                options = options ++ [_][]const u8{opt};
                j = k;
            }
            out = out ++ [_]Part{.{ .choice = options }};
            i = j - 1;
        },
        else => lit = lit ++ pattern[i .. i + 1],
    };
    if (lit.len > 0) out = out ++ [_]Part{.{ .fixed = .{ .literal = lit } }};
    return out;
}

fn expand(comptime parts: []const Part) CompileError![]const Alternative {
    var alts: []const Alternative = &[_]Alternative{&.{}};
    for (parts) |part| switch (part) {
        .fixed => |seg| {
            var next: []const Alternative = &.{};
            for (alts) |alt| next = next ++ [_]Alternative{alt ++ [_]Segment{seg}};
            alts = next;
        },
        .choice => |opts| {
            var next: []const Alternative = &.{};
            for (alts) |alt| for (opts) |opt| {
                next = next ++ [_]Alternative{
                    if (opt.len == 0) alt else alt ++ [_]Segment{.{ .literal = opt }},
                };
            };
            if (next.len > max_alternatives) return CompileError.TooManyAlternatives;
            alts = next;
        },
    };

    var merged: []const Alternative = &.{};
    for (alts) |alt| {
        var segs: []const Segment = &.{};
        for (alt) |seg| {
            if (segs.len > 0 and seg == .literal and segs[segs.len - 1] == .literal) {
                segs = segs[0 .. segs.len - 1] ++ [_]Segment{
                    .{ .literal = segs[segs.len - 1].literal ++ seg.literal },
                };
            } else segs = segs ++ [_]Segment{seg};
        }
        merged = merged ++ [_]Alternative{segs};
    }
    return merged;
}

pub fn compile(comptime pattern: []const u8) CompileError![]const Alternative {
    @setEvalBranchQuota(1_000_000);
    return expand(try parseParts(pattern));
}

pub const CustomType = struct {
    name: []const u8,
    alternatives: []const []const u8,
};

/// The captured text for each capture, in order, or null when nothing matches.
/// Every alternative of one pattern has the same capture sequence, because a
/// capture inside a group is a compile error, so the caller can bind the result
/// positionally without knowing which alternative matched.
pub fn match(
    comptime alternatives: []const Alternative,
    comptime custom: []const CustomType,
    comptime text: []const u8,
) ?[]const []const u8 {
    @setEvalBranchQuota(1_000_000);
    for (alternatives) |alt| {
        if (matchSegments(alt, custom, text)) |caps| return caps;
    }
    return null;
}

fn matchSegments(
    comptime segs: []const Segment,
    comptime custom: []const CustomType,
    comptime text: []const u8,
) ?[]const []const u8 {
    if (segs.len == 0) return if (text.len == 0) &.{} else null;
    switch (segs[0]) {
        .literal => |lit| {
            if (!std.mem.startsWith(u8, text, lit)) return null;
            return matchSegments(segs[1..], custom, text[lit.len..]);
        },
        .capture => |cap| {
            var len = maxCapture(cap, custom, text) + 1;
            while (len > 0) {
                len -= 1;
                if (!validCapture(cap, custom, text[0..len])) continue;
                if (matchSegments(segs[1..], custom, text[len..])) |rest| {
                    return &[_][]const u8{text[0..len]} ++ rest;
                }
            }
            return null;
        },
    }
}

/// The first declared type with this name, or null.
fn findCustom(comptime custom: []const CustomType, comptime name: []const u8) ?CustomType {
    for (custom) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

/// The length of the quoted run starting at `text[0]`, including both quotes,
/// or 0 if there is none. A backslash escapes the byte after it.
fn stringRun(comptime text: []const u8) usize {
    if (text.len < 2) return 0;
    const quote = text[0];
    if (quote != '"' and quote != '\'') return 0;
    var i: usize = 1;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\') {
            i += 1;
            continue;
        }
        if (text[i] == quote) return i + 1;
    }
    return 0;
}

/// The longest prefix of `text` this capture could consume. Trying lengths down
/// from here is what gives the matcher its backtracking.
fn maxCapture(
    comptime cap: Capture,
    comptime custom: []const CustomType,
    comptime text: []const u8,
) usize {
    return switch (cap) {
        .int => blk: {
            var i: usize = 0;
            if (i < text.len and text[i] == '-') i += 1;
            while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
            break :blk i;
        },
        .float => blk: {
            var i: usize = 0;
            var seen_dot = false;
            if (i < text.len and text[i] == '-') i += 1;
            while (i < text.len) : (i += 1) {
                if (std.ascii.isDigit(text[i])) continue;
                if (text[i] == '.' and !seen_dot) {
                    seen_dot = true;
                    continue;
                }
                break;
            }
            break :blk i;
        },
        .word => blk: {
            var i: usize = 0;
            while (i < text.len and !std.ascii.isWhitespace(text[i])) i += 1;
            break :blk i;
        },
        .string => stringRun(text),
        .anything => text.len,
        .custom => |name| blk: {
            const t = findCustom(custom, name) orelse break :blk 0;
            var longest: usize = 0;
            for (t.alternatives) |alt| {
                if (alt.len > longest and alt.len <= text.len) longest = alt.len;
            }
            break :blk longest;
        },
    };
}

fn validCapture(
    comptime cap: Capture,
    comptime custom: []const CustomType,
    comptime text: []const u8,
) bool {
    return switch (cap) {
        .int => hasDigit(text),
        .float => hasDigit(text),
        .word => text.len > 0,
        .string => text.len >= 2 and stringRun(text) == text.len,
        .anything => true,
        .custom => |name| blk: {
            const t = findCustom(custom, name) orelse break :blk false;
            for (t.alternatives) |alt| {
                if (std.mem.eql(u8, alt, text)) break :blk true;
            }
            break :blk false;
        },
    };
}

fn hasDigit(comptime text: []const u8) bool {
    for (text) |c| if (std.ascii.isDigit(c)) return true;
    return false;
}

test "a pattern of only literal text" {
    const alts = comptime try compile("I press add");
    try std.testing.expectEqualDeep(
        &[_]Alternative{&[_]Segment{.{ .literal = "I press add" }}},
        alts,
    );
}

test "captures between literals" {
    const alts = comptime try compile("add {int} and {float}");
    try std.testing.expectEqualDeep(&[_]Alternative{&[_]Segment{
        .{ .literal = "add " },
        .{ .capture = .int },
        .{ .literal = " and " },
        .{ .capture = .float },
    }}, alts);
}

test "every builtin capture name, and an unknown one becomes custom" {
    const alts = comptime try compile("{int}{float}{word}{string}{}{Colour}");
    try std.testing.expectEqualDeep(&[_]Alternative{&[_]Segment{
        .{ .capture = .int },
        .{ .capture = .float },
        .{ .capture = .word },
        .{ .capture = .string },
        .{ .capture = .anything },
        .{ .capture = .{ .custom = "Colour" } },
    }}, alts);
}

test "a capture at each end" {
    const alts = comptime try compile("{int} plus {int}");
    try std.testing.expectEqual(@as(usize, 3), alts[0].len);
    try std.testing.expectEqualDeep(Segment{ .capture = .int }, alts[0][0]);
    try std.testing.expectEqualDeep(Segment{ .capture = .int }, alts[0][2]);
}

test "escaped delimiters become literal text" {
    const alts = comptime try compile(
        "literal \\{what} and \\(paren) and a\\/b and back\\\\slash",
    );
    try std.testing.expectEqualDeep(
        &[_]Alternative{&[_]Segment{
            .{ .literal = "literal {what} and (paren) and a/b and back\\slash" },
        }},
        alts,
    );
}

test "an escaped brace does not open a capture" {
    const alts = comptime try compile("\\{int}");
    try std.testing.expectEqual(@as(usize, 1), alts[0].len);
    try std.testing.expectEqualStrings("{int}", alts[0][0].literal);
}

test "malformed patterns" {
    try std.testing.expectError(CompileError.StrayBackslash, comptime compile("bad\\"));
    try std.testing.expectError(CompileError.StrayBackslash, comptime compile("a\\zb"));
    try std.testing.expectError(CompileError.UnterminatedCapture, comptime compile("a {int"));
}

/// Renders an alternative as text, with each capture shown as `<>`, so a whole
/// expansion can be asserted on one line.
fn render(comptime alt: Alternative) []const u8 {
    comptime var out: []const u8 = "";
    inline for (alt) |seg| out = out ++ switch (seg) {
        .literal => |l| l,
        .capture => "<>",
    };
    return out;
}

test "Cucumber's canonical example expands to four alternatives" {
    const alts = comptime try compile("I have {int} cucumber(s) in my belly/stomach");
    try std.testing.expectEqual(@as(usize, 4), alts.len);
    try std.testing.expectEqualStrings("I have <> cucumber in my belly", comptime render(alts[0]));
    try std.testing.expectEqualStrings("I have <> cucumber in my stomach", comptime render(alts[1]));
    try std.testing.expectEqualStrings("I have <> cucumbers in my belly", comptime render(alts[2]));
    try std.testing.expectEqualStrings("I have <> cucumbers in my stomach", comptime render(alts[3]));
}

test "an optional group alone" {
    const alts = comptime try compile("I press the button(s)");
    try std.testing.expectEqual(@as(usize, 2), alts.len);
    try std.testing.expectEqualStrings("I press the button", comptime render(alts[0]));
    try std.testing.expectEqualStrings("I press the buttons", comptime render(alts[1]));
}

test "three-way alternation" {
    const alts = comptime try compile("I click/tap/press it");
    try std.testing.expectEqual(@as(usize, 3), alts.len);
    try std.testing.expectEqualStrings("I click it", comptime render(alts[0]));
    try std.testing.expectEqualStrings("I tap it", comptime render(alts[1]));
    try std.testing.expectEqualStrings("I press it", comptime render(alts[2]));
}

test "adjacent literals are merged into one segment" {
    const alts = comptime try compile("a(b)c");
    try std.testing.expectEqual(@as(usize, 1), alts[0].len);
    try std.testing.expectEqualStrings("ac", alts[0][0].literal);
    try std.testing.expectEqual(@as(usize, 1), alts[1].len);
    try std.testing.expectEqualStrings("abc", alts[1][0].literal);
}

test "an escaped slash does not start an alternation" {
    const alts = comptime try compile("either\\/or");
    try std.testing.expectEqual(@as(usize, 1), alts.len);
    try std.testing.expectEqualStrings("either/or", alts[0][0].literal);
}

test "an alternation option may not be empty" {
    try std.testing.expectError(CompileError.EmptyGroup, comptime compile("/a"));
    try std.testing.expectError(CompileError.EmptyGroup, comptime compile("a /b"));
    try std.testing.expectError(CompileError.EmptyGroup, comptime compile("(x)/y"));
    try std.testing.expectError(CompileError.EmptyGroup, comptime compile("a {int}/b"));
    try std.testing.expectError(CompileError.EmptyGroup, comptime compile("I press ok(s)/cancel"));
}

test "an escaped slash inside a later alternation option stays literal" {
    const alts = comptime try compile("a/b\\/c");
    try std.testing.expectEqual(@as(usize, 2), alts.len);
    try std.testing.expectEqualStrings("a", comptime render(alts[0]));
    try std.testing.expectEqualStrings("b/c", comptime render(alts[1]));
    try std.testing.expectError(CompileError.StrayBackslash, comptime compile("a/b\\zc"));
    try std.testing.expectError(CompileError.StrayBackslash, comptime compile("a/b\\"));
}

test "group errors" {
    try std.testing.expectError(CompileError.UnterminatedOptional, comptime compile("a (s"));
    try std.testing.expectError(CompileError.EmptyGroup, comptime compile("a ()"));
    try std.testing.expectError(CompileError.IllegalGroupContent, comptime compile("a ({int})"));
    try std.testing.expectError(CompileError.EmptyGroup, comptime compile("a/"));
}

test "the alternative cap" {
    // Six optional groups is exactly 64 expansions, which is allowed.
    try std.testing.expectEqual(
        @as(usize, 64),
        (comptime try compile("a(1)b(2)c(3)d(4)e(5)f(6)")).len,
    );
    // Seven is 128, past the cap.
    try std.testing.expectError(
        CompileError.TooManyAlternatives,
        comptime compile("a(1)b(2)c(3)d(4)e(5)f(6)g(7)"),
    );
}

test "matching a literal-only pattern" {
    const alts = comptime try compile("I press add");
    try std.testing.expectEqual(@as(usize, 0), (comptime match(alts, &.{}, "I press add").?).len);
    try std.testing.expect(comptime match(alts, &.{}, "I press subtract") == null);
    try std.testing.expect(comptime match(alts, &.{}, "I press add twice") == null);
}

test "int capture, including a negative" {
    const alts = comptime try compile("add {int} and {int}");
    const caps = comptime match(alts, &.{}, "add -19 and 71").?;
    try std.testing.expectEqualDeep(&[_][]const u8{ "-19", "71" }, caps);
    try std.testing.expect(comptime match(alts, &.{}, "add x and 71") == null);
}

test "float capture accepts the forms Cucumber accepts" {
    const alts = comptime try compile("value {float}");
    try std.testing.expectEqualStrings("3.6", (comptime match(alts, &.{}, "value 3.6").?)[0]);
    try std.testing.expectEqualStrings(".8", (comptime match(alts, &.{}, "value .8").?)[0]);
    try std.testing.expectEqualStrings("-9.2", (comptime match(alts, &.{}, "value -9.2").?)[0]);
    try std.testing.expectEqualStrings("3", (comptime match(alts, &.{}, "value 3").?)[0]);
}

test "word capture backtracks off a following literal" {
    const alts = comptime try compile("I click {word}!");
    const caps = comptime match(alts, &.{}, "I click save!").?;
    try std.testing.expectEqualStrings("save", caps[0]);
}

test "a word capture will not span whitespace" {
    const alts = comptime try compile("I click {word}");
    try std.testing.expect(comptime match(alts, &.{}, "I click two words") == null);
}

test "matching picks the first alternative that fits" {
    const alts = comptime try compile("I have {int} cucumber(s)");
    try std.testing.expectEqualStrings("1", (comptime match(alts, &.{}, "I have 1 cucumber").?)[0]);
    try std.testing.expectEqualStrings("2", (comptime match(alts, &.{}, "I have 2 cucumbers").?)[0]);
}

test "a string capture accepts either quote kind" {
    const alts = comptime try compile("I type {string}");
    try std.testing.expectEqualStrings(
        "\"hello\"",
        (comptime match(alts, &.{}, "I type \"hello\"").?)[0],
    );
    try std.testing.expectEqualStrings(
        "'hello'",
        (comptime match(alts, &.{}, "I type 'hello'").?)[0],
    );
}

test "a string capture keeps its quotes, so the caller can unquote once" {
    const alts = comptime try compile("say {string} twice");
    const caps = comptime match(alts, &.{}, "say \"a b\" twice").?;
    try std.testing.expectEqualStrings("\"a b\"", caps[0]);
}

test "unquoted text is not a string capture" {
    const alts = comptime try compile("I type {string}");
    try std.testing.expect(comptime match(alts, &.{}, "I type hello") == null);
}

test "anything is greedy, matching Cucumber's dot-star" {
    const alts = comptime try compile("{} end");
    const caps = comptime match(alts, &.{}, "a end b end").?;
    try std.testing.expectEqualStrings("a end b", caps[0]);
}

test "anything can match an empty run" {
    const alts = comptime try compile("[{}]");
    try std.testing.expectEqualStrings("", (comptime match(alts, &.{}, "[]").?)[0]);
}

test "two anything captures in one pattern" {
    const alts = comptime try compile("{} and {}");
    const caps = comptime match(alts, &.{}, "x and y and z").?;
    try std.testing.expectEqualStrings("x and y", caps[0]);
    try std.testing.expectEqualStrings("z", caps[1]);
}

test "an escaped quote inside a string capture is kept, not treated as the end" {
    const alts = comptime try compile("I type {string}");
    try std.testing.expectEqualStrings(
        "\"a\\\"b\"",
        (comptime match(alts, &.{}, "I type \"a\\\"b\"").?)[0],
    );
}

test "backtracking never splits a string capture at an escaped quote" {
    const alts = comptime try compile("{string}\"");
    try std.testing.expect(comptime match(alts, &.{}, "\"\\\"\"") == null);
}

const colours = [_]CustomType{.{
    .name = "Colour",
    .alternatives = &[_][]const u8{ "red", "green", "blue" },
}};

test "a custom capture matches one of its alternatives" {
    const alts = comptime try compile("I pick {Colour}");
    try std.testing.expectEqualStrings(
        "green",
        (comptime match(alts, &colours, "I pick green").?)[0],
    );
    try std.testing.expect(comptime match(alts, &colours, "I pick mauve") == null);
}

test "an unresolved name never matches, and a later one still resolves" {
    const alts = comptime try compile("I pick {Colour}");
    try std.testing.expect(comptime match(alts, &.{}, "I pick red") == null);

    const sizes = [_]CustomType{.{
        .name = "Size",
        .alternatives = &[_][]const u8{"small"},
    }};
    try std.testing.expect(comptime match(alts, &sizes, "I pick red") == null);

    const both = sizes ++ colours;
    try std.testing.expectEqualStrings(
        "red",
        (comptime match(alts, &both, "I pick red").?)[0],
    );
}

test "the longest alternative wins" {
    const shades = [_]CustomType{.{
        .name = "Shade",
        .alternatives = &[_][]const u8{ "red", "red_dark" },
    }};
    const alts = comptime try compile("{Shade} it");
    try std.testing.expectEqualStrings(
        "red_dark",
        (comptime match(alts, &shades, "red_dark it").?)[0],
    );
}

test "a custom capture beside a literal" {
    const alts = comptime try compile("paint {Colour} now");
    const caps = comptime match(alts, &colours, "paint blue now").?;
    try std.testing.expectEqualStrings("blue", caps[0]);
}
