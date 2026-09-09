const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addModule("zig_cucumber", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const codegen_mod = b.addModule("codegen", .{ .root_source_file = b.path("src/codegen.zig") });

    // The generator the consumer's build runs. Installed so a consumer can
    // reach it with dep.artifact("zig-cucumber-gen").
    const gen = b.addExecutable(.{
        .name = "zig-cucumber-gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    gen.root_module.addImport("codegen", codegen_mod);
    b.installArtifact(gen);

    const mod_tests = b.addTest(.{ .root_module = lib });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);

    // The library's own features, run the way a consumer's are, so that
    // `zig build test` compiles and runs generated source.
    _ = featureTests(b, test_step, gen, lib, .{
        .features = b.path("test/features"),
        .steps = b.path("test/steps.zig"),
        .target = target,
        .optimize = optimize,
    });
}

/// Options for `addFeatureTests`.
pub const FeatureTestOptions = struct {
    /// Directory holding `.feature` files, searched recursively.
    features: std.Build.LazyPath,
    /// The user's step-definition module root.
    steps: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// Extra modules the step definitions may import.
    imports: []const std.Build.Module.Import = &.{},
    /// Tag expression selecting scenarios, usually from `b.option`.
    tags: ?[]const u8 = null,
    /// Test-name substring, usually from `b.option`.
    filter: ?[]const u8 = null,
};

/// Generates one Zig test per scenario and attaches them to `test_step`.
/// Returns the test artifact, for a consumer that wants to install it or give
/// it more imports.
pub fn addFeatureTests(
    b: *std.Build,
    test_step: *std.Build.Step,
    dep: *std.Build.Dependency,
    options: FeatureTestOptions,
) *std.Build.Step.Compile {
    return featureTests(
        b,
        test_step,
        dep.artifact("zig-cucumber-gen"),
        dep.module("zig_cucumber"),
        options,
    );
}

/// `addFeatureTests` against a generator and a library module the caller
/// already holds, which is how this package tests itself.
fn featureTests(
    b: *std.Build,
    test_step: *std.Build.Step,
    gen: *std.Build.Step.Compile,
    cucumber: *std.Build.Module,
    options: FeatureTestOptions,
) *std.Build.Step.Compile {
    const run_gen = b.addRunArtifact(gen);
    run_gen.has_side_effects = true;
    run_gen.addDirectoryArg(options.features);
    const gen_dir = run_gen.addOutputDirectoryArg("features");
    if (options.tags) |t| {
        run_gen.addArg("--tags");
        run_gen.addArg(t);
    }

    const steps_mod = b.createModule(.{
        .root_source_file = options.steps,
        .target = options.target,
        .optimize = options.optimize,
    });
    steps_mod.addImport("zig_cucumber", cucumber);
    for (options.imports) |imp| steps_mod.addImport(imp.name, imp.module);

    const generated = b.createModule(.{
        .root_source_file = gen_dir.path(b, "root.zig"),
        .target = options.target,
        .optimize = options.optimize,
    });
    generated.addImport("zig_cucumber", cucumber);
    generated.addImport("steps", steps_mod);

    const tests = b.addTest(.{ .root_module = generated });
    if (options.filter) |f| {
        tests.filters = b.allocator.dupe([]const u8, &[_][]const u8{f}) catch @panic("OOM");
    }
    test_step.dependOn(&b.addRunArtifact(tests).step);
    return tests;
}
