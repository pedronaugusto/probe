const std = @import("std");

/// What a project that depends on probe builds: the `probe` module, on
/// aegis. The tests, checks and gate are `dev`'s.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("probe", .{ .root_source_file = b.path("src/probe.zig"), .target = target, .optimize = optimize });
    addSourceImports(b, module, target, optimize);
}

/// What probe's sources import: aegis.
fn addSourceImports(p: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) void {
    module.addImport("aegis", p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis"));
}

/// probe's development: its tests and checks under preflight's gate. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const package = b.dependency("probe", .{ .target = target, .optimize = optimize });
    const p = package.builder;
    const filters = if (test_filter) |filter| &.{filter} else &.{};
    const shakedown = b.dependency("shakedown", .{ .target = target, .optimize = optimize });
    const test_module = b.createModule(.{
        .root_source_file = p.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "shakedown", .module = shakedown.module("shakedown") }},
    });
    addSourceImports(p, test_module, target, optimize);
    const tests = b.addTest(.{ .name = "probe-tests", .filters = filters, .root_module = test_module });
    const check = b.step("check", "Compile the tests without running them");
    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    check.dependOn(&tests.step);
    b.getInstallStep().dependOn(&tests.step);
    // The release tier runs every property under Zig's fuzzer (each shakedown
    // property is a fuzz target) and the suite with safety on.
    tools.preflight.addCi(b, p, .{
        .tests = test_step,
        .portable_tests = true,
        .hardened = .{ .fuzz_step = "test", .tsan_step = "test" },
    });
    // A project that depends on probe by path, with aegis and nothing else
    // to fetch: the build a consumer gets.
    tools.preflight.addConsumerCheck(b, p, .{
        .package = "probe",
        .program = p.path("ci/consumer.zig"),
        .packages = &.{p.dependency("aegis", .{})},
    });
}
