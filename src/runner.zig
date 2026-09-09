const std = @import("std");
const gherkin = @import("gherkin.zig");
const expression = @import("expression.zig");
const tags = @import("tags.zig");
const convert = @import("convert.zig");
const table = @import("table.zig");

pub const Result = enum { passed, failed, skipped };

pub const Scenario = struct {
    name: []const u8,
    tags: []const []const u8,
    file: []const u8,
    line: u32,
    steps: []const gherkin.Step,
};

pub const BindError = error{
    UndefinedStep,
    AmbiguousStep,
    ArityMismatch,
    IncompatibleCaptureType,
    UnknownCustomType,
    CustomTypeNotEnum,
    MissingStepArgument,
    UnexpectedStepArgument,
    UnsupportedArgumentType,
    UnsupportedInitParam,
    UnsupportedReturnType,
    DuplicateCustomType,
    GenericParam,
    ImmutableWorldParam,
    UnknownHookPhase,
    UnsupportedHookParam,
    StepParamOutsideStepHook,
    ModuleNotAStruct,
    MissingStepsDeclaration,
    StepsNotAStruct,
    HooksNotAStruct,
    WorldNotAStruct,
    WorldInitNotAFunction,
    WorldFieldWithoutDefault,
} || convert.Error || table.RowsError || expression.CompileError || tags.ParseError;

/// What a message points at. A step names a line of a feature file; a
/// declaration names something in the user's own source, which for these
/// messages is a step declaration, a hook, a World field or the module.
const Blame = union(enum) {
    step: Where,
    decl: []const u8,
};

const Where = struct {
    file: []const u8,
    step: gherkin.Step,
    has_world: bool,
};

/// A returned user mistake, with the declaration to blame for it.
const Failure = struct {
    err: BindError,
    decl: []const u8,
};

/// Every public enum declaration of `Module`, as a custom capture type.
fn customTypes(comptime Module: type) BindError![]const expression.CustomType {
    comptime var out: []const expression.CustomType = &.{};
    inline for (@typeInfo(Module).@"struct".decl_names) |name| {
        const decl = @field(Module, name);
        if (@TypeOf(decl) != type) continue;
        if (@typeInfo(decl) != .@"enum") continue;
        for (out) |seen| {
            if (std.mem.eql(u8, seen.name, name)) return BindError.DuplicateCustomType;
        }
        out = out ++ [_]expression.CustomType{.{
            .name = name,
            .alternatives = @typeInfo(decl).@"enum".field_names,
        }};
    }
    return out;
}

/// One resolved step: which handler matched, and what it captured.
const Resolved = struct {
    name: []const u8,
    captures: []const []const u8,
    kinds: []const expression.Capture,
};

/// The capture kinds of an alternative, in order. Every alternative of one
/// pattern shares this sequence, so alternative zero speaks for all of them.
fn captureKinds(comptime alt: expression.Alternative) []const expression.Capture {
    comptime var out: []const expression.Capture = &.{};
    for (alt) |seg| switch (seg) {
        .literal => {},
        .capture => |c| out = out ++ [_]expression.Capture{c},
    };
    return out;
}

fn resolve(comptime Module: type, comptime text: []const u8) BindError!Resolved {
    const custom = try customTypes(Module);
    comptime var found: ?Resolved = null;
    inline for (@typeInfo(Module.steps).@"struct".decl_names) |name| {
        if (@typeInfo(@TypeOf(@field(Module.steps, name))) != .@"fn") continue;
        const alts = try expression.compile(name);
        if (expression.match(alts, custom, text)) |caps| {
            if (found != null) return BindError.AmbiguousStep;
            found = .{ .name = name, .captures = caps, .kinds = captureKinds(alts[0]) };
        }
    }
    return found orelse BindError.UndefinedStep;
}

/// The module's World, or `void` when it declares none.
fn WorldOf(comptime Module: type) type {
    return if (@hasDecl(Module, "World")) Module.World else void;
}

/// The argument tuple for calling `F`. A generic parameter cannot be bound, so
/// it is reported here rather than deep inside `std.meta.ArgsTuple`.
fn ArgsOf(comptime F: type, comptime blame: Blame) type {
    if (@typeInfo(F).@"fn".is_generic) explain(BindError.GenericParam, blame);
    return std.meta.ArgsTuple(F);
}

/// Builds the World, binding `init`'s parameters by type rather than position.
/// Each is optional and either order is accepted. `init` may fail with any
/// error of its own, which is why this returns `anyerror`.
fn makeWorld(comptime Module: type) anyerror!WorldOf(Module) {
    if (comptime !@hasDecl(Module, "World")) return {};
    const World = Module.World;
    if (!@hasDecl(World, "init")) return World{};
    const fi = @typeInfo(@TypeOf(World.init)).@"fn";
    var args: ArgsOf(@TypeOf(World.init), .{ .decl = "World.init" }) = undefined;
    inline for (fi.param_types, 0..) |p, i| {
        const T = p orelse return BindError.UnsupportedInitParam;
        if (T == std.mem.Allocator) {
            args[i] = std.testing.allocator;
        } else if (T == std.Io) {
            args[i] = std.testing.io;
        } else {
            return BindError.UnsupportedInitParam;
        }
    }
    const produced = @call(.auto, World.init, args);
    return if (@typeInfo(fi.return_type.?) == .error_union) try produced else produced;
}

/// The text between a `{string}` capture's quotes, with escapes decoded.
fn unquote(comptime text: []const u8) []const u8 {
    if (text.len < 2) return text;
    comptime var out: []const u8 = "";
    comptime var i: usize = 1;
    while (i + 1 < text.len) : (i += 1) {
        if (text[i] == '\\' and i + 2 < text.len) i += 1;
        out = out ++ text[i .. i + 1];
    }
    return out;
}

/// Checks that a pattern's custom captures name public enums of the module.
fn checkCustomCaptures(comptime Module: type, comptime kinds: []const expression.Capture) BindError!void {
    inline for (kinds) |k| switch (k) {
        .custom => |name| {
            if (!@hasDecl(Module, name)) return BindError.UnknownCustomType;
            const decl = @field(Module, name);
            if (@TypeOf(decl) != type) return BindError.CustomTypeNotEnum;
            if (@typeInfo(decl) != .@"enum") return BindError.CustomTypeNotEnum;
        },
        else => {},
    };
}

/// Converts one captured text to the handler parameter's declared type.
fn bindCapture(
    comptime Module: type,
    comptime T: type,
    comptime kind: expression.Capture,
    comptime text: []const u8,
) BindError!T {
    return switch (kind) {
        .int => if (@typeInfo(T) == .int)
            try convert.parse(T, text)
        else
            BindError.IncompatibleCaptureType,
        .float => if (@typeInfo(T) == .float)
            try convert.parse(T, text)
        else
            BindError.IncompatibleCaptureType,
        .word, .anything => if (T == []const u8)
            text
        else
            BindError.IncompatibleCaptureType,
        .string => if (T == []const u8)
            unquote(text)
        else
            BindError.IncompatibleCaptureType,
        .custom => |name| if (@hasDecl(Module, name) and
            @TypeOf(@field(Module, name)) == type and
            T == @field(Module, name))
            try convert.parse(T, text)
        else
            BindError.IncompatibleCaptureType,
    };
}

/// How a handler's parameter list divides up.
const Shape = struct {
    world: bool,
    captures: usize,
    argument: ?type,
};

/// Whether a handler or hook may return this type: `void`, or an error union
/// over `void`.
fn returnsVoid(comptime R: type) bool {
    return switch (@typeInfo(R)) {
        .void => true,
        .error_union => |u| u.payload == void,
        else => false,
    };
}

