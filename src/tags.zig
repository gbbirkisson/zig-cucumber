const std = @import("std");

/// A flat postfix tree. Operands are indexes into the same slice and the root
/// is the last element, so no pointers and no allocator are needed.
pub const Node = union(enum) {
    tag: []const u8,
    not: u32,
    @"and": [2]u32,
    @"or": [2]u32,
};

pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEnd,
    UnbalancedParen,
    EmptyExpression,
    OutOfNodes,
};

const Parser = struct {
    text: []const u8,
    pos: usize = 0,
    buf: []Node,
    len: usize = 0,

    fn skipSpace(p: *Parser) void {
        while (p.pos < p.text.len and std.ascii.isWhitespace(p.text[p.pos])) p.pos += 1;
    }

    fn takeWord(p: *Parser) []const u8 {
        p.skipSpace();
        const start = p.pos;
        while (p.pos < p.text.len and
            !std.ascii.isWhitespace(p.text[p.pos]) and
            p.text[p.pos] != '(' and
            p.text[p.pos] != ')') p.pos += 1;
        return p.text[start..p.pos];
    }

    fn peekByte(p: *Parser) ?u8 {
        p.skipSpace();
        return if (p.pos < p.text.len) p.text[p.pos] else null;
    }

    fn add(p: *Parser, node: Node) ParseError!u32 {
        if (p.len == p.buf.len) return ParseError.OutOfNodes;
        p.buf[p.len] = node;
        p.len += 1;
        return @intCast(p.len - 1);
    }

    fn parseOr(p: *Parser) ParseError!u32 {
        var left = try p.parseAnd();
        while (true) {
            const save = p.pos;
            const word = p.takeWord();
            if (!std.mem.eql(u8, word, "or")) {
                p.pos = save;
                return left;
            }
            const right = try p.parseAnd();
            left = try p.add(.{ .@"or" = .{ left, right } });
        }
    }

    fn parseAnd(p: *Parser) ParseError!u32 {
        var left = try p.parseUnary();
        while (true) {
            const save = p.pos;
            const word = p.takeWord();
            if (!std.mem.eql(u8, word, "and")) {
                p.pos = save;
                return left;
            }
            const right = try p.parseUnary();
            left = try p.add(.{ .@"and" = .{ left, right } });
        }
    }

    fn parseUnary(p: *Parser) ParseError!u32 {
        if (p.peekByte() == null) return ParseError.UnexpectedEnd;
        if (p.peekByte().? == '(') {
            p.pos += 1;
            const inner = try p.parseOr();
            if (p.peekByte() != ')') return ParseError.UnbalancedParen;
            p.pos += 1;
            return inner;
        }
        const save = p.pos;
        const word = p.takeWord();
        if (word.len == 0) return ParseError.UnexpectedEnd;
        if (std.mem.eql(u8, word, "not")) {
            const operand = try p.parseUnary();
            return p.add(.{ .not = operand });
        }
        if (std.mem.eql(u8, word, "and") or std.mem.eql(u8, word, "or")) {
            p.pos = save;
            return ParseError.UnexpectedToken;
        }
        return p.add(.{ .tag = std.mem.trimStart(u8, word, "@") });
    }
};

/// Parses `text` into `buf`, returning the used prefix. The root is the last
/// element. Works at comptime and at runtime. A `buf` of `text.len` nodes is
/// always enough, since every node consumes at least one byte of `text`.
pub fn parse(text: []const u8, buf: []Node) ParseError![]const Node {
    @setEvalBranchQuota(1_000_000);
    var p: Parser = .{ .text = text, .buf = buf };
    p.skipSpace();
    if (p.pos == text.len) return ParseError.EmptyExpression;
    _ = try p.parseOr();
    p.skipSpace();
    if (p.pos != text.len) return ParseError.UnexpectedToken;
    return p.buf[0..p.len];
}

