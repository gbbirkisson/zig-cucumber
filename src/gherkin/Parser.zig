const std = @import("std");
const Allocator = std.mem.Allocator;

const gherkin = @import("../gherkin.zig");
const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;
const Diagnostic = gherkin.Diagnostic;
const Error = gherkin.Error;

const Parser = @This();

arena: Allocator,
path: []const u8,
source: []const u8,
tokenizer: Tokenizer,
peeked: ?Token,
diag: ?*Diagnostic,
pending: std.ArrayList([]const u8) = .empty,
pending_line: u32 = 0,

pub fn parse(
    arena: Allocator,
    path: []const u8,
    source: []const u8,
    diag: ?*Diagnostic,
) Error!gherkin.Feature {
    var p: Parser = .{
        .arena = arena,
        .path = path,
        .source = source,
        .tokenizer = .init(source),
        .peeked = null,
        .diag = diag,
    };
    return p.feature();
}

fn advance(p: *Parser) Token {
    if (p.peeked) |tok| {
        p.peeked = null;
        return tok;
    }
    return p.tokenizer.next();
}

/// Next token, skipping comments and blank lines. They are never significant
/// outside a doc string body, which uses `Tokenizer.nextRaw` instead.
fn peek(p: *Parser) Token {
    while (true) {
        const tok = if (p.peeked) |t| t else p.tokenizer.next();
        p.peeked = tok;
        switch (tok.tag) {
            .comment, .empty => p.peeked = null,
            else => return tok,
        }
    }
}

fn fail(p: *Parser, tag: Diagnostic.Tag, line: u32) error{InvalidGherkin} {
    if (p.diag) |d| d.* = .{ .path = p.path, .line = line, .tag = tag };
    return error.InvalidGherkin;
}

/// Reads any tag lines into `pending`, where they wait for whichever construct
/// follows to claim them. Leaving unclaimed tags buffered is what lets
/// `scenarios` stop at a tagged `Rule:` without stealing its tags.
fn bufferTags(p: *Parser) Error!void {
    while (p.peek().tag == .tag_line) {
        const tok = p.advance();
        if (p.pending_line == 0) p.pending_line = tok.line;
        var it = std.mem.tokenizeAny(u8, tok.text, &std.ascii.whitespace);
        while (it.next()) |word| {
            try p.pending.append(p.arena, std.mem.trimStart(u8, word, "@"));
        }
    }
}

fn takePending(p: *Parser) []const []const u8 {
    const claimed = p.pending.items;
    // Resetting to .empty rather than clearing keeps the returned slice valid:
    // the next append allocates fresh.
    p.pending = .empty;
    p.pending_line = 0;
    return claimed;
}

fn feature(p: *Parser) Error!gherkin.Feature {
    try p.bufferTags();
    const head = p.peek();
    if (head.tag != .feature_line) {
        if (p.pending.items.len != 0) return p.fail(.tags_without_target, p.pending_line);
        return p.fail(.missing_feature, head.line);
    }
    _ = p.advance();
    const desc = p.description();

    var result: gherkin.Feature = .{
        .path = p.path,
        .tags = p.takePending(),
        .name = head.text,
        .description = desc,
        .background = null,
        .scenarios = &.{},
        .rules = &.{},
        .line = head.line,
    };

    result.background = try p.background();
    result.scenarios = try p.scenarios();
    result.rules = try p.rules();

    if (p.pending.items.len != 0) return p.fail(.tags_without_target, p.pending_line);

    const trailing = p.peek();
    switch (trailing.tag) {
        .eof => {},
        .feature_line => return p.fail(.multiple_features, trailing.line),
        .background_line => return p.fail(.misplaced_background, trailing.line),
        .step_line => return p.fail(.step_outside_scenario, trailing.line),
        .table_row => return p.fail(.table_outside_step, trailing.line),
        .docstring_delim => return p.fail(.doc_string_outside_step, trailing.line),
        else => return p.fail(.unexpected_line, trailing.line),
    }
    return result;
}