fn shapeOf(
    comptime Module: type,
    comptime F: type,
    comptime captures: usize,
) BindError!Shape {
    const fi = @typeInfo(F).@"fn";
    if (fi.is_generic) return BindError.GenericParam;
    const R = fi.return_type orelse return BindError.UnsupportedReturnType;
    if (!returnsVoid(R)) return BindError.UnsupportedReturnType;
    const World = WorldOf(Module);
    if (World != void and fi.param_types.len > 0 and
        (fi.param_types[0] == World or fi.param_types[0] == *const World))
        return BindError.ImmutableWorldParam;
    const world = World != void and
        fi.param_types.len > 0 and
        fi.param_types[0] == *World;
    const fixed = @as(usize, @intFromBool(world)) + captures;
    if (fi.param_types.len == fixed) return .{ .world = world, .captures = captures, .argument = null };
    if (fi.param_types.len == fixed + 1) {
        const T = fi.param_types[fixed] orelse return BindError.UnsupportedArgumentType;
        return .{ .world = world, .captures = captures, .argument = T };
    }
    return BindError.ArityMismatch;
}

/// A Gherkin data table as a `Table`: row zero is the header.
fn tableOf(comptime rows: []const gherkin.Row) BindError!table.Table {
    if (rows.len == 0) return BindError.MissingStepArgument;
    return .{ .header = rows[0], .rows = rows[1..] };
}

/// Converts a step's Gherkin argument to the handler's trailing parameter type.
fn bindArgument(
    comptime T: type,
    comptime argument: ?gherkin.Argument,
) BindError!T {
    const arg = argument orelse return BindError.MissingStepArgument;
    if (T == table.Table) {
        return switch (arg) {
            .data_table => |rows| try tableOf(rows),
            .doc_string => BindError.UnsupportedArgumentType,
        };
    }
    if (T == gherkin.DocString) {
        return switch (arg) {
            .doc_string => |d| d,
            .data_table => BindError.UnsupportedArgumentType,
        };
    }
    if (T == []const u8) {
        return switch (arg) {
            .doc_string => |d| d.content,
            .data_table => BindError.UnsupportedArgumentType,
        };
    }
    const info = @typeInfo(T);
    if (info == .pointer and info.pointer.size == .slice and
        info.pointer.attrs.@"const" and @typeInfo(info.pointer.child) == .@"struct")
    {
        return switch (arg) {
            .data_table => |rows| try table.rows(info.pointer.child, try tableOf(rows)),
            .doc_string => BindError.UnsupportedArgumentType,
        };
    }
    return BindError.UnsupportedArgumentType;
}

const Phase = enum { before, after, before_step, after_step };

fn hookParts(comptime name: []const u8) struct { phase: ?Phase, filter: []const u8 } {
    const sp = std.mem.findScalar(u8, name, ' ');
    const head = if (sp) |s| name[0..s] else name;
    const filter = if (sp) |s| name[s + 1 ..] else "";
    inline for (std.meta.tags(Phase)) |p| {
        if (std.mem.eql(u8, @tagName(p), head)) return .{ .phase = p, .filter = filter };
    }
    return .{ .phase = null, .filter = "" };
}

fn filterAdmits(comptime filter: []const u8, comptime scenario_tags: []const []const u8) tags.ParseError!bool {
    if (filter.len == 0) return true;
    var buf: [filter.len]tags.Node = undefined;
    const nodes = try tags.parse(filter, &buf);
    return tags.eval(nodes, scenario_tags);
}

/// What a hook parameter receives, by its declared type.
const HookArg = enum { world, result, step };

fn hookArg(comptime Module: type, comptime T: ?type) BindError!HookArg {
    const P = T orelse return BindError.GenericParam;
    const World = WorldOf(Module);
    if (World != void) {
        if (P == *World) return .world;
        if (P == World or P == *const World) return BindError.ImmutableWorldParam;
    }
    if (P == Result) return .result;
    if (P == gherkin.Step) return .step;
    return BindError.UnsupportedHookParam;
}

fn callHook(
    comptime Module: type,
    comptime name: []const u8,
    world: *WorldOf(Module),
    comptime step: ?gherkin.Step,
    result: Result,
) anyerror!void {
    const f = @field(Module.hooks, name);
    const fi = @typeInfo(@TypeOf(f)).@"fn";
    var args: ArgsOf(@TypeOf(f), .{ .decl = name }) = undefined;
    inline for (fi.param_types, 0..) |p, i| {
        const which = comptime hookArg(Module, p) catch |e| explain(e, .{ .decl = name });
        if (which == .world) {
            args[i] = world;
        } else if (which == .result) {
            args[i] = result;
        } else {
            args[i] = comptime (step orelse
                explain(BindError.StepParamOutsideStepHook, .{ .decl = name }));
        }
    }
    const produced = @call(.auto, f, args);
    if (@typeInfo(fi.return_type.?) == .error_union) try produced;
}

fn runHooks(
    comptime Module: type,
    comptime scenario: Scenario,
    comptime phase: Phase,
    world: *WorldOf(Module),
    comptime step: ?gherkin.Step,
    result: Result,
) anyerror!void {
    if (comptime !@hasDecl(Module, "hooks")) return;
    const names = @typeInfo(Module.hooks).@"struct".decl_names;
    const reverse = phase == .after or phase == .after_step;
    var first_error: ?anyerror = null;
    inline for (0..names.len) |n| {
        const name = names[if (reverse) names.len - 1 - n else n];
        if (@typeInfo(@TypeOf(@field(Module.hooks, name))) != .@"fn") continue;
        const parts = comptime hookParts(name);
        if (comptime parts.phase != phase) continue;
        if (comptime !(filterAdmits(parts.filter, scenario.tags) catch |e|
            explain(e, .{ .decl = name }))) continue;
        callHook(Module, name, world, step, result) catch |e| {
            if (first_error == null) first_error = e;
        };
    }
    if (first_error) |e| return e;
}

/// Everything about the user's module that can be judged before a step runs:
/// its shape, its World, its step declarations and its hooks.
fn checkModule(comptime Module: type) ?Failure {
    @setEvalBranchQuota(1_000_000);
    const named = @typeName(Module);
    if (@typeInfo(Module) != .@"struct") return .{ .err = BindError.ModuleNotAStruct, .decl = named };
    if (!@hasDecl(Module, "steps")) return .{ .err = BindError.MissingStepsDeclaration, .decl = named };
    if (@TypeOf(Module.steps) != type or @typeInfo(Module.steps) != .@"struct")
        return .{ .err = BindError.StepsNotAStruct, .decl = named };
    if (@hasDecl(Module, "hooks") and
        (@TypeOf(Module.hooks) != type or @typeInfo(Module.hooks) != .@"struct"))
        return .{ .err = BindError.HooksNotAStruct, .decl = named };
    if (checkWorld(Module)) |f| return f;
    if (checkSteps(Module)) |f| return f;
    if (checkHooks(Module)) |f| return f;
    return null;
}

/// The World must be a struct, and without an `init` every field needs a
/// default, because `makeWorld` then default constructs it.
fn checkWorld(comptime Module: type) ?Failure {
    if (!@hasDecl(Module, "World")) return null;
    const named = @typeName(Module);
    if (@TypeOf(Module.World) != type or @typeInfo(Module.World) != .@"struct")
        return .{ .err = BindError.WorldNotAStruct, .decl = named };
    const World = Module.World;
    if (@hasDecl(World, "init")) {
        if (@typeInfo(@TypeOf(World.init)) != .@"fn")
            return .{ .err = BindError.WorldInitNotAFunction, .decl = named };
        return null;
    }
    const info = @typeInfo(World).@"struct";
    inline for (info.field_names, info.field_attrs) |name, attrs| {
        if (attrs.default_value_ptr == null)
            return .{ .err = BindError.WorldFieldWithoutDefault, .decl = name };
    }
    return null;
}

/// Every step declaration names a pattern that must compile, whose custom
/// captures must name public enums of the module. Both are mistakes in the
/// declaration itself, so neither waits for a feature line to trip over it.
fn checkSteps(comptime Module: type) ?Failure {
    inline for (@typeInfo(Module.steps).@"struct".decl_names) |name| {
        if (@typeInfo(@TypeOf(@field(Module.steps, name))) != .@"fn") continue;
        const alts = expression.compile(name) catch |e| return .{ .err = e, .decl = name };
        checkCustomCaptures(Module, captureKinds(alts[0])) catch |e|
            return .{ .err = e, .decl = name };
    }
    return null;
}