/// Whether `tags` satisfies the expression. `nodes` must come from `parse`,
/// which never returns an empty slice, and whose indexes always point earlier
/// in the slice than the node holding them.
pub fn eval(nodes: []const Node, tags: []const []const u8) bool {
    std.debug.assert(nodes.len != 0);
    return evalAt(nodes, @intCast(nodes.len - 1), tags);
}

fn evalAt(nodes: []const Node, index: u32, tags: []const []const u8) bool {
    return switch (nodes[index]) {
        .tag => |name| blk: {
            for (tags) |t| if (std.mem.eql(u8, t, name)) break :blk true;
            break :blk false;
        },
        .not => |operand| !evalAt(nodes, operand, tags),
        .@"and" => |ops| evalAt(nodes, ops[0], tags) and evalAt(nodes, ops[1], tags),
        .@"or" => |ops| evalAt(nodes, ops[0], tags) or evalAt(nodes, ops[1], tags),
    };
}

fn check(text: []const u8, tags: []const []const u8) !bool {
    var buf: [64]Node = undefined;
    const nodes = try parse(text, &buf);
    return eval(nodes, tags);
}

test "a single tag" {
    try std.testing.expect(try check("@smoke", &.{"smoke"}));
    try std.testing.expect(!try check("@smoke", &.{"slow"}));
    try std.testing.expect(!try check("@smoke", &.{}));
}

test "not, and, or" {
    try std.testing.expect(try check("not @slow", &.{"smoke"}));
    try std.testing.expect(!try check("not @slow", &.{"slow"}));
    try std.testing.expect(try check("@a and @b", &.{ "a", "b" }));
    try std.testing.expect(!try check("@a and @b", &.{"a"}));
    try std.testing.expect(try check("@a or @b", &.{"b"}));
    try std.testing.expect(!try check("@a or @b", &.{"c"}));
}

test "not binds tighter than and, which binds tighter than or" {
    // Parsed as (@a and (not @b)) or @c.
    try std.testing.expect(try check("@a and not @b or @c", &.{"c"}));
    try std.testing.expect(try check("@a and not @b or @c", &.{"a"}));
    try std.testing.expect(!try check("@a and not @b or @c", &.{ "a", "b" }));
}

test "parentheses override precedence" {
    try std.testing.expect(try check("@a and (@b or @c)", &.{ "a", "c" }));
    try std.testing.expect(!try check("@a and (@b or @c)", &.{"a"}));
    try std.testing.expect(try check("not (@a or @b)", &.{"c"}));
    try std.testing.expect(!try check("not (@a or @b)", &.{"a"}));
}

test "the tag expression Cucumber's own docs use" {
    try std.testing.expect(try check("@smoke and not @slow", &.{ "smoke", "fast" }));
    try std.testing.expect(!try check("@smoke and not @slow", &.{ "smoke", "slow" }));
}

test "malformed expressions" {
    var buf: [64]Node = undefined;
    try std.testing.expectError(ParseError.EmptyExpression, parse("", &buf));
    try std.testing.expectError(ParseError.EmptyExpression, parse("   ", &buf));
    try std.testing.expectError(ParseError.UnexpectedEnd, parse("@a and", &buf));
    try std.testing.expectError(ParseError.UnexpectedEnd, parse("not", &buf));
    try std.testing.expectError(ParseError.UnbalancedParen, parse("(@a", &buf));
    try std.testing.expectError(ParseError.UnexpectedToken, parse("@a @b", &buf));
    try std.testing.expectError(ParseError.UnexpectedToken, parse("and @a", &buf));

    var tiny: [2]Node = undefined;
    try std.testing.expectError(ParseError.OutOfNodes, parse("@a and @b or @c", &tiny));
}

test "a tag may be written without its at sign" {
    try std.testing.expect(try check("smoke", &.{"smoke"}));
}

test "it works at comptime as well as at runtime" {
    const ok = comptime blk: {
        var buf: [64]Node = undefined;
        const nodes = try parse("@a and not @b", &buf);
        break :blk eval(nodes, &[_][]const u8{"a"});
    };
    try std.testing.expect(ok);
}
