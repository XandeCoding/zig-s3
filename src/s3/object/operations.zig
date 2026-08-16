/// Object operations for S3 client.
/// This module implements basic object operations like upload, download, and deletion.
const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;
const Uri = std.Uri;
const fmt = std.fmt;
const fs = std.fs;
const Writer = std.Io.Writer;

const client_impl = @import("../client/implementation.zig");
const bucket_ops = @import("../bucket/operations.zig");
const encoding = @import("../common/encoding.zig");
const xml = @import("../common/xml.zig");
const validators = @import("../common/validators.zig");
const S3Error = @import("../common/errors.zig").S3Error;
const S3Client = client_impl.S3Client;



// TODO: CHECK IF CAN BE MOVED TO INTEGRATION TESTS

//test "object operations" {
//    const allocator = std.testing.allocator;
//    const io = std.testing.io;
//
//    const config = client_impl.S3Config{
//        .access_key_id = "admin",
//        .secret_access_key = "admin",
//        .region = "us-east-1",
//        .endpoint = "http://localhost:9000",
//    };
//
//    var test_client = try S3Client.init(allocator, io, config);
//    defer test_client.deinit();
//
//    const bucket_name = "object-operations-test";
//    try bucket_ops.createBucket(test_client, bucket_name);
//    defer _ = bucket_ops.deleteBucket(test_client, .{ .bucket_name = bucket_name }) catch {};
//
//    // Test basic object lifecycle
//    const test_data = "Hello, S3!";
//    try putObject(test_client, bucket_name, "admin", test_data);
//
//    const retrieved = try getObject(test_client, bucket_name, "admin");
//    defer allocator.free(retrieved);
//    try std.testing.expectEqualStrings(test_data, retrieved);
//
//    try deleteObject(test_client, bucket_name, "admin");
//}

//test "object operations with custom endpoint" {
//    const allocator = std.testing.allocator;
//    const io = std.testing.io;
//
//    const config = client_impl.S3Config{
//        .access_key_id = "admin",
//        .secret_access_key = "admin",
//        .region = "us-east-1",
//        .endpoint = "http://localhost:9000",
//    };
//
//    var test_client = try S3Client.init(allocator, io, config);
//    defer test_client.deinit();
//
//    // Test object operations with custom endpoint
//    const bucket_name = "custom-endpoint-bucket";
//    try bucket_ops.createBucket(test_client, bucket_name);
//    defer _ = bucket_ops.deleteBucket(test_client, .{ .bucket_name = bucket_name }) catch {};
//
//    const test_data = "Testing with custom endpoint";
//    try putObject(test_client, bucket_name, "custom-endpoint-test.txt", test_data);
//
//    const retrieved = try getObject(test_client, bucket_name, "custom-endpoint-test.txt");
//    defer allocator.free(retrieved);
//
//    try std.testing.expectEqualStrings(test_data, retrieved);
//
//    try deleteObject(test_client, bucket_name, "custom-endpoint-test.txt");
//}