/// The run of `other` tokens after a block keyword, as one source slice from
/// the first to the last. Blank lines and comments inside are kept verbatim
/// because the slice spans them.
fn description(p: *Parser) []const u8 {
    var start: ?u32 = null;
    var end: u32 = 0;
    while (p.peek().tag == .other) {
        const tok = p.advance();
        if (start == null) start = tok.offset;
        end = tok.offset + @as(u32, @intCast(tok.text.len));
    }
    const from = start orelse return "";
    return p.source[from..end];
}

/// Buffers any tag lines, then claims the head token only if it opens `tag`.
/// Unclaimed tags stay buffered for whatever construct owns them, which is what
/// lets `scenarios` stop at a tagged `Rule:` without stealing its tags.
fn openBlock(p: *Parser, tag: Token.Tag) Error!?Token {
    try p.bufferTags();
    if (p.peek().tag != tag) return null;
    return p.advance();
}

fn scenarios(p: *Parser) Error![]const gherkin.Scenario {
    var list: std.ArrayList(gherkin.Scenario) = .empty;
    while (try p.openBlock(.scenario_line)) |head| {
        const scenario_tags = p.takePending();
        const desc = p.description();
        const scenario_steps = try p.steps();
        const blocks = try p.examples();
        if (blocks.len != 0 and p.peek().tag == .step_line) {
            return p.fail(.step_after_examples, p.peek().line);
        }

        try list.append(p.arena, .{
            .tags = scenario_tags,
            .keyword_text = head.keyword,
            .name = head.text,
            .description = desc,
            .steps = scenario_steps,
            .examples = blocks,
            .line = head.line,
        });
    }
    return list.toOwnedSlice(p.arena);
}

fn steps(p: *Parser) Error![]const gherkin.Step {
    var list: std.ArrayList(gherkin.Step) = .empty;
    var previous: ?gherkin.Keyword = null;
    while (p.peek().tag == .step_line) {
        const tok = p.advance();
        const resolved = Tokenizer.resolveStepKeyword(tok.keyword) orelse
            previous orelse
            return p.fail(.conjunction_without_step, tok.line);
        previous = resolved;
        var step: gherkin.Step = .{
            .keyword = resolved,
            .keyword_text = tok.keyword,
            .text = tok.text,
            .argument = null,
            .line = tok.line,
        };
        const arg = p.peek();
        switch (arg.tag) {
            .table_row => step.argument = .{ .data_table = try p.table() },
            .docstring_delim => {
                _ = p.advance();
                step.argument = .{ .doc_string = try p.docString(arg) };
            },
            else => {},
        }
        const extra = p.peek();
        if (step.argument != null) switch (extra.tag) {
            .table_row, .docstring_delim => return p.fail(.multiple_step_arguments, extra.line),
            else => {},
        };
        try list.append(p.arena, step);
    }
    return list.toOwnedSlice(p.arena);
}

fn background(p: *Parser) Error!?gherkin.Background {
    if (p.peek().tag != .background_line) return null;
    const head = p.advance();
    const desc = p.description();
    const bg_steps = try p.steps();
    return .{
        .name = head.text,
        .description = desc,
        .steps = bg_steps,
        .line = head.line,
    };
}

/// Splits a `table_row` on unescaped `|`, dropping the fragments outside the
/// outer pipes, then trims and unescapes each cell.
fn row(p: *Parser, tok: Token) Error!gherkin.Row {
    var cells: std.ArrayList([]const u8) = .empty;
    var start: usize = 1;
    var i: usize = 1;
    while (i < tok.text.len) : (i += 1) {
        switch (tok.text[i]) {
            '\\' => i += 1,
            '|' => {
                try cells.append(p.arena, try p.cell(tok.text[start..i]));
                start = i + 1;
            },
            else => {},
        }
    }
    return .{ .cells = try cells.toOwnedSlice(p.arena), .line = tok.line };
}