fn checkHooks(comptime Module: type) ?Failure {
    if (!@hasDecl(Module, "hooks")) return null;
    inline for (@typeInfo(Module.hooks).@"struct".decl_names) |name| {
        if (checkHook(Module, name)) |f| return f;
    }
    return null;
}

/// A hook must name a phase, parse its tag filter, return void and declare
/// only parameters its phase can hand it. Anything else in `hooks` that is not
/// a function is a shared helper, not a hook.
fn checkHook(comptime Module: type, comptime name: []const u8) ?Failure {
    const info = @typeInfo(@TypeOf(@field(Module.hooks, name)));
    if (info != .@"fn") return null;
    const fi = info.@"fn";
    const parts = hookParts(name);
    const phase = parts.phase orelse return .{ .err = BindError.UnknownHookPhase, .decl = name };
    _ = filterAdmits(parts.filter, &.{}) catch |e| return .{ .err = e, .decl = name };
    if (fi.is_generic) return .{ .err = BindError.GenericParam, .decl = name };
    const R = fi.return_type orelse return .{ .err = BindError.UnsupportedReturnType, .decl = name };
    if (!returnsVoid(R)) return .{ .err = BindError.UnsupportedReturnType, .decl = name };
    inline for (fi.param_types) |p| {
        const which = hookArg(Module, p) catch |e| return .{ .err = e, .decl = name };
        if (which == .step and phase != .before_step and phase != .after_step)
            return .{ .err = BindError.StepParamOutsideStepHook, .decl = name };
    }
    return null;
}

const Suggestion = struct {
    pattern: []const u8,
    params: []const u8,
};

fn suggest(comptime text: []const u8, comptime has_world: bool) Suggestion {
    comptime var pattern: []const u8 = "";
    comptime var params: []const u8 = if (has_world) "w: *World" else "";
    comptime var argc: usize = 0;
    comptime var i: usize = 0;

    while (i < text.len) {
        if (capture(text, i)) |c| {
            pattern = pattern ++ c.name;
            if (params.len > 0) params = params ++ ", ";
            params = params ++ std.fmt.comptimePrint("arg{d}: {s}", .{ argc, c.type_name });
            argc += 1;
            i = c.end;
            continue;
        }
        pattern = pattern ++ text[i .. i + 1];
        i += 1;
    }
    return .{ .pattern = pattern, .params = params };
}

fn capture(comptime text: []const u8, comptime i: usize) ?struct {
    name: []const u8,
    type_name: []const u8,
    end: usize,
} {
    if (text[i] == '"' or text[i] == '\'') {
        const quote = text[i];
        comptime var j = i + 1;
        while (j < text.len and text[j] != quote) j += 1;
        if (j < text.len) return .{ .name = "{string}", .type_name = "[]const u8", .end = j + 1 };
        return null;
    }
    const starts_number = std.ascii.isDigit(text[i]) or
        (text[i] == '-' and i + 1 < text.len and std.ascii.isDigit(text[i + 1]));
    if (!starts_number) return null;
    comptime var j = if (text[i] == '-') i + 1 else i;
    comptime var dots: usize = 0;
    while (j < text.len and (std.ascii.isDigit(text[j]) or (text[j] == '.' and dots == 0))) {
        if (text[j] == '.') dots += 1;
        j += 1;
    }
    if (dots == 1 and std.ascii.isDigit(text[j - 1]))
        return .{ .name = "{float}", .type_name = "f64", .end = j };
    return .{ .name = "{int}", .type_name = "i64", .end = j };
}

/// The declaration to paste for a step the module does not define. The step's
/// own argument, if it carries one, becomes the trailing parameter, so the
/// pasted declaration accepts the step as written.
fn snippet(
    comptime text: []const u8,
    comptime has_world: bool,
    comptime argument: ?gherkin.Argument,
) []const u8 {
    const s = suggest(text, has_world);
    const trailing: []const u8 = if (argument) |a| switch (a) {
        .data_table => "t: cucumber.Table",
        .doc_string => "doc: []const u8",
    } else "";
    const params = if (trailing.len == 0)
        s.params
    else if (s.params.len == 0)
        trailing
    else
        s.params ++ ", " ++ trailing;
    return std.fmt.comptimePrint(
        \\
        \\    pub fn @"{s}"({s}) !void {{
        \\        @panic("TODO");
        \\    }}
        \\
    , .{ s.pattern, params });
}

fn hasDeinit(comptime Module: type) bool {
    const World = WorldOf(Module);
    if (World == void) return false;
    return @hasDecl(World, "deinit");
}

/// Turns a returned bind error into a compile error naming either the feature
/// file line the step comes from or the declaration the mistake is in. This is
/// the only place in the library that raises rather than returns.
fn explain(comptime e: anyerror, comptime blame: Blame) noreturn {
    @compileError(switch (blame) {
        .step => |w| stepMessage(e, w),
        .decl => |d| declMessage(e, d),
    });
}

/// A mistake the feature file's own line explains best.
fn stepMessage(comptime e: anyerror, comptime w: Where) []const u8 {
    const where = std.fmt.comptimePrint("{s}:{d}", .{ w.file, w.step.line });
    return switch (e) {
        BindError.UndefinedStep => std.fmt.comptimePrint(
            "{s}: undefined step: \"{s}\"\n{s}",
            .{ where, w.step.text, snippet(w.step.text, w.has_world, w.step.argument) },
        ),
        BindError.AmbiguousStep => std.fmt.comptimePrint(
            "{s}: ambiguous step: \"{s}\" matches more than one pattern",
            .{ where, w.step.text },
        ),
        BindError.ArityMismatch => std.fmt.comptimePrint(
            "{s}: the handler for \"{s}\" declares the wrong number of parameters: " ++
                "it must be one optional world pointer, one per capture, then one optional argument",
            .{ where, w.step.text },
        ),
        BindError.UnexpectedStepArgument => std.fmt.comptimePrint(
            "{s}: step \"{s}\" carries an argument its handler does not accept",
            .{ where, w.step.text },
        ),
        BindError.MissingStepArgument => std.fmt.comptimePrint(
            "{s}: the handler for \"{s}\" declares an argument the step does not carry",
            .{ where, w.step.text },
        ),
        BindError.ImmutableWorldParam => std.fmt.comptimePrint(
            "{s}: the handler for \"{s}\" takes the World by value or by const pointer; " ++
                "declare its first parameter as *World",
            .{ where, w.step.text },
        ),
        BindError.GenericParam => std.fmt.comptimePrint(
            "{s}: the handler for \"{s}\" declares a generic parameter; anytype and comptime " ++
                "parameters cannot be bound",
            .{ where, w.step.text },
        ),
        else => std.fmt.comptimePrint(
            "{s}: step \"{s}\": {s}",
            .{ where, w.step.text, @errorName(e) },
        ),
    };
}