test "list objects with multiple prefixes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const config = client_impl.S3Config{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    };

    var test_client = try S3Client.init(allocator, io, config);
    defer test_client.deinit();

    const bucket_name = "test-prefix-bucket";
    try bucket_ops.createBucket(test_client, bucket_name);
    defer _ = bucket_ops.deleteBucket(test_client, .{ .bucket_name = bucket_name }) catch {};

    // Create objects with different prefixes
    const test_objects = [_]struct { key: []const u8, content: []const u8 }{
        .{ .key = "folder1/a.txt", .content = "a" },
        .{ .key = "folder1/b.txt", .content = "b" },
        .{ .key = "folder2/c.txt", .content = "c" },
        .{ .key = "folder2/subfolder/d.txt", .content = "d" },
        .{ .key = "folder3/e.txt", .content = "e" },
        .{ .key = "root.txt", .content = "root" },
    };

    // Upload test objects
    for (test_objects) |obj| {
        try putObject(test_client, bucket_name, obj.key, obj.content);
    }
    defer {
        var delete_list = std.ArrayList(DeleteObjectParam).empty;
        defer delete_list.deinit(allocator);

        for (test_objects) |object| {
            _ = delete_list.append(allocator, .{ .key = object.key }) catch {};
        }
        _ = deleteObjectList(test_client, bucket_name, delete_list.items) catch {};
    }

    // Test different prefix scenarios
    const test_cases = [_]struct {
        prefix: []const u8,
        expected_count: usize,
    }{
        .{ .prefix = "folder1/", .expected_count = 2 },
        .{ .prefix = "folder2/", .expected_count = 2 },
        .{ .prefix = "folder2/subfolder/", .expected_count = 1 },
        .{ .prefix = "folder3/", .expected_count = 1 },
        .{ .prefix = "", .expected_count = 6 }, // All objects
        .{ .prefix = "nonexistent/", .expected_count = 0 },
    };

    for (test_cases) |case| {
        const objects = try listObjects(test_client, bucket_name, .{
            .prefix = case.prefix,
        });
        defer {
            for (objects) |object| {
                allocator.free(object.key);
                allocator.free(object.last_modified);
                allocator.free(object.etag);
            }
            allocator.free(objects);
        }

        try std.testing.expectEqual(case.expected_count, objects.len);

        // Verify all objects start with prefix
        for (objects) |object| {
            if (case.prefix.len > 0) {
                try std.testing.expect(std.mem.startsWith(u8, object.key, case.prefix));
            }
        }
    }
}

test "list objects pagination with various sizes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const config = client_impl.S3Config{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    };

    var test_client = try S3Client.init(allocator, io, config);
    defer test_client.deinit();

    const bucket_name = "test-pagination-bucket";
    try bucket_ops.createBucket(test_client, bucket_name);
    defer _ = bucket_ops.deleteBucket(test_client, .{ .bucket_name = bucket_name }) catch {};

    // Create 25 test objects
    const total_objects = 25;
    var i: usize = 0;
    while (i < total_objects) : (i += 1) {
        const key = try fmt.allocPrint(allocator, "obj{d:0>3}.txt", .{i}); // pad with zeros for correct sorting
        defer allocator.free(key);

        const content = try fmt.allocPrint(allocator, "Content {d}", .{i});
        defer allocator.free(content);

        try putObject(test_client, bucket_name, key, content);
    }
    defer {
        var delete_list = std.ArrayList(DeleteObjectParam).empty;
        defer delete_list.deinit(allocator);

        i = 0;
        while (i < total_objects) : (i += 1) {
            const key = fmt.allocPrint(allocator, "obj{d:0>3}.txt", .{i}) catch continue;
            _ = delete_list.append(allocator, .{ .key = key }) catch {};
        }

        _ = deleteObjectList(test_client, bucket_name, delete_list.items) catch {};

        for (delete_list.items) |object| {
            allocator.free(object.key);
        }
    }

    // Test different page sizes
    const page_sizes = [_]u32{ 5, 10, 15 };
    for (page_sizes) |page_size| {
        var collected_objects = std.ArrayList([]const u8).empty;
        defer {
            for (collected_objects.items) |key| {
                allocator.free(key);
            }
            collected_objects.deinit(allocator);
        }

        var last_key: ?[]const u8 = null;
        while (true) {
            const page = try listObjects(test_client, bucket_name, .{
                .max_keys = page_size,
                .start_after = last_key,
            });
            defer {
                for (page) |object| {
                    allocator.free(object.last_modified);
                    allocator.free(object.etag);
                    allocator.free(object.key);
                }
                allocator.free(page);
            }

            if (page.len == 0) break;

            for (page) |object| {
                if (last_key == null or !std.mem.eql(u8, object.key, last_key.?)) {
                    try collected_objects.append(allocator, try allocator.dupe(u8, object.key));
                }
            }

            if (page.len < page_size) break;

            if (last_key) |key| {
                allocator.free(key);
            }
            last_key = try allocator.dupe(u8, page[page.len - 1].key);
        }

        if (last_key) |key| {
            allocator.free(key);
        }

        // Verify we got all objects and they're in order
        try std.testing.expectEqual(@as(usize, total_objects), collected_objects.items.len);
        for (collected_objects.items, 0..) |key, idx| {
            const expected = try fmt.allocPrint(allocator, "obj{d:0>3}.txt", .{idx});
            defer allocator.free(expected);
            try std.testing.expectEqualStrings(expected, key);
        }
    }
}

