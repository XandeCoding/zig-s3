const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the s3 library module
    const s3_module = b.addModule("s3", .{
        .root_source_file = b.path("src/s3/lib.zig"),
        .target = target,
        .optimize = optimize,
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
    // Commons
    const errors_module = b.createModule(.{
        .root_source_file = b.path("src/s3/common/errors.zig"),
        .target = target,
        .optimize = optimize,
    });
    const encoding_module = b.createModule(.{
        .root_source_file = b.path("src/s3/common/encoding.zig"),
        .target = target,
        .optimize = optimize,
    });
    const validators_module = b.createModule(.{
        .root_source_file = b.path("src/s3/common/validators.zig"),
        .target = target,
        .optimize = optimize,
    });
    const xml_module = b.createModule(.{
        .root_source_file = b.path("src/s3/common/xml.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Auth
    const time_module = b.createModule(.{
        .root_source_file = b.path("src/s3/client/auth/time.zig"),
        .target = target,
        .optimize = optimize,
    });
    const signer_module = b.createModule(.{
        .root_source_file = b.path("src/s3/client/auth/signer.zig"),
        .target = target,
        .optimize = optimize,
    });

    signer_module.addImport("time", time_module);

    // Client
    const client_module = b.createModule(.{
        .root_source_file = b.path("src/s3/client/implementation.zig"),
        .target = target,
        .optimize = optimize,
    });
    client_module.addImport("time", time_module);
    client_module.addImport("signer", signer_module);
    client_module.addImport("../common/errors.zig", errors_module);

    // Bucket
    const bucket_module = b.createModule(.{
        .root_source_file = b.path("src/s3/bucket/operations.zig"),
        .target = target,
        .optimize = optimize,
    });
    bucket_module.addImport("../client/implementation.zig", client_module);
    bucket_module.addImport("../common/xml.zig", xml_module);
    bucket_module.addImport("../common/validators.zig", validators_module);
    bucket_module.addImport("../common/errors.zig", errors_module);

    // Object
    const object_module = b.createModule(.{
        .root_source_file = b.path("src/s3/object/operations.zig"),
        .target = target,
        .optimize = optimize,
    });
    object_module.addImport("../client/implementation.zig", client_module);
    object_module.addImport("../bucket/operations.zig", bucket_module);
    object_module.addImport("../common/encoding.zig", encoding_module);
    object_module.addImport("../common/xml.zig", xml_module);
    object_module.addImport("../common/validators.zig", validators_module);
    object_module.addImport("../common/errors.zig", errors_module);

    const modules_data = [_]struct { module: *std.Build.Module, filters: []const []const u8 }{
        .{ .module = encoding_module, .filters = &.{"encoding"} },
        .{ .module = time_module, .filters = &.{"time"} },
        .{ .module = validators_module, .filters = &.{ "validators"} },
        .{ .module = xml_module, .filters = &.{"xml"} },
        .{ .module = signer_module, .filters = &.{"signer"} },
        .{ .module = client_module, .filters = &.{"Client"} },
        .{ .module = bucket_module, .filters = &.{"bucket"} },
        .{ .module = object_module, .filters = &.{"object"} },
    };
    const test_runner = b.path("test_runner.zig");
    const test_step = b.step("test", "Run library tests");

    // Test flags
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match filters",
    ) orelse &.{};


    for (modules_data) |data| {
        var filters = data.filters;
        if (test_filters.len > 0) {
            filters = test_filters;
        }

        const unit_tests = b.addTest(.{
            .root_module = data.module,
            .test_runner = .{ .path = test_runner, .mode = .simple },
            .filters = filters,
        });
        const run_unit_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_unit_tests.step);
    }

    // Unit tests
    //const test_runner = b.path("test_runner.zig");
    //const lib_unit_tests = b.addTest(.{
    //    .root_module = s3_module,
    //    .test_runner = .{ .path = test_runner, .mode = .simple }
    //});
    //const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    //const test_step = b.step("test", "Run library tests");
    //test_step.dependOn(&run_lib_unit_tests.step);

    //const test_module = b.createModule(.{
    //    .root_source_file = b.path("src/s3/lib.zig"),
    //    .target = target,
    //    .optimize = optimize,
    //});
    //const unit_tests = b.addTest(.{ .root_module = test_module, .filters = test_filters });
    //unit_tests.root_module.addImport("dotenv", dotenv_dep.module("dotenv"));
    //const run_unit_tests = b.addRunArtifact(unit_tests);

    //const test_step = b.step("test", "Run library tests");
    //test_step.dependOn(&run_unit_tests.step);

    // Integration tests
    //const integration_test_module = b.createModule(.{
    //    .root_source_file = b.path("tests/integration/s3_client_test.zig"),
    //    .target = target,
    //    .optimize = optimize,
    //});
    //const integration_tests = b.addTest(.{
    //    .root_module = integration_test_module,
    //    .filters = test_filters,
    //});
    //integration_tests.root_module.addImport("s3", s3_module);
    //integration_tests.root_module.addImport("dotenv", dotenv_dep.module("dotenv"));

    //const run_integration_tests = b.addRunArtifact(integration_tests);
    //const integration_test_step = b.step("integration-test", "Run integration tests");
    //integration_test_step.dependOn(&run_integration_tests.step);

    //// Add integration tests to main test step
    //test_step.dependOn(&run_integration_tests.step);

    // Add formatting
    const fmt = b.addFmt(.{
        .paths = &.{ "src", "build.zig" },
        .check = true,
    });

    const fmt_step = b.step("fmt", "Format source files");
    fmt_step.dependOn(&fmt.step);
}