/// A mistake in the user's Zig source, which no feature line is to blame for.
fn declMessage(comptime e: anyerror, comptime decl: []const u8) []const u8 {
    return switch (e) {
        BindError.StrayBackslash,
        BindError.UnterminatedCapture,
        BindError.UnterminatedOptional,
        BindError.EmptyGroup,
        BindError.IllegalGroupContent,
        BindError.TooManyAlternatives,
        => std.fmt.comptimePrint(
            "the step declaration @\"{s}\" is not a valid Cucumber Expression: {s}",
            .{ decl, @errorName(e) },
        ),
        BindError.UnexpectedToken,
        BindError.UnexpectedEnd,
        BindError.UnbalancedParen,
        BindError.EmptyExpression,
        BindError.OutOfNodes,
        => std.fmt.comptimePrint(
            "the tag filter of hook @\"{s}\" is malformed: {s}",
            .{ decl, @errorName(e) },
        ),
        BindError.UnknownCustomType => std.fmt.comptimePrint(
            "the step declaration @\"{s}\" names a custom type the module does not declare; " ++
                "declare a public enum of that name beside steps",
            .{decl},
        ),
        BindError.CustomTypeNotEnum => std.fmt.comptimePrint(
            "the step declaration @\"{s}\" names a custom type that is not a public enum",
            .{decl},
        ),
        BindError.UnknownHookPhase => std.fmt.comptimePrint(
            "@\"{s}\" in hooks names no phase; a hook is before, after, before_step or " ++
                "after_step, optionally followed by a tag filter",
            .{decl},
        ),
        BindError.UnsupportedHookParam => std.fmt.comptimePrint(
            "the hook @\"{s}\" declares a parameter no hook is given; a hook takes *World, " ++
                "cucumber.Result and, for a step hook, cucumber.Step",
            .{decl},
        ),
        BindError.StepParamOutsideStepHook => std.fmt.comptimePrint(
            "the hook @\"{s}\" declares a cucumber.Step parameter, which only before_step and " ++
                "after_step hooks are given",
            .{decl},
        ),
        BindError.ImmutableWorldParam => std.fmt.comptimePrint(
            "the hook @\"{s}\" takes the World by value or by const pointer; declare it as *World",
            .{decl},
        ),
        BindError.UnsupportedReturnType => std.fmt.comptimePrint(
            "the hook @\"{s}\" must return void or an error union over void",
            .{decl},
        ),
        BindError.GenericParam => std.fmt.comptimePrint(
            "\"{s}\" declares a generic parameter; anytype and comptime parameters cannot be bound",
            .{decl},
        ),
        BindError.ModuleNotAStruct => std.fmt.comptimePrint(
            "the steps module {s} is not a struct",
            .{decl},
        ),
        BindError.MissingStepsDeclaration => std.fmt.comptimePrint(
            "the steps module {s} declares no steps; add pub const steps = struct {{ ... }}",
            .{decl},
        ),
        BindError.StepsNotAStruct => std.fmt.comptimePrint(
            "steps in {s} must be a struct of step declarations",
            .{decl},
        ),
        BindError.HooksNotAStruct => std.fmt.comptimePrint(
            "hooks in {s} must be a struct of hook declarations",
            .{decl},
        ),
        BindError.WorldNotAStruct => std.fmt.comptimePrint(
            "World in {s} must be a struct",
            .{decl},
        ),
        BindError.WorldInitNotAFunction => std.fmt.comptimePrint(
            "World.init in {s} must be a function",
            .{decl},
        ),
        BindError.WorldFieldWithoutDefault => std.fmt.comptimePrint(
            "the World field \"{s}\" has no default value and World declares no init; " ++
                "give the field a default or add pub fn init",
            .{decl},
        ),
        else => std.fmt.comptimePrint("the declaration @\"{s}\": {s}", .{ decl, @errorName(e) }),
    };
}

/// Resolves one step and calls its handler.
fn dispatch(
    comptime Module: type,
    comptime file: []const u8,
    comptime step: gherkin.Step,
    world: *WorldOf(Module),
) anyerror!void {
    const blame: Blame = .{ .step = .{
        .file = file,
        .step = step,
        .has_world = WorldOf(Module) != void,
    } };
    const r = comptime resolve(Module, step.text) catch |e| explain(e, blame);
    const f = @field(Module.steps, r.name);
    const F = @TypeOf(f);
    const fi = @typeInfo(F).@"fn";
    const shape = comptime shapeOf(Module, F, r.captures.len) catch |e| explain(e, blame);
    if (comptime shape.argument == null and step.argument != null)
        explain(BindError.UnexpectedStepArgument, blame);

    var args: ArgsOf(F, blame) = undefined;
    const base = comptime @intFromBool(shape.world);
    if (comptime shape.world) args[0] = world;
    inline for (r.captures, r.kinds, 0..) |text, kind, n| {
        args[base + n] = comptime bindCapture(Module, fi.param_types[base + n].?, kind, text) catch |e|
            explain(e, blame);
    }
    if (comptime shape.argument) |T| {
        args[base + r.captures.len] = comptime bindArgument(T, step.argument) catch |e|
            explain(e, blame);
    }
    const produced = @call(.auto, f, args);
    if (@typeInfo(fi.return_type.?) == .error_union) try produced;
}

/// Runs one scenario against the user's steps module.
pub fn run(comptime Module: type, comptime scenario: Scenario) anyerror!void {
    return runScenario(Module, scenario, true);
}

/// `report` prints a failing step's location to stderr. This file's tests of
/// expected failures pass false: any stderr write makes an otherwise green
/// `zig build test` print `failed command:` and dump the output.
fn runScenario(comptime Module: type, comptime scenario: Scenario, comptime report: bool) anyerror!void {
    @setEvalBranchQuota(1_000_000);
    comptime {
        if (checkModule(Module)) |f| explain(f.err, .{ .decl = f.decl });
    }
    var world = try makeWorld(Module);
    defer if (comptime hasDeinit(Module)) world.deinit();

    var first_error: ?anyerror = null;
    var outcome: Result = .passed;
    {
        defer runHooks(Module, scenario, .after, &world, null, outcome) catch |e| {
            if (first_error == null) first_error = e;
        };

        runHooks(Module, scenario, .before, &world, null, .passed) catch |e| {
            first_error = e;
            outcome = if (e == error.SkipZigTest) .skipped else .failed;
        };

        inline for (scenario.steps) |step| {
            if (first_error == null) {
                runHooks(Module, scenario, .before_step, &world, step, .passed) catch |e| {
                    first_error = e;
                    outcome = if (e == error.SkipZigTest) .skipped else .failed;
                };
            }
            if (first_error == null) {
                dispatch(Module, scenario.file, step, &world) catch |e| {
                    first_error = e;
                    outcome = if (e == error.SkipZigTest) .skipped else .failed;
                    if (report and e != error.SkipZigTest) std.debug.print(
                        "\n{s}:{d}: step failed: {s} {s}\n",
                        .{ scenario.file, step.line, step.keyword_text, step.text },
                    );
                };
                runHooks(Module, scenario, .after_step, &world, step, outcome) catch |e| {
                    if (first_error == null) first_error = e;
                };
            } else {
                runHooks(Module, scenario, .after_step, &world, step, .skipped) catch |e| {
                    if (first_error == null) first_error = e;
                };
            }
        }
    }
    if (first_error) |e| return e;
}

test "custom types come from the module's public enum declarations" {
    const M = struct {
        pub const Color = enum { red, green_dark, green };
        pub const Size = enum { small, large };
        pub const World = struct { n: i64 = 0 };
        pub const steps = struct {};
        const Private = enum { hidden };
    };
    const cts = comptime try customTypes(M);
    try std.testing.expectEqual(@as(usize, 2), cts.len);
    try std.testing.expectEqualStrings("Color", cts[0].name);
    try std.testing.expectEqualStrings("green_dark", cts[0].alternatives[1]);
    try std.testing.expectEqualStrings("Size", cts[1].name);
}

test "a module with no enums yields an empty list" {
    const M = struct {
        pub const steps = struct {};
    };
    const cts = comptime try customTypes(M);
    try std.testing.expectEqual(@as(usize, 0), cts.len);
}

test "a step resolves to the one handler whose pattern matches" {
    const M = struct {
        pub const steps = struct {
            pub fn @"I press add"() void {}
            pub fn @"I have {int} cukes"(n: i64) void {
                _ = n;
            }
        };
    };
    const r = comptime try resolve(M, "I have 42 cukes");
    try std.testing.expectEqualStrings("I have {int} cukes", r.name);
    try std.testing.expectEqual(@as(usize, 1), r.captures.len);
    try std.testing.expectEqualStrings("42", r.captures[0]);
    try std.testing.expectEqual(expression.Capture.int, r.kinds[0]);

    const plain = comptime try resolve(M, "I press add");
    try std.testing.expectEqualStrings("I press add", plain.name);
    try std.testing.expectEqual(@as(usize, 0), plain.captures.len);
}

test "no handler and two handlers are both reported" {
    const None = struct {
        pub const steps = struct {
            pub fn @"I press add"() void {}
        };
    };
    try std.testing.expectError(BindError.UndefinedStep, comptime resolve(None, "I press subtract"));

    const Two = struct {
        pub const steps = struct {
            pub fn @"I have {int} cukes"(n: i64) void {
                _ = n;
            }
            pub fn @"I have {word} cukes"(w: []const u8) void {
                _ = w;
            }
        };
    };
    try std.testing.expectError(BindError.AmbiguousStep, comptime resolve(Two, "I have 42 cukes"));
}

