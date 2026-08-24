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
    const bucket_imports: []const std.Build.Module.Import = &.{
        .{ .name = "../client/implementation.zig", .module = client_module },
        .{ .name = "../common/xml.zig", .module = xml_module },
        .{ .name = "../common/validators.zig", .module = validators_module },
        .{ .name = "../common/errors.zig", .module = errors_module },
    };

    const bucket_module = b.createModule(.{
        .root_source_file = b.path("src/s3/bucket/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = bucket_imports,
    });

    const create_bucket_module = b.createModule(.{
        .root_source_file = b.path("src/s3/bucket/create_bucket.zig"),
        .target = target,
        .optimize = optimize,
        .imports = bucket_imports,
    });
    const delete_bucket_module = b.createModule(.{
        .root_source_file = b.path("src/s3/bucket/delete_bucket.zig"),
        .target = target,
        .optimize = optimize,
        .imports = bucket_imports,
    });
    const list_buckets_module = b.createModule(.{
        .root_source_file = b.path("src/s3/bucket/list_buckets.zig"),
        .target = target,
        .optimize = optimize,
        .imports = bucket_imports,
    });

    // Object
    const object_imports: []const std.Build.Module.Import = &.{
        .{ .name = "../client/implementation.zig", .module = client_module },
        .{ .name = "../bucket/lib.zig", .module = bucket_module },
        .{ .name = "../common/encoding.zig", .module = encoding_module },
        .{ .name = "../common/xml.zig", .module = xml_module },
        .{ .name = "../common/validators.zig", .module = validators_module },
        .{ .name = "../common/errors.zig", .module = errors_module },
    };

    const get_object_module = b.createModule(.{
        .root_source_file = b.path("src/s3/object/get_object.zig"),
        .target = target,
        .optimize = optimize,
        .imports = object_imports,
    });
    const list_objects_module = b.createModule(.{
        .root_source_file = b.path("src/s3/object/list_objects.zig"),
        .target = target,
        .optimize = optimize,
        .imports = object_imports,
    });
    const put_object_module = b.createModule(.{
        .root_source_file = b.path("src/s3/object/put_object.zig"),
        .target = target,
        .optimize = optimize,
        .imports = object_imports,
    });
    const delete_object_module = b.createModule(.{
        .root_source_file = b.path("src/s3/object/delete_object.zig"),
        .target = target,
        .optimize = optimize,
        .imports = object_imports,
    });

    const object_uploader_module = b.createModule(.{
        .root_source_file = b.path("src/s3/object/object_uploader.zig"),
        .target = target,
        .optimize = optimize,
        .imports = object_imports,
    });
    const modules_data = [_]struct { module: *std.Build.Module, filters: []const []const u8 }{
        .{ .module = encoding_module, .filters = &.{"encoding"} },
        .{ .module = time_module, .filters = &.{"time"} },
        .{ .module = validators_module, .filters = &.{"validators"} },
        .{ .module = xml_module, .filters = &.{"xml"} },
        .{ .module = signer_module, .filters = &.{"signer"} },
        .{ .module = client_module, .filters = &.{"Client"} },
        .{ .module = create_bucket_module, .filters = &.{"create_bucket"} },
        .{ .module = delete_bucket_module, .filters = &.{"delete_bucket"} },
        .{ .module = list_buckets_module, .filters = &.{"list_buckets"} },
        .{ .module = get_object_module, .filters = &.{"get_object"} },
        .{ .module = list_objects_module, .filters = &.{"list_objects"} },
        .{ .module = put_object_module, .filters = &.{"put_object"} },
        .{ .module = delete_object_module, .filters = &.{"delete_object"} },
        .{ .module = object_uploader_module, .filters = &.{"object_uploader"} },
    };
    const test_runner = b.path("test_runner.zig");
    const test_step = b.step("test", "Run library tests");

    // Test flags
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match filters",
    ) orelse &.{};

    // Unit Tests
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

    // Integration tests
    //const integration_test_module = b.createModule(.{
    //    .root_source_file = b.path("tests/integration/s3_client_test.zig"),
    //    .target = target,
    //    .optimize = optimize,
    //});
    //const integration_tests = b.addTest(.{
    //    .root_module = integration_test_module,
    //    .test_runner = .{ .path = test_runner, .mode = .simple },
    //    .filters = test_filters,
    //});
    //integration_tests.root_module.addImport("s3", s3_module);

    //const run_integration_tests = b.addRunArtifact(integration_tests);
    //const integration_test_step = b.step("integration-test", "Run integration tests");
    //integration_test_step.dependOn(&run_integration_tests.step);

    // Add integration tests to main test step
    //test_step.dependOn(&run_integration_tests.step);

    // Add formatting
    const fmt = b.addFmt(.{
        .paths = &.{ "src", "build.zig" },
        .check = true,
    });

    const fmt_step = b.step("fmt", "Format source files");
    fmt_step.dependOn(&fmt.step);
}
