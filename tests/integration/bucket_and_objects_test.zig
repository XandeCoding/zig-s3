const std = @import("std");
const s3 = @import("s3");

const testing = std.testing;
const io = testing.io;
const allocator = testing.allocator;

// At the top of the file, add ConnectionRefused to possible errors
const TestError = error{
    BucketNotFound,
    ConnectionRefused,
    MissingAccessKey,
    MissingSecretKey,
    MissingEndpoint,
    InvalidEndpoint,
    OperationTimeout,
    // ... other errors ...
};

fn createS3ClientConfig() !s3.S3ClientConfig {
    return s3.S3ClientConfig{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-west-1",
        .endpoint = "http://localhost:9000",
    };
}

test "initialize client" {
    const config = try createS3ClientConfig();
    var client = try s3.S3Client.init(allocator, io, config);
    defer client.deinit();

    try std.testing.expect(client.inner.config.endpoint.len > 0);
    try std.testing.expect(client.inner.config.secret_access_key.len > 0);
}

test "validate endpoint" {
    const config = try createS3ClientConfig();
    // Validate endpoint is not empty and accessible
    if (config.endpoint) |endpoint| {
        if (endpoint.len == 0) {
            return error.InvalidEndpoint;
        }
        // Try to parse the endpoint URL
        const uri = std.Uri.parse(endpoint) catch |err| {
            std.debug.print("Error parsing endpoint URL: {}\n", .{err});
            return error.InvalidEndpoint;
        };

        // Validate scheme
        if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) {
            std.debug.print("Error: Invalid scheme (must be http or https)\n", .{});
            return error.InvalidEndpoint;
        }
    } else {
        std.debug.print("Error: Missing endpoint URL\n", .{});
        return error.MissingEndpoint;
    }
}

test "create simple bucket" {
    const config = try createS3ClientConfig();
    var client = try s3.S3Client.init(allocator, io, config);
    defer client.deinit();
    const bucket_name = "integration-test-bucket-123";

    try client.createBucket(bucket_name, .{});
    defer _ = client.deleteBucket(bucket_name, .{}) catch {};

    // Verify the bucket exists by listing buckets
    const buckets = try client.listBuckets(.{});
    defer {
        for (buckets) |bucket| {
            allocator.free(bucket.name);
            allocator.free(bucket.creation_date);
        }
        allocator.free(buckets);
    }

    var bucket_found = false;
    for (buckets) |bucket| {
        if (std.mem.eql(u8, bucket.name, bucket_name)) {
            bucket_found = true;
            break;
        }
    }

    try testing.expect(bucket_found);
}

test "bucket operations with custom endpoint" {
    const config = try createS3ClientConfig();
    var client = try s3.S3Client.init(allocator, io, config);
    defer client.deinit();

    // Test bucket operations with custom endpoint
    const bucket_name = "test-bucket-local";
    try client.createBucket(bucket_name, .{});
    defer _ = client.deleteBucket(bucket_name, .{}) catch {};
}

test "create buckets with special characters" {
    const config = try createS3ClientConfig();
    var client = try s3.S3Client.init(allocator, io, config);
    defer client.deinit();

    // Test bucket names with various special characters
    const long_name: [60]u8 = @splat('a');
    const test_cases: [5][]const u8 = .{
        "normal-bucket-123", "bucket-with-dash",
        "bucket.with.dots",  "3-numeric-prefix",
        &long_name,
    };

    for (test_cases) |name| {
        try client.createBucket(name, .{});
    }
    defer {
        var threaded: std.Io.Threaded = .init(
            allocator,
            .{ .concurrent_limit = .unlimited },
        );
        defer threaded.deinit();
        var group: std.Io.Group = .init;
        const io_threaded = threaded.io();

        // Clean up
        for (test_cases) |name| {
            _ = group.concurrent(
                io_threaded,
                struct {
                    fn deleteBucketFn(
                        delete_client: *s3.S3Client,
                        delete_bucket_name: []const u8,
                    ) !void {
                        _ = delete_client.deleteBucket(delete_bucket_name, .{}) catch {};
                    }
                }.deleteBucketFn,
                .{ &client, name },
            ) catch {};
        }

        _ = group.await(io_threaded) catch {};
    }

    // Verify bucket exists
    const buckets = try client.listBuckets(.{});
    defer {
        for (buckets) |bucket| {
            allocator.free(bucket.name);
            allocator.free(bucket.creation_date);
        }
        allocator.free(buckets);
    }

    var buckets_found: usize = 0;
    for (buckets) |bucket| {
        for (test_cases) |name| {
            if (std.mem.eql(u8, bucket.name, name)) {
                buckets_found += 1;
                break;
            }
        }
    }

    try std.testing.expectEqual(buckets_found, test_cases.len);
}