test "matching ignores the keyword, per keyword agnosticism" {
    const M = struct {
        pub const steps = struct {
            pub fn @"the light is on"() void {}
        };
    };
    const r = comptime try resolve(M, "the light is on");
    try std.testing.expectEqualStrings("the light is on", r.name);
}

test "a custom capture resolves through the module's enum" {
    const M = struct {
        pub const Color = enum { red, green };
        pub const steps = struct {
            pub fn @"I pick {Color}"(c: Color) void {
                _ = c;
            }
        };
    };
    const r = comptime try resolve(M, "I pick green");
    try std.testing.expectEqualStrings("green", r.captures[0]);
    try std.testing.expectEqualStrings("Color", r.kinds[0].custom);
}

test "a World with no init is default constructed" {
    const M = struct {
        pub const World = struct { n: i64 = 7 };
        pub const steps = struct {};
    };
    const w = try makeWorld(M);
    try std.testing.expectEqual(@as(i64, 7), w.n);
}

test "init parameters bind by type, in either order, fallible or not" {
    const OnlyGpa = struct {
        pub const World = struct {
            gpa: std.mem.Allocator,
            pub fn init(gpa: std.mem.Allocator) World {
                return .{ .gpa = gpa };
            }
        };
        pub const steps = struct {};
    };
    _ = (try makeWorld(OnlyGpa)).gpa;

    const Reversed = struct {
        pub const World = struct {
            gpa: std.mem.Allocator,
            io: std.Io,
            pub fn init(io: std.Io, gpa: std.mem.Allocator) !World {
                return .{ .gpa = gpa, .io = io };
            }
        };
        pub const steps = struct {};
    };
    const w = try makeWorld(Reversed);
    _ = .{ w.gpa, w.io };

    const Nothing = struct {
        pub const World = struct {
            pub fn init() World {
                return .{};
            }
        };
        pub const steps = struct {};
    };
    _ = try makeWorld(Nothing);
}

test "a World that allocates in init and frees in deinit" {
    const M = struct {
        pub const World = struct {
            gpa: std.mem.Allocator,
            buf: []u8,
            pub fn init(gpa: std.mem.Allocator) !World {
                const buf = try gpa.alloc(u8, 4);
                @memset(buf, 'x');
                return .{ .gpa = gpa, .buf = buf };
            }
            pub fn deinit(w: *World) void {
                w.gpa.free(w.buf);
            }
        };
        pub const steps = struct {
            pub fn one(w: *World) !void {
                try std.testing.expectEqualStrings("xxxx", w.buf);
            }
        };
    };
    var w = try makeWorld(M);
    try std.testing.expectEqualStrings("xxxx", w.buf);
    w.deinit();

    try run(M, scenario_plain);
}

test "an init that fails hands its own error to the caller" {
    const M = struct {
        pub const World = struct {
            pub fn init(gpa: std.mem.Allocator) !World {
                _ = gpa;
                return error.WorldRefused;
            }
        };
        pub const steps = struct {
            pub fn one() void {}
        };
    };
    try std.testing.expectError(error.WorldRefused, makeWorld(M));
    try std.testing.expectError(error.WorldRefused, run(M, scenario_plain));
}

test "an init parameter that is neither an Allocator nor an Io is an error" {
    const M = struct {
        pub const World = struct {
            n: i64,
            pub fn init(n: i64) World {
                return .{ .n = n };
            }
        };
        pub const steps = struct {};
    };
    try std.testing.expectError(BindError.UnsupportedInitParam, makeWorld(M));
}

test "a module with no World builds nothing" {
    const M = struct {
        pub const steps = struct {};
    };
    try std.testing.expectEqual({}, try makeWorld(M));
}

test "unquote strips the quotes and decodes escapes" {
    try std.testing.expectEqualStrings("hello", comptime unquote("\"hello\""));
    try std.testing.expectEqualStrings("hello", comptime unquote("'hello'"));
    try std.testing.expectEqualStrings("a\"b", comptime unquote("\"a\\\"b\""));
    try std.testing.expectEqualStrings("it's", comptime unquote("\"it's\""));
    try std.testing.expectEqualStrings("", comptime unquote("\"\""));
    try std.testing.expectEqualStrings("a b", comptime unquote("\"a b\""));
}

test "a custom capture naming a non-enum or nothing at all is reported" {
    const NotEnum = struct {
        pub const Color = struct { r: u8 };
        pub const steps = struct {
            pub fn @"I pick {Color}"(c: u8) void {
                _ = c;
            }
        };
    };
    try std.testing.expectError(
        BindError.CustomTypeNotEnum,
        comptime checkCustomCaptures(NotEnum, &.{.{ .custom = "Color" }}),
    );

    const Missing = struct {
        pub const steps = struct {
            pub fn @"I pick {Color}"(c: u8) void {
                _ = c;
            }
        };
    };
    try std.testing.expectError(
        BindError.UnknownCustomType,
        comptime checkCustomCaptures(Missing, &.{.{ .custom = "Color" }}),
    );
}

test "each capture kind binds to the types the spec allows" {
    const M = struct {
        pub const Color = enum { red, green };
        pub const steps = struct {};
    };
    try std.testing.expectEqual(@as(i64, -19), comptime try bindCapture(M, i64, .int, "-19"));
    try std.testing.expectEqual(@as(u8, 200), comptime try bindCapture(M, u8, .int, "200"));
    try std.testing.expectEqual(@as(f64, 3.5), comptime try bindCapture(M, f64, .float, "3.5"));
    try std.testing.expectEqualStrings("save", comptime try bindCapture(M, []const u8, .word, "save"));
    try std.testing.expectEqualStrings("a b", comptime try bindCapture(M, []const u8, .anything, "a b"));
    try std.testing.expectEqualStrings("hi", comptime try bindCapture(M, []const u8, .string, "\"hi\""));
    try std.testing.expectEqual(M.Color.green, comptime try bindCapture(M, M.Color, .{ .custom = "Color" }, "green"));
}

test "an incompatible parameter type is reported, and an out of range integer" {
    const M = struct {
        pub const Color = enum { red, green };
        pub const Other = enum { a, b };
        pub const steps = struct {};
    };
    try std.testing.expectError(BindError.IncompatibleCaptureType, comptime bindCapture(M, []const u8, .int, "1"));
    try std.testing.expectError(BindError.IncompatibleCaptureType, comptime bindCapture(M, i64, .float, "1.5"));
    try std.testing.expectError(BindError.IncompatibleCaptureType, comptime bindCapture(M, i64, .word, "x"));
    try std.testing.expectError(BindError.IncompatibleCaptureType, comptime bindCapture(M, i64, .string, "\"x\""));
    try std.testing.expectError(
        BindError.IncompatibleCaptureType,
        comptime bindCapture(M, M.Other, .{ .custom = "Color" }, "green"),
    );
    try std.testing.expectError(BindError.IntegerOutOfRange, comptime bindCapture(M, u8, .int, "300"));
}

test "the parameter list divides into world, captures and one argument" {
    const M = struct {
        pub const World = struct { n: i64 = 0 };
        pub const steps = struct {
            pub fn a(w: *World) void {
                _ = w;
            }
            pub fn b(w: *World, n: i64) void {
                _ = .{ w, n };
            }
            pub fn c(w: *World, n: i64, t: table.Table) void {
                _ = .{ w, n, t };
            }
            pub fn d(n: i64) void {
                _ = n;
            }
        };
    };
    const a = comptime try shapeOf(M, @TypeOf(M.steps.a), 0);
    try std.testing.expect(a.world and a.captures == 0 and a.argument == null);

    const b = comptime try shapeOf(M, @TypeOf(M.steps.b), 1);
    try std.testing.expect(b.world and b.captures == 1 and b.argument == null);

    const c = comptime try shapeOf(M, @TypeOf(M.steps.c), 1);
    try std.testing.expect(c.world and c.captures == 1 and c.argument.? == table.Table);

    const d = comptime try shapeOf(M, @TypeOf(M.steps.d), 1);
    try std.testing.expect(!d.world and d.captures == 1 and d.argument == null);
}

