const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the s3 library module
    const s3_module = b.addModule("s3", .{
        .root_source_file = b.path("src/s3/lib.zig"),
    });

    // dotenv library
    const dotenv_dep = b.dependency("dotenv", .{
        .target = target,
        .optimize = optimize,
    });

    // Create the library that others can use as a dependency
    const static_module = b.createModule(.{
        .root_source_file = b.path("src/s3/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "s3-client",
        .root_module = static_module,
    });

    lib.root_module.addImport("s3", s3_module);
    lib.root_module.addImport("dotenv", dotenv_dep.module("dotenv"));
    b.installArtifact(lib);

    const exec_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Create the example executable
    const exe = b.addExecutable(.{
        .name = "s3-example",
        .root_module = exec_module,
    });
    exe.root_module.addImport("s3", s3_module);
    exe.root_module.addImport("dotenv", dotenv_dep.module("dotenv"));
    b.installArtifact(exe);

    // Create "run" step for the example
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the example application");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/s3/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{ .root_module = test_module });
    unit_tests.root_module.addImport("dotenv", dotenv_dep.module("dotenv"));
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_unit_tests.step);

    // Integration tests
    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match filters") orelse &.{};
    const integration_test_module = b.createModule(.{
        .root_source_file = b.path("tests/integration/s3_client_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const integration_tests = b.addTest(.{
        .root_module = integration_test_module,
        .filters = test_filters,
    });
    integration_tests.root_module.addImport("s3", s3_module);
    integration_tests.root_module.addImport("dotenv", dotenv_dep.module("dotenv"));

    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_test_step = b.step("integration-test", "Run integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);

    // Add integration tests to main test step
    test_step.dependOn(&run_integration_tests.step);

    // Add formatting
    const fmt = b.addFmt(.{
        .paths = &.{ "src", "build.zig" },
        .check = true,
    });

    const fmt_step = b.step("fmt", "Format source files");
    fmt_step.dependOn(&fmt.step);
}