test "list objects with special characters in prefix" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const config = client_impl.S3Config{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    };

    var test_client = try S3Client.init(allocator, io, config);
    defer test_client.deinit();

    const bucket_name = "test-special-chars";
    try bucket_ops.createBucket(test_client, bucket_name);
    defer _ = bucket_ops.deleteBucket(test_client, .{ .bucket_name = bucket_name }) catch {};

    // Create objects with special characters in paths
    const test_objects = [_]struct { key: []const u8, content: []const u8 }{
        .{ .key = "special!chars/test1.txt", .content = "1" },
        .{ .key = "special@chars/test2.txt", .content = "2" },
        .{ .key = "special*chars/test3.txt", .content = "3" },
        .{ .key = "special$chars/test4.txt", .content = "4" },
        .{ .key = "special_chars/test5.txt", .content = "5" },
        .{ .key = "special:20chars/test6.txt", .content = "6" },
        .{ .key = "special+chars/test7.txt", .content = "7" },
    };

    // Upload test objects
    for (test_objects) |obj| {
        try putObject(test_client, bucket_name, obj.key, obj.content);
    }
    defer {
        var delete_list = std.ArrayList(DeleteObjectParam).empty;
        defer delete_list.deinit(allocator);

        for (test_objects) |object| {
            _ = delete_list.append(allocator, .{ .key = object.key }) catch {};
        }

        _ = deleteObjectList(test_client, bucket_name, delete_list.items) catch {};
    }

    // Test listing with various special character prefixes
    for (test_objects) |obj| {
        const prefix = obj.key[0 .. std.mem.indexOf(u8, obj.key, "/").? + 1];
        const objects = try listObjects(test_client, bucket_name, .{
            .prefix = prefix,
        });
        defer {
            for (objects) |object| {
                allocator.free(object.key);
                allocator.free(object.last_modified);
                allocator.free(object.etag);
            }
            allocator.free(objects);
        }

        try std.testing.expectEqual(@as(usize, 1), objects.len);
        try std.testing.expectEqualStrings(obj.key, objects[0].key);
    }
}

test "ObjectUploader basic functionality" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const config = client_impl.S3Config{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    };

    var test_client = try S3Client.init(allocator, io, config);
    defer test_client.deinit();

    // Create test bucket
    const bucket_name = "test-uploader";
    try bucket_ops.createBucket(test_client, bucket_name);
    defer _ = bucket_ops.deleteBucket(test_client, .{ .bucket_name = bucket_name }) catch {};

    var uploader = ObjectUploader.init(test_client);

    // Test string upload
    const test_string = "Hello, World!";
    try uploader.uploadString(bucket_name, "test.txt", test_string);

    // Verify string upload
    const retrieved_string = try getObject(test_client, bucket_name, "test.txt");
    defer allocator.free(retrieved_string);
    try std.testing.expectEqualStrings(test_string, retrieved_string);

    // Test JSON upload
    const TestStructType = struct {
        name: []const u8,
        value: i32,
        tags: [2][]const u8,
    };

    const test_json: TestStructType = .{
        .name = "test",
        .value = 42,
        .tags = [2][]const u8{ "tag1", "tag2" },
    };
    try uploader.uploadJson(bucket_name, "test.json", test_json);

    // Verify JSON upload
    const retrieved_json = try getObject(test_client, bucket_name, "test.json");
    defer allocator.free(retrieved_json);

    // Parse and verify JSON content
    const parsed = try std.json.parseFromSlice(
        TestStructType,
        allocator,
        retrieved_json,
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("test", parsed.value.name);
    try std.testing.expectEqual(@as(i64, 42), parsed.value.value);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.tags.len);
    try std.testing.expectEqualStrings("tag1", parsed.value.tags[0]);
    try std.testing.expectEqualStrings("tag2", parsed.value.tags[1]);

    // Clean up test objects
    var delete_object_list: [2]DeleteObjectParam = .{
        .{ .key = "test.txt" }, .{ .key = "test.json" },
    };
    try deleteObjectList(test_client, bucket_name, &delete_object_list);
}