test "a handler must return void or an error union over void" {
    const M = struct {
        pub const steps = struct {
            pub fn plain() void {}
            pub fn fallible() anyerror!void {}
            pub fn @"returns a number"() i64 {
                return 1;
            }
            pub fn @"returns a fallible number"() anyerror!i64 {
                return 1;
            }
        };
    };
    _ = comptime try shapeOf(M, @TypeOf(M.steps.plain), 0);
    _ = comptime try shapeOf(M, @TypeOf(M.steps.fallible), 0);
    try std.testing.expectError(
        BindError.UnsupportedReturnType,
        comptime shapeOf(M, @TypeOf(M.steps.@"returns a number"), 0),
    );
    try std.testing.expectError(
        BindError.UnsupportedReturnType,
        comptime shapeOf(M, @TypeOf(M.steps.@"returns a fallible number"), 0),
    );
}

test "too few or too many parameters is an arity mismatch" {
    const M = struct {
        pub const World = struct { n: i64 = 0 };
        pub const steps = struct {
            pub fn two(w: *World, a: i64, b: i64) void {
                _ = .{ w, a, b };
            }
        };
    };
    try std.testing.expectError(BindError.ArityMismatch, comptime shapeOf(M, @TypeOf(M.steps.two), 0));
    const ok = comptime try shapeOf(M, @TypeOf(M.steps.two), 1);
    try std.testing.expect(ok.argument.? == i64);
    try std.testing.expectError(BindError.ArityMismatch, comptime shapeOf(M, @TypeOf(M.steps.two), 3));
}

test "the world parameter must be a mutable pointer" {
    const M = struct {
        pub const World = struct { n: i64 = 0 };
        pub const steps = struct {
            pub fn @"by value"(w: World) void {
                _ = w;
            }
            pub fn @"by const pointer"(w: *const World) void {
                _ = w;
            }
        };
    };
    try std.testing.expectError(
        BindError.ImmutableWorldParam,
        comptime shapeOf(M, @TypeOf(M.steps.@"by value"), 0),
    );
    try std.testing.expectError(
        BindError.ImmutableWorldParam,
        comptime shapeOf(M, @TypeOf(M.steps.@"by const pointer"), 0),
    );
}

test "a generic parameter cannot be bound, in a handler or a hook" {
    const M = struct {
        pub const World = struct { n: i64 = 0 };
        pub const steps = struct {
            pub fn @"anything goes"(x: anytype) void {
                _ = x;
            }
        };
    };
    try std.testing.expectError(
        BindError.GenericParam,
        comptime shapeOf(M, @TypeOf(M.steps.@"anything goes"), 0),
    );
    try std.testing.expectError(BindError.GenericParam, comptime hookArg(M, null));
}

test "a hook parameter is the world pointer, the result or the step" {
    const M = struct {
        pub const World = struct { n: i64 = 0 };
        pub const steps = struct {};
    };
    try std.testing.expectEqual(HookArg.world, comptime try hookArg(M, *M.World));
    try std.testing.expectEqual(HookArg.result, comptime try hookArg(M, Result));
    try std.testing.expectEqual(HookArg.step, comptime try hookArg(M, gherkin.Step));
    try std.testing.expectError(BindError.ImmutableWorldParam, comptime hookArg(M, M.World));
    try std.testing.expectError(BindError.ImmutableWorldParam, comptime hookArg(M, *const M.World));
    try std.testing.expectError(BindError.UnsupportedHookParam, comptime hookArg(M, i64));
}

test "a data table's first row becomes the header" {
    const rows = [_]gherkin.Row{
        .{ .cells = &.{ "name", "age" }, .line = 4 },
        .{ .cells = &.{ "Alice", "30" }, .line = 5 },
    };
    const t = comptime try tableOf(&rows);
    try std.testing.expectEqual(@as(?usize, 1), t.column("age"));
    try std.testing.expectEqualStrings("Alice", t.cell(0, "name").?);
    try std.testing.expectEqual(@as(usize, 1), t.rows.len);
}

test "each accepted trailing argument type binds" {
    const rows = [_]gherkin.Row{
        .{ .cells = &.{ "name", "age" }, .line = 4 },
        .{ .cells = &.{ "Alice", "30" }, .line = 5 },
    };
    const data: gherkin.Argument = .{ .data_table = &rows };
    const doc: gherkin.Argument = .{ .doc_string = .{ .media_type = "json", .content = "{}", .line = 9 } };

    const raw = comptime try bindArgument(table.Table, data);
    try std.testing.expectEqualStrings("Alice", raw.cell(0, "name").?);

    const User = struct { name: []const u8, age: u32 };
    const typed = comptime try bindArgument([]const User, data);
    try std.testing.expectEqual(@as(usize, 1), typed.len);
    try std.testing.expectEqualStrings("Alice", typed[0].name);
    try std.testing.expectEqual(@as(u32, 30), typed[0].age);

    try std.testing.expectEqualStrings("{}", comptime try bindArgument([]const u8, doc));

    const ds = comptime try bindArgument(gherkin.DocString, doc);
    try std.testing.expectEqualStrings("json", ds.media_type.?);
}

test "a trailing slice must be const, and a custom name must be a type" {
    const rows = [_]gherkin.Row{
        .{ .cells = &.{ "name", "age" }, .line = 1 },
        .{ .cells = &.{ "Alice", "30" }, .line = 2 },
    };
    const data: gherkin.Argument = .{ .data_table = &rows };
    const User = struct { name: []const u8, age: u32 };
    try std.testing.expectError(BindError.UnsupportedArgumentType, comptime bindArgument([]User, data));
    const ok = comptime try bindArgument([]const User, data);
    try std.testing.expectEqualStrings("Alice", ok[0].name);

    const M = struct {
        pub const Color = 3;
        pub const steps = struct {};
    };
    try std.testing.expectError(
        BindError.IncompatibleCaptureType,
        comptime bindCapture(M, u8, .{ .custom = "Color" }, "red"),
    );
}

test "a mismatched or missing argument is reported" {
    const rows = [_]gherkin.Row{.{ .cells = &.{"a"}, .line = 1 }};
    const data: gherkin.Argument = .{ .data_table = &rows };
    const doc: gherkin.Argument = .{ .doc_string = .{ .media_type = null, .content = "x", .line = 1 } };

    try std.testing.expectError(BindError.UnsupportedArgumentType, comptime bindArgument(table.Table, doc));
    try std.testing.expectError(BindError.UnsupportedArgumentType, comptime bindArgument(gherkin.DocString, data));
    try std.testing.expectError(BindError.UnsupportedArgumentType, comptime bindArgument([]const u8, data));
    try std.testing.expectError(BindError.UnsupportedArgumentType, comptime bindArgument(i64, doc));
    try std.testing.expectError(BindError.MissingStepArgument, comptime bindArgument(table.Table, null));
}

test "a hook name splits into a phase and a tag filter" {
    const a = comptime hookParts("before");
    try std.testing.expectEqual(Phase.before, a.phase.?);
    try std.testing.expectEqualStrings("", a.filter);

    const b = comptime hookParts("before @db");
    try std.testing.expectEqual(Phase.before, b.phase.?);
    try std.testing.expectEqualStrings("@db", b.filter);

    const c = comptime hookParts("after @slow or @network");
    try std.testing.expectEqual(Phase.after, c.phase.?);
    try std.testing.expectEqualStrings("@slow or @network", c.filter);

    const d = comptime hookParts("after_step");
    try std.testing.expectEqual(Phase.after_step, d.phase.?);

    try std.testing.expect(comptime hookParts("not_a_hook").phase == null);
}

test "a tag filter admits or rejects a scenario" {
    try std.testing.expect(comptime try filterAdmits("", &.{}));
    try std.testing.expect(comptime try filterAdmits("@db", &.{"db"}));
    try std.testing.expect(!try comptime filterAdmits("@db", &.{"slow"}));
    try std.testing.expect(comptime try filterAdmits("@slow or @network", &.{"network"}));
    try std.testing.expect(!try comptime filterAdmits("@a and @b", &.{"a"}));
    try std.testing.expect(comptime try filterAdmits("not @slow", &.{"fast"}));
}