test "list objects basic" {
    const config = try createS3ClientConfig();
    var client = try s3.S3Client.init(allocator, io, config);
    defer client.deinit();

    // Create test bucket and objects
    const bucket_name = "test-list-objects";
    try client.createBucket(bucket_name, .{});
    defer _ = client.deleteBucket(bucket_name, .{}) catch {};

    const test_objects = [_]struct { key: []const u8, content: []const u8 }{
        .{ .key = "test1.txt", .content = "Hello 1" },
        .{ .key = "test2.txt", .content = "Hello 2" },
        .{ .key = "folder/test3.txt", .content = "Hello 3" },
    };

    for (test_objects) |object| {
        try client.putObject(bucket_name, object.key, object.content, .{});
    }

    // List all objects
    const objects = try client.listObjects(bucket_name, .{});
    defer {
        for (objects) |object| {
            allocator.free(object.key);
            allocator.free(object.last_modified);
            allocator.free(object.etag);
        }
        allocator.free(objects);
    }

    try std.testing.expectEqual(test_objects.len, objects.len);

    // Verify each object
    for (objects) |object| {
        var found = false;
        for (test_objects) |test_obj| {
            if (std.mem.eql(u8, object.key, test_obj.key)) {
                found = true;
                try std.testing.expectEqual(test_obj.content.len, object.size);
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "list objects empty bucket" {
    const config = try createS3ClientConfig();
    var client = try s3.S3Client.init(allocator, io, config);
    defer client.deinit();

    // List objects in empty bucket
    const bucket_name = "test-empty-bucket";
    try client.createBucket(bucket_name, .{});
    defer _ = client.deleteBucket(bucket_name, .{}) catch {};

    const objects = try client.listObjects(bucket_name, .{});
    defer allocator.free(objects);

    try std.testing.expectEqual(@as(usize, 0), objects.len);
}

test "list objects with multiple prefixes" {
    const config = try createS3ClientConfig();
    var client = try s3.S3Client.init(allocator, io, config);
    defer client.deinit();

    const bucket_name = "test-prefix-bucket";
    try client.createBucket(bucket_name, .{});
    defer _ = client.deleteBucket(bucket_name, .{}) catch {};
    const test_objects = [_]struct { key: []const u8, content: []const u8 }{
        .{ .key = "folder1/a.txt", .content = "Hello 1" },
        .{ .key = "folder1/b.txt", .content = "Hello 2" },
        .{ .key = "folder2/c.txt", .content = "Hello 3" },
        .{ .key = "folder2/subfolder/d.txt", .content = "Hello 4" },
        .{ .key = "folder3/e.txt", .content = "Hello 5" },
        .{ .key = "root.txt", .content = "Hello 6" },
    };
    
    for (test_objects) |object| {
        try client.putObject(bucket_name, object.key, object.content, .{});
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
        const objects = try client.listObjects(bucket_name, .{ .prefix = case.prefix });
        defer {
            for (objects) |object| {
                _= client.deleteObject(bucket_name, object.key, .{}) catch {};
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
    const config = try createS3ClientConfig();
    var client = try s3.S3Client.init(allocator, io, config);
    defer client.deinit();

    const bucket_name = "test-pagination-bucket";
    try client.createBucket(bucket_name, .{});
    defer _ = client.deleteBucket(bucket_name, .{}) catch {};

    // Create 25 test objects
    const total_objects = 25;
    for (1 .. 25) |index| {
        const key = try std.fmt.allocPrint(allocator, "obj{d:0>3}.txt", .{index});
        defer allocator.free(key);
        try client.putObject(bucket_name, key, "Hello Test", .{});
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
        var attempts: u8 = 10;
        while (attempts > 0) {
            attempts = attempts - 1;
            const page = try client.listObjects(
                bucket_name,
                .{ .max_keys = page_size, .start_after = last_key },
            );
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
            const expected = try std.fmt.allocPrint(allocator, "obj{d:0>3}.txt", .{idx});
            defer {
                _ = client.deleteObject(bucket_name, expected, .{}) catch {};
                allocator.free(expected);
            }
            try std.testing.expectEqualStrings(expected, key);
        }
    }
}

test "list objects with special characters in prefix" {
    const config = try createS3ClientConfig();
    var client = try s3.S3Client.init(allocator, io, config);
    defer client.deinit();

    const bucket_name = "test-special-chars";
    try client.createBucket(bucket_name, .{});
    defer _ = client.deleteBucket(bucket_name, .{}) catch {};

    // Objects with special characters in paths
    const test_objects = [_]struct { key: []const u8, content: []const u8 }{
        .{ .key = "special!chars/test1.txt", .content = "1" },
        .{ .key = "special@chars/test2.txt", .content = "2" },
        .{ .key = "special*chars/test3.txt", .content = "3" },
        .{ .key = "special$chars/test4.txt", .content = "4" },
        .{ .key = "special_chars/test5.txt", .content = "5" },
        .{ .key = "special:20chars/test6.txt", .content = "6" },
        .{ .key = "special+chars/test7.txt", .content = "7" },
    };

    for (test_objects) |object| {
        try client.putObject(bucket_name, object.key, object.content, .{});
    }

    // Test listing with various special character prefixes
    for (test_objects) |obj| {
        const prefix = obj.key[0 .. std.mem.indexOf(u8, obj.key, "/").? + 1];
        const objects = try client.listObjects(bucket_name, .{ .prefix = prefix });
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
test "pagination and prefixes" {
    // Initialize client
    const config = try createS3ClientConfig();
    var client = try s3.S3Client.init(allocator, io, config);
    defer client.deinit();

    const bucket_name = "pagination-test-bucket";
    try client.createBucket(bucket_name, .{});
    defer _ = client.deleteBucket(bucket_name, .{}) catch {};

    // Create test objects with different prefixes
    const prefixes = [_][]const u8{ "folder1/", "folder2/", "folder3/" };
    var total_objects: usize = 0;

    for (prefixes) |prefix| {
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            const key = try std.fmt.allocPrint(
                allocator,
                "{s}file{d}.txt",
                .{ prefix, i },
            );
            defer allocator.free(key);
            const content = try std.fmt.allocPrint(
                allocator,
                "Content {d}",
                .{i},
            );
            defer allocator.free(content);
            try client.putObject(bucket_name, key, content, .{});
            total_objects += 1;
        }
    }

    // Test listing with different page sizes
    {
        const page_size: u32 = 7;
        var all_objects: std.ArrayList([]u8) = .empty;
        defer {
            for (all_objects.items) |object| {
                allocator.free(object);
            }
            all_objects.deinit(allocator);
        }

        var max_attempts: u16 = 10;
        while (max_attempts > 0) {
            max_attempts = max_attempts - 1;
            const page = try client.listObjects(bucket_name, .{
                .max_keys = page_size,
                .start_after = all_objects.getLastOrNull(),
            });

            defer {
                for (page) |item| {
                    allocator.free(item.key);
                    allocator.free(item.last_modified);
                    allocator.free(item.etag);
                }
                allocator.free(page);
            }

            if (page.len == 0) break;
            for (page) |data| {
                const key = try allocator.dupe(u8, data.key);
                try all_objects.append(allocator, key);
            }

            if (page.len < page_size) break;
        }

        try testing.expectEqual(total_objects, all_objects.items.len);
    }

    // Test listing with prefix
    for (prefixes) |prefix| {
        const objects = try client.listObjects(bucket_name, .{
            .prefix = prefix,
        });
        defer {
            var threaded: std.Io.Threaded = .init(
                allocator,
                .{ .async_limit = .unlimited, .concurrent_limit = .unlimited },
            );
            defer threaded.deinit();
            var group: std.Io.Group = .init;
            const io_threaded = threaded.io();

            // Clean up
            for (objects) |obj| {
                _ = group.concurrent(
                    io_threaded,
                    struct {
                        fn deleteObjectFn(
                            delete_client: *s3.S3Client,
                            delete_bucket_name: []const u8,
                            key: []const u8,
                        ) !void {
                            _ = delete_client.deleteObject(delete_bucket_name, key, .{}) catch {};
                        }
                    }.deleteObjectFn,
                    .{ &client, bucket_name, obj.key },
                ) catch {};
            }

            _ = group.await(io_threaded) catch {};

            for (objects) |object| {
                allocator.free(object.key);
                allocator.free(object.last_modified);
                allocator.free(object.etag);
            }
            allocator.free(objects);
        }

        try testing.expectEqual(@as(usize, 5), objects.len);
        for (objects) |object| {
            try testing.expect(std.mem.startsWith(u8, object.key, prefix));
        }
    }
}

test "put large object" {
    // Initialize client
    const config = try createS3ClientConfig();
    var client = try s3.S3Client.init(allocator, io, config);
    defer client.deinit();

    // Create large test data (1MB)
    const data_size = 10 * 1024 * 1024;
    var large_data = try allocator.alloc(u8, data_size);
    defer allocator.free(large_data);

    for (0..data_size) |i| {
        large_data[i] = @as(u8, @truncate(i));
    }
    const bucket_name = "large-data-test";
    try client.createBucket(bucket_name, .{});
    defer _ = client.deleteBucket(bucket_name, .{}) catch {};

    // Test large object operations
    try client.putObject(bucket_name, "large-file.bin", large_data, .{});

    const retrieved = try client.getObject(bucket_name, "large-file.bin", .{});
    defer allocator.free(retrieved);

    try std.testing.expectEqualSlices(u8, large_data, retrieved);
}

test "put objects with valid keys" {
    // Initialize client
    const config = try createS3ClientConfig();
    var client = try s3.S3Client.init(allocator, io, config);
    defer client.deinit();

    const bucket_name = "object-valid-name-bucket";
    try client.createBucket(bucket_name, .{});
    defer _ = client.deleteBucket(bucket_name, .{}) catch {};

    // Test valid object keys
    const valid_keys = [_][]const u8{
        "valid/key.txt",
        "path/to/object.json",
        "special-chars_!@$&*().txt",
    };

    for (valid_keys) |key| {
        const test_data = "Test data";
        try client.putObject(bucket_name, key, test_data, .{});

        const retrieved = try client.getObject(bucket_name, key, .{});
        defer allocator.free(retrieved);

        try std.testing.expectEqualStrings(test_data, retrieved);
    }
}