test "ObjectUploader file operations" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const config = client_impl.S3Config{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    };

    var test_client = try S3Client.init(allocator, io, config);
    defer test_client.deinit();

    // Create test bucket
    const bucket_name = "test-file-uploader";
    try bucket_ops.createBucket(test_client, bucket_name);
    defer _ = bucket_ops.deleteBucket(test_client, .{ .bucket_name = bucket_name }) catch {};

    var uploader = ObjectUploader.init(test_client);

    // Create a temporary test file
    const test_content = "Test file content";
    const test_filename = "test-upload.txt";

    // Create temporary directory for test files
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();

    // Create and write test file
    {
        const file = try directory.dir.createFile(io, test_filename, .{});
        defer file.close(io);
        try file.writePositionalAll(io, test_content, 0);
    }

    // Test file upload
    const file_path = try directory.dir.realPathFileAlloc(io, test_filename, allocator);
    defer allocator.free(file_path);
    try uploader.uploadFile(bucket_name, "uploaded.txt", file_path);

    // Verify file upload
    const retrieved_content = try getObject(test_client, bucket_name, "uploaded.txt");
    defer allocator.free(retrieved_content);
    try std.testing.expectEqualStrings(test_content, retrieved_content);

    // Clean up test object
    try deleteObject(test_client, bucket_name, "uploaded.txt");
}

test "ObjectUploader error cases" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const config = client_impl.S3Config{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    };

    var test_client = try S3Client.init(allocator, io, config);
    defer test_client.deinit();

    var uploader = ObjectUploader.init(test_client);

    // Test non-existent bucket
    try std.testing.expectError(
        error.InvalidResponse,
        uploader.uploadString("nonexistent-bucket", "test.txt", "test"),
    );

    // Test invalid object key
    try std.testing.expectError(
        error.InvalidObjectKey,
        uploader.uploadString("test-bucket", "", "test"),
    );

    // Test non-existent file
    try std.testing.expectError(
        error.FileNotFound,
        uploader.uploadFile("test-bucket", "test.txt", "nonexistent/file.txt"),
    );
}

test "ObjectUploader with custom endpoint" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const config = client_impl.S3Config{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    };

    var test_client = try S3Client.init(allocator, io, config);
    defer test_client.deinit();

    var uploader = ObjectUploader.init(test_client);

    // Create test bucket
    const bucket_name = "test-custom-endpoint";
    try bucket_ops.createBucket(test_client, bucket_name);
    defer _ = bucket_ops.deleteBucket(test_client, .{ .bucket_name = bucket_name }) catch {};

    // Test basic upload with custom endpoint
    const test_data = "Testing with custom endpoint";
    try uploader.uploadString(bucket_name, "test.txt", test_data);

    // Verify upload
    const retrieved = try getObject(test_client, bucket_name, "test.txt");
    defer allocator.free(retrieved);
    try std.testing.expectEqualStrings(test_data, retrieved);

    // Clean up
    try deleteObject(test_client, bucket_name, "test.txt");
}