fn failureOf(comptime Module: type) Failure {
    return comptime checkModule(Module) orelse .{ .err = BindError.UndefinedStep, .decl = "" };
}

test "a module that is not shaped like a steps module is reported" {
    try std.testing.expectEqual(BindError.ModuleNotAStruct, failureOf(u32).err);

    try std.testing.expectEqual(
        BindError.MissingStepsDeclaration,
        failureOf(struct {
            pub const World = struct {};
        }).err,
    );
    try std.testing.expectEqual(
        BindError.StepsNotAStruct,
        failureOf(struct {
            pub const steps = 3;
        }).err,
    );
    try std.testing.expectEqual(
        BindError.HooksNotAStruct,
        failureOf(struct {
            pub const steps = struct {};
            pub const hooks = 3;
        }).err,
    );
    try std.testing.expectEqual(
        BindError.WorldNotAStruct,
        failureOf(struct {
            pub const World = u32;
            pub const steps = struct {};
        }).err,
    );
    try std.testing.expectEqual(
        BindError.WorldInitNotAFunction,
        failureOf(struct {
            pub const World = struct {
                pub const init = 3;
            };
            pub const steps = struct {};
        }).err,
    );
}

test "a World field with no default needs an init to fill it" {
    const M = struct {
        pub const World = struct { n: i64 };
        pub const steps = struct {};
    };
    const f = failureOf(M);
    try std.testing.expectEqual(BindError.WorldFieldWithoutDefault, f.err);
    try std.testing.expectEqualStrings("n", f.decl);

    const WithInit = struct {
        pub const World = struct {
            n: i64,
            pub fn init() World {
                return .{ .n = 1 };
            }
        };
        pub const steps = struct {};
    };
    try std.testing.expectEqual(@as(?Failure, null), comptime checkModule(WithInit));
}

test "a step declaration that does not compile is blamed by its own name" {
    const M = struct {
        pub const steps = struct {
            pub fn @"the light is on"() void {}
            pub fn @"I set the dial to {int"(n: i64) void {
                _ = n;
            }
        };
    };
    const f = failureOf(M);
    try std.testing.expectEqual(BindError.UnterminatedCapture, f.err);
    try std.testing.expectEqualStrings("I set the dial to {int", f.decl);
}

test "a custom capture with no enum behind it is blamed by its own declaration" {
    const Misspelled = struct {
        pub const Color = enum { red, green };
        pub const steps = struct {
            // The capture names a type the module does not declare.
            pub fn @"I pick {Colr}"(c: Color) void {
                _ = c;
            }
        };
    };
    const f = failureOf(Misspelled);
    try std.testing.expectEqual(BindError.UnknownCustomType, f.err);
    try std.testing.expectEqualStrings("I pick {Colr}", f.decl);

    const NotEnum = struct {
        pub const Color = struct { r: u8 };
        pub const steps = struct {
            pub fn @"I pick {Color}"(c: u8) void {
                _ = c;
            }
        };
    };
    try std.testing.expectEqual(BindError.CustomTypeNotEnum, failureOf(NotEnum).err);
}

test "a hook must name a phase and take only what its phase provides" {
    try std.testing.expectEqual(
        BindError.UnknownHookPhase,
        failureOf(struct {
            pub const steps = struct {};
            pub const hooks = struct {
                pub fn Before() void {}
            };
        }).err,
    );
    try std.testing.expectEqual(
        BindError.UnexpectedEnd,
        failureOf(struct {
            pub const steps = struct {};
            pub const hooks = struct {
                pub fn @"before @a and"() void {}
            };
        }).err,
    );
    try std.testing.expectEqual(
        BindError.UnsupportedHookParam,
        failureOf(struct {
            pub const steps = struct {};
            pub const hooks = struct {
                pub fn before(n: i64) void {
                    _ = n;
                }
            };
        }).err,
    );
    try std.testing.expectEqual(
        BindError.StepParamOutsideStepHook,
        failureOf(struct {
            pub const steps = struct {};
            pub const hooks = struct {
                pub fn before(s: gherkin.Step) void {
                    _ = s;
                }
            };
        }).err,
    );
    try std.testing.expectEqual(
        BindError.UnsupportedReturnType,
        failureOf(struct {
            pub const steps = struct {};
            pub const hooks = struct {
                pub fn before() i64 {
                    return 1;
                }
            };
        }).err,
    );
}

test "a hooks declaration that is not a function is a helper, not a hook" {
    const M = struct {
        pub const steps = struct {};
        pub const hooks = struct {
            pub const retries = 3;
            pub const Helper = struct {};
            pub fn before() void {}
        };
    };
    try std.testing.expectEqual(@as(?Failure, null), comptime checkModule(M));
}

test "a step text generalises into a pattern and a parameter list" {
    try std.testing.expectEqualStrings("I have entered {int}", comptime suggest("I have entered 50", true).pattern);
    try std.testing.expectEqualStrings("w: *World, arg0: i64", comptime suggest("I have entered 50", true).params);
    try std.testing.expectEqualStrings("a {float} b", comptime suggest("a 3.5 b", false).pattern);
    try std.testing.expectEqualStrings("arg0: f64", comptime suggest("a 3.5 b", false).params);
    try std.testing.expectEqualStrings("I type {string}", comptime suggest("I type \"hello\"", false).pattern);
    try std.testing.expectEqualStrings("plain text", comptime suggest("plain text", false).pattern);
    try std.testing.expectEqualStrings("", comptime suggest("plain text", false).params);
    try std.testing.expectEqualStrings("{int} and {int}", comptime suggest("-19 and 71", false).pattern);
    try std.testing.expectEqualStrings("arg0: i64, arg1: i64", comptime suggest("-19 and 71", false).params);
    try std.testing.expectEqualStrings("v{int}", comptime suggest("v2", false).pattern);
}

test "the snippet reads as pasteable Zig" {
    try std.testing.expectEqualStrings(
        \\
        \\    pub fn @"I have entered {int}"(w: *World, arg0: i64) !void {
        \\        @panic("TODO");
        \\    }
        \\
    , comptime snippet("I have entered 50", true, null));
}

test "the snippet takes the step's own argument as its trailing parameter" {
    const rows = [_]gherkin.Row{.{ .cells = &.{"a"}, .line = 2 }};
    try std.testing.expectEqualStrings(
        \\
        \\    pub fn @"the users are"(w: *World, t: cucumber.Table) !void {
        \\        @panic("TODO");
        \\    }
        \\
    , comptime snippet("the users are", true, .{ .data_table = &rows }));

    try std.testing.expectEqualStrings(
        \\
        \\    pub fn @"the body is"(doc: []const u8) !void {
        \\        @panic("TODO");
        \\    }
        \\
    , comptime snippet("the body is", false, .{
        .doc_string = .{ .media_type = null, .content = "x", .line = 2 },
    }));

    try std.testing.expectEqualStrings(
        \\
        \\    pub fn @"I add {int}"(arg0: i64, t: cucumber.Table) !void {
        \\        @panic("TODO");
        \\    }
        \\
    , comptime snippet("I add 2", false, .{ .data_table = &rows }));
}

var trace_buf: [64][]const u8 = undefined;
var trace_len: usize = 0;

fn note(what: []const u8) void {
    trace_buf[trace_len] = what;
    trace_len += 1;
}

fn traced() []const []const u8 {
    return trace_buf[0..trace_len];
}

fn mkStep(comptime text: []const u8, comptime line: u32) gherkin.Step {
    return .{
        .keyword = .given,
        .keyword_text = "Given",
        .text = text,
        .argument = null,
        .line = line,
    };
}

