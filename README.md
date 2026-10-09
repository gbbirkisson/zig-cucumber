# cucumber-zig

Cucumber-style BDD for Zig. Write `.feature` files in Gherkin, write step
definitions as plain Zig functions, and get one `zig test` case per scenario.

Step resolution happens at comptime: a feature file that names a step you have
not defined is a compile error.

## Requirements

Zig `0.17.0` or newer.

## Install

```bash
zig fetch --save git+https://github.com/gbbirkisson/cucumber-zig
```

## Use

Three files. A feature file:

```gherkin
Feature: Adding

  Background:
    Given a fresh calculator

  @math
  Scenario: two numbers
    When I add 40
    And I add 2
    Then the total is 42
```

The steps that satisfy it, where the function name is the Cucumber Expression
and the parameters are bound from the captures:

```zig
const std = @import("std");
const cucumber = @import("cucumber_zig");

pub const World = struct {
    total: i64 = 0,
};

pub const steps = struct {
    pub fn @"a fresh calculator"(w: *World) !void {
        w.total = 0;
    }

    pub fn @"I add {int}"(w: *World, n: i64) !void {
        w.total += n;
    }

    pub fn @"the total is {int}"(w: *World, want: i64) !void {
        try std.testing.expectEqual(want, w.total);
    }
};
```

And the wiring, in your `build.zig`:

```zig
const std = @import("std");
const cucumber_build = @import("cucumber_zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run feature tests");
    const dep = b.dependency("cucumber_zig", .{ .target = target, .optimize = optimize });

    _ = cucumber_build.addFeatureTests(b, test_step, dep, .{
        .features = b.path("test/features"),
        .steps = b.path("test/steps.zig"),
        .target = target,
        .optimize = optimize,
    });
}
```

Then:

```bash
zig build test
```

Each scenario becomes one test, named after its feature, scenario and tags:

```
Adding: two numbers [@math]
```

## Examples

Each is a standalone project you can copy. Together they cover the whole
feature set of this package.

| Example | Shows |
|---|---|
| [arguments](examples/arguments) | data tables raw and as typed structs, doc strings, media types |
| [calculator](examples/calculator) | the minimal case: a feature, a background, a scenario outline, a World with state |
| [expressions](examples/expressions) | every capture kind, (optionals, alternation, escaping, enums, typed table rows |
| [hooks](examples/hooks) | all four hook phases, a tag-filtered hook, a World holding an allocator and an `Io` |
| [meta](examples/meta) | this library's Gherkin parser, tested in Gherkin |
| [structure](examples/structure) | rules, nested backgrounds, scenario outlines, tags at all four levels |

## Selecting scenarios

`addFeatureTests` takes optional `tags` and `filter` fields, which the examples
wire to `-Dtags` and `-Dfilter`:

```bash
zig build test -Dtags="@math and not @wip"
zig build test -Dfilter="two numbers"
```

A tag expression that matches nothing fails the build rather than reporting a
green run with no tests. A `-Dfilter` that matches nothing does not: it passes
with zero tests.

## Development

```bash
zig build test     # the library's own tests
zig build examples # every example's tests, in a nested build each
zig fmt --check .
```