fn cell(p: *Parser, raw: []const u8) Error![]const u8 {
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (std.mem.findScalar(u8, trimmed, '\\') == null) return trimmed;

    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(p.arena, trimmed.len);
    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        if (trimmed[i] != '\\' or i + 1 == trimmed.len) {
            out.appendAssumeCapacity(trimmed[i]);
            continue;
        }
        i += 1;
        out.appendAssumeCapacity(switch (trimmed[i]) {
            'n' => '\n',
            else => trimmed[i],
        });
    }
    return out.toOwnedSlice(p.arena);
}

fn table(p: *Parser) Error![]const gherkin.Row {
    var rows: std.ArrayList(gherkin.Row) = .empty;
    while (p.peek().tag == .table_row) {
        const parsed = try p.row(p.advance());
        if (rows.items.len != 0 and parsed.cells.len != rows.items[0].cells.len) {
            return p.fail(.ragged_table_row, parsed.line);
        }
        try rows.append(p.arena, parsed);
    }
    return rows.toOwnedSlice(p.arena);
}

fn examples(p: *Parser) Error![]const gherkin.Examples {
    var list: std.ArrayList(gherkin.Examples) = .empty;
    while (try p.openBlock(.examples_line)) |head| {
        const block_tags = p.takePending();
        const desc = p.description();
        const rows = try p.table();
        if (rows.len == 0) return p.fail(.examples_missing_header, head.line);
        try list.append(p.arena, .{
            .tags = block_tags,
            .name = head.text,
            .description = desc,
            .header = rows[0],
            .rows = rows[1..],
            .line = head.line,
        });
    }
    return list.toOwnedSlice(p.arena);
}

fn rules(p: *Parser) Error![]const gherkin.Rule {
    var list: std.ArrayList(gherkin.Rule) = .empty;
    while (try p.openBlock(.rule_line)) |head| {
        const rule_tags = p.takePending();
        const desc = p.description();
        const bg = try p.background();
        const scenario_list = try p.scenarios();

        const after = p.peek();
        if (after.tag == .background_line) return p.fail(.misplaced_background, after.line);

        try list.append(p.arena, .{
            .tags = rule_tags,
            .name = head.text,
            .description = desc,
            .background = bg,
            .scenarios = scenario_list,
            .line = head.line,
        });
    }
    return list.toOwnedSlice(p.arena);
}

/// Reads a doc string body with `Tokenizer.nextRaw`, so nothing inside is
/// classified. Closes only on a line whose trimmed content equals the opening
/// delimiter, which is why a `"""` body is not closed by a ``` line.
fn docString(p: *Parser, open: Token) Error!gherkin.DocString {
    std.debug.assert(p.peeked == null);

    var content: std.ArrayList(u8) = .empty;
    var first = true;
    while (p.tokenizer.nextRaw()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line.text, &std.ascii.whitespace), open.keyword)) {
            return .{
                .media_type = if (open.text.len == 0) null else open.text,
                .content = try content.toOwnedSlice(p.arena),
                .line = open.line,
            };
        }
        if (!first) try content.append(p.arena, '\n');
        first = false;

        const dedented = line.text[@min(open.indent, line.indent)..];
        try appendUnescaped(p.arena, &content, dedented, open.keyword);
    }
    return p.fail(.unterminated_doc_string, open.line);
}

/// Single left-to-right pass. A backslash consumes the byte after it, so an
/// escaped delimiter becomes literal and a lone backslash is preserved.
fn appendUnescaped(
    arena: Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
    delim: []const u8,
) Error!void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\' and std.mem.startsWith(u8, text[i + 1 ..], delim)) {
            try out.appendSlice(arena, delim);
            i += delim.len;
            continue;
        }
        try out.append(arena, text[i]);
    }
}