const Three = struct {
    pub const World = struct { n: i64 = 0 };
    pub const steps = struct {
        pub fn one(w: *World) !void {
            _ = w;
            note("step one");
        }
        pub fn two(w: *World) !void {
            _ = w;
            note("step two");
            return error.Boom;
        }
        pub fn three(w: *World) !void {
            _ = w;
            note("step three");
        }
    };
    pub const hooks = struct {
        pub fn before(w: *World) !void {
            _ = w;
            note("before");
        }
        pub fn after(w: *World, r: Result) void {
            _ = w;
            note(switch (r) {
                .passed => "after passed",
                .failed => "after failed",
                .skipped => "after skipped",
            });
        }
        pub fn before_step(w: *World, s: gherkin.Step) !void {
            _ = .{ w, s };
            note("before_step");
        }
        pub fn after_step(w: *World, s: gherkin.Step, r: Result) void {
            _ = .{ w, s };
            note(switch (r) {
                .passed => "after_step passed",
                .failed => "after_step failed",
                .skipped => "after_step skipped",
            });
        }
    };
};

const three_steps = [_]gherkin.Step{ mkStep("one", 3), mkStep("two", 4), mkStep("three", 5) };

const scenario_three: Scenario = .{
    .name = "three",
    .tags = &.{},
    .file = "t.feature",
    .line = 2,
    .steps = &three_steps,
};

test "a failure at step two still reports all three steps" {
    trace_len = 0;
    try std.testing.expectError(error.Boom, runScenario(Three, scenario_three, false));
    try std.testing.expectEqualDeep(&[_][]const u8{
        "before",
        "before_step",
        "step one",
        "after_step passed",
        "before_step",
        "step two",
        "after_step failed",
        "after_step skipped",
        "after failed",
    }, traced());
}

const Skipping = struct {
    pub const World = struct { n: i64 = 0 };
    pub const steps = struct {
        pub fn one() !void {
            note("step one");
        }
        pub fn two() !void {
            note("step two");
            return error.SkipZigTest;
        }
        pub fn three() !void {
            note("step three");
        }
    };
    pub const hooks = struct {
        pub fn after(r: Result) void {
            note(switch (r) {
                .passed => "after passed",
                .failed => "after failed",
                .skipped => "after skipped",
            });
        }
        pub fn after_step(r: Result) void {
            note(switch (r) {
                .passed => "after_step passed",
                .failed => "after_step failed",
                .skipped => "after_step skipped",
            });
        }
    };
};

test "a skip at step two hands after an outcome of skipped" {
    trace_len = 0;
    try std.testing.expectError(error.SkipZigTest, run(Skipping, scenario_three));
    try std.testing.expectEqualDeep(&[_][]const u8{
        "step one",
        "after_step passed",
        "step two",
        "after_step skipped",
        "after_step skipped",
        "after skipped",
    }, traced());
}

const Ordered = struct {
    pub const steps = struct {
        pub fn one() void {
            note("step");
        }
    };
    pub const hooks = struct {
        pub fn @"before @db"() void {
            note("before db");
        }
        pub fn before() void {
            note("before plain");
        }
        pub fn @"after @db"() void {
            note("after db");
        }
        pub fn after() void {
            note("after plain");
        }
    };
};

const one_step = [_]gherkin.Step{mkStep("one", 2)};

const scenario_tagged: Scenario = .{
    .name = "s",
    .tags = &.{"db"},
    .file = "t.feature",
    .line = 1,
    .steps = &one_step,
};

const scenario_untagged: Scenario = .{
    .name = "s",
    .tags = &.{"other"},
    .file = "t.feature",
    .line = 1,
    .steps = &one_step,
};

const scenario_plain: Scenario = .{
    .name = "s",
    .tags = &.{},
    .file = "t.feature",
    .line = 1,
    .steps = &one_step,
};

test "before hooks run in declaration order and after hooks in reverse" {
    trace_len = 0;
    try run(Ordered, scenario_tagged);
    try std.testing.expectEqualDeep(&[_][]const u8{
        "before db",
        "before plain",
        "step",
        "after plain",
        "after db",
    }, traced());
}

test "a non-matching tag filter drops that hook" {
    trace_len = 0;
    try run(Ordered, scenario_untagged);
    try std.testing.expectEqualDeep(&[_][]const u8{
        "before plain",
        "step",
        "after plain",
    }, traced());
}

const FailingAfter = struct {
    pub const steps = struct {
        pub fn one() !void {
            return error.StepFailed;
        }
    };
    pub const hooks = struct {
        pub fn after() !void {
            return error.AfterFailed;
        }
    };
};

test "a failing after hook does not mask the step's error" {
    try std.testing.expectError(error.StepFailed, runScenario(FailingAfter, scenario_plain, false));
}

var deinit_calls: usize = 0;

const WithDeinit = struct {
    pub const World = struct {
        n: i64 = 0,
        pub fn deinit(w: *World) void {
            _ = w;
            deinit_calls += 1;
        }
    };
    pub const steps = struct {
        pub fn one(w: *World) !void {
            w.n = 1;
            return error.Boom;
        }
    };
};

test "deinit runs even when a step fails" {
    deinit_calls = 0;
    try std.testing.expectError(error.Boom, runScenario(WithDeinit, scenario_plain, false));
    try std.testing.expectEqual(@as(usize, 1), deinit_calls);
}

test "a scenario with captures and a table argument runs end to end" {
    const M = struct {
        pub const World = struct { total: i64 = 0, rows: usize = 0 };
        pub const steps = struct {
            pub fn @"I add {int}"(w: *World, n: i64) !void {
                w.total += n;
            }
            pub fn @"the users are"(w: *World, users: []const struct { name: []const u8, age: u32 }) !void {
                w.rows = users.len;
                try std.testing.expectEqualStrings("Alice", users[0].name);
                try std.testing.expectEqual(@as(u32, 30), users[0].age);
            }
            pub fn @"the total is {int}"(w: *World, want: i64) !void {
                try std.testing.expectEqual(want, w.total);
            }
        };
    };
    try run(M, scenario_e2e);
}

test "only functions in steps are candidate patterns" {
    const M = struct {
        pub const steps = struct {
            pub const shared_limit = 3;
            pub const Helper = struct {};
            pub fn @"I press add"() void {}
        };
    };
    try std.testing.expectError(BindError.UndefinedStep, comptime resolve(M, "shared_limit"));
    try std.testing.expectError(BindError.UndefinedStep, comptime resolve(M, "Helper"));
    const ok = comptime try resolve(M, "I press add");
    try std.testing.expectEqualStrings("I press add", ok.name);
}

const e2e_rows = [_]gherkin.Row{
    .{ .cells = &.{ "name", "age" }, .line = 4 },
    .{ .cells = &.{ "Alice", "30" }, .line = 5 },
};

const e2e_steps = [_]gherkin.Step{
    mkStep("I add 40", 2),
    mkStep("I add 2", 3),
    .{
        .keyword = .when,
        .keyword_text = "When",
        .text = "the users are",
        .argument = .{ .data_table = &e2e_rows },
        .line = 4,
    },
    mkStep("the total is 42", 6),
};

const scenario_e2e: Scenario = .{
    .name = "end to end",
    .tags = &.{},
    .file = "t.feature",
    .line = 1,
    .steps = &e2e_steps,
};

const FailingBefore = struct {
    pub const steps = struct {
        pub fn one() void {
            note("step one");
        }
        pub fn two() void {
            note("step two");
        }
        pub fn three() void {
            note("step three");
        }
    };
    pub const hooks = struct {
        pub fn before() !void {
            note("before");
            return error.BeforeFailed;
        }
        pub fn before_step() void {
            note("before_step");
        }
        pub fn after_step(r: Result) void {
            note(switch (r) {
                .passed => "after_step passed",
                .failed => "after_step failed",
                .skipped => "after_step skipped",
            });
        }
        pub fn after(r: Result) void {
            note(switch (r) {
                .passed => "after passed",
                .failed => "after failed",
                .skipped => "after skipped",
            });
        }
    };
};

test "a failing before hook still reports every step as skipped" {
    trace_len = 0;
    try std.testing.expectError(error.BeforeFailed, run(FailingBefore, scenario_three));
    try std.testing.expectEqualDeep(&[_][]const u8{
        "before",
        "after_step skipped",
        "after_step skipped",
        "after_step skipped",
        "after failed",
    }, traced());
}
