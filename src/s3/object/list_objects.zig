const std = @import("std");
const fmt = std.fmt;
const Uri = std.Uri;
const Writer = std.Io.Writer;
const S3Error = @import("../common/errors.zig").S3Error;
const encoding = @import("../common/encoding.zig");
const xml = @import("../common/xml.zig");
const client_impl = @import("../client/implementation.zig");
const S3Client = client_impl.S3Client;
const putObject = @import("put_object.zig").putObject;
const deleteObject = @import("delete_object.zig").deleteObject;
const createBucket = @import("../bucket/lib.zig").createBucket;
const deleteBucket = @import("../bucket/lib.zig").deleteBucket;

/// Object information returned by listObjects
pub const ObjectInfo = struct {
    /// Key (path) of the object
    key: []const u8,
    /// Size of the object in bytes
    size: u64,
    /// Last modified timestamp as ISO-8601 string
    last_modified: []const u8,
    /// ETag of the object (usually MD5 of content)
    etag: []const u8,
};

/// Options for listing objects
pub const ListObjectsOptions = struct {
    bucket_name: []const u8,
    /// Filter objects by prefix
    prefix: ?[]const u8 = null,
    /// Maximum number of objects to return (1-1000)
    max_keys: ?u32 = null,
    /// Start listing from this key (for pagination)
    start_after: ?[]const u8 = null,
};

/// List objects in a bucket.
///
/// This implements the S3 ListObjectsV2 API.
/// Results are sorted by key in lexicographical order.
///
/// Parameters:
///   - self: Pointer to initialized S3Client
///   - bucket_name: Name of the bucket to list
///   - options: Optional listing parameters (prefix, pagination)
///
/// Returns: Slice of ObjectInfo structs. Caller owns the memory.
///
/// Errors:
///   - BucketNotFound: If the bucket doesn't exist
///   - InvalidResponse: If listing fails or response is malformed
///   - ConnectionFailed: Network or connection issues
///   - OutOfMemory: Memory allocation failure
pub fn listObjects(
    self: *S3Client,
    options: ListObjectsOptions,
) ![]ObjectInfo {
    // Build query string
    var query = std.ArrayList(u8).empty;
    defer {
        query.deinit(self.allocator);
    }

    try query.appendSlice(self.allocator, "list-type=2"); // Use ListObjectsV2

    if (options.prefix) |prefix| {
        const prefix_value = try encoding.encodeURI(self.allocator, prefix);
        defer self.allocator.free(prefix_value);

        try query.appendSlice(self.allocator, "&prefix=");
        try query.appendSlice(self.allocator, prefix_value);
    }

    if (options.max_keys) |max_keys| {
        if (max_keys > 1000) return S3Error.InvalidResponse;

        var buf: [4]u8 = undefined;
        const max_keys_string = try encoding.encodeURI(self.allocator, try std.fmt.bufPrint(&buf, "{d}", .{max_keys}));
        defer self.allocator.free(max_keys_string);

        try query.appendSlice(self.allocator, "&max-keys=");
        try query.appendSlice(self.allocator, max_keys_string);
    }

    if (options.start_after) |start_after| {
        const start_after_value = try encoding.encodeURI(self.allocator, start_after);
        defer self.allocator.free(start_after_value);

        try query.appendSlice(self.allocator, "&start-after=");
        try query.appendSlice(self.allocator, start_after_value);
    }

    const uri_str = try fmt.allocPrint(self.allocator, "{s}/{s}?{s}", .{ self.config.endpoint, options.bucket_name, query.items });
    defer self.allocator.free(uri_str);

    var alloc_writer = try Writer.Allocating.initCapacity(self.allocator, 4096);
    defer alloc_writer.deinit();

    const response = try self.request(.GET, try Uri.parse(uri_str), &alloc_writer.writer, null);

    if (response.status == .not_found) {
        return S3Error.BucketNotFound;
    }
    if (response.status != .ok) {
        return S3Error.InvalidResponse;
    }

    const body = alloc_writer.written();
    // Parse XML response
    var objects = std.ArrayList(ObjectInfo).empty;
    errdefer {
        for (objects.items) |object| {
            self.allocator.free(object.key);
            self.allocator.free(object.last_modified);
            self.allocator.free(object.etag);
        }
        objects.deinit(self.allocator);
    }

    // Simple XML parsing - look for <Contents> elements
    var it = std.mem.splitSequence(u8, body, "<Contents>");
    _ = it.first(); // Skip first part before any <Contents>

    while (it.next()) |object_xml| {
        const key = try xml.getByKey(self.allocator, object_xml, "Key");
        const last_modified = try xml.getByKey(self.allocator, object_xml, "LastModified");
        const etag = try xml.getByKey(self.allocator, object_xml, "ETag");

        const size_string = try xml.getByKey(self.allocator, object_xml, "Size");
        defer self.allocator.free(size_string);
        const size = try std.fmt.parseInt(u64, size_string, 10);

        try objects.append(self.allocator, .{
            .key = key,
            .size = size,
            .last_modified = last_modified,
            .etag = etag,
        });
    }

    return objects.toOwnedSlice(self.allocator);
}

test "Before All - List Objects" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_client = try S3Client.init(allocator, io, client_impl.S3Config{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    });
    defer test_client.deinit();

    const buckets_name: [8][]const u8 = .{
        "test-list-objects",      "test-list-prefix",
        "test-list-pagination",   "error-cases-test",
        "test-empty-bucket",      "test-prefix-bucket",
        "test-pagination-bucket", "test-special-chars",
    };

    var threaded: std.Io.Threaded = .init(
        allocator,
        .{ .async_limit = .unlimited, .concurrent_limit = .unlimited },
    );
    defer threaded.deinit();
    var group: std.Io.Group = .init;
    const io_threaded = threaded.io();

    // Start up
    for (buckets_name) |name| {
        try group.concurrent(
            io_threaded,
            struct {
                fn createBucketFn(client: *S3Client, bucket_name: []const u8) !void {
                    _ = createBucket(client, .{ .bucket_name = bucket_name }) catch {};
                }
            }.createBucketFn,
            .{ test_client, name },
        );
    }

    try group.await(io_threaded);

    const test_objects = [49]struct { bucket_name: []const u8, key: []const u8, content: []const u8 }{
        .{ .bucket_name = "test-list-objects", .key = "test1.txt", .content = "Hello 1" },
        .{ .bucket_name = "test-list-objects", .key = "test2.txt", .content = "Hello 2" },
        .{ .bucket_name = "test-list-objects", .key = "folder/test3.txt", .content = "Hello 3" },
        .{ .bucket_name = "test-list-prefix", .key = "folder1/test1.txt", .content = "Hello 1" },
        .{ .bucket_name = "test-list-prefix", .key = "folder1/test2.txt", .content = "Hello 2" },
        .{ .bucket_name = "test-list-prefix", .key = "folder2/test3.txt", .content = "Hello 3" },
        .{ .bucket_name = "test-list-pagination", .key = "test1.txt", .content = "Content 1" },
        .{ .bucket_name = "test-list-pagination", .key = "test2.txt", .content = "Content 2" },
        .{ .bucket_name = "test-list-pagination", .key = "test3.txt", .content = "Content 3" },
        .{ .bucket_name = "test-list-pagination", .key = "test4.txt", .content = "Content 4" },
        .{ .bucket_name = "test-list-pagination", .key = "test5.txt", .content = "Content 5" },
        .{ .bucket_name = "test-prefix-bucket", .key = "folder1/a.txt", .content = "a" },
        .{ .bucket_name = "test-prefix-bucket", .key = "folder1/b.txt", .content = "b" },
        .{ .bucket_name = "test-prefix-bucket", .key = "folder2/c.txt", .content = "c" },
        .{ .bucket_name = "test-prefix-bucket", .key = "folder2/subfolder/d.txt", .content = "d" },
        .{ .bucket_name = "test-prefix-bucket", .key = "folder3/e.txt", .content = "e" },
        .{ .bucket_name = "test-prefix-bucket", .key = "root.txt", .content = "root" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj000.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj001.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj002.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj003.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj004.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj005.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj006.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj007.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj008.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj009.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj010.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj011.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj012.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj013.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj014.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj015.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj016.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj017.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj018.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj019.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj020.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj021.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj022.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj023.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj024.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-special-chars", .key = "special!chars/test1.txt", .content = "1" },
        .{ .bucket_name = "test-special-chars", .key = "special@chars/test2.txt", .content = "2" },
        .{ .bucket_name = "test-special-chars", .key = "special*chars/test3.txt", .content = "3" },
        .{ .bucket_name = "test-special-chars", .key = "special$chars/test4.txt", .content = "4" },
        .{ .bucket_name = "test-special-chars", .key = "special_chars/test5.txt", .content = "5" },
        .{ .bucket_name = "test-special-chars", .key = "special:20chars/test6.txt", .content = "6" },
        .{ .bucket_name = "test-special-chars", .key = "special+chars/test7.txt", .content = "7" },
    };

    for (test_objects) |obj| {
        try group.concurrent(
            io_threaded,
            struct {
                fn putObjectFn(client: *S3Client, bucket_name: []const u8, key: []const u8, data: []const u8) !void {
                    _ = putObject(client, .{
                        .bucket_name = bucket_name,
                        .key = key,
                        .data = data,
                    }) catch {};
                }
            }.putObjectFn,
            .{ test_client, obj.bucket_name, obj.key, obj.content },
        );

        try group.await(io_threaded);
    }
}

test "list objects basic" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_client = try S3Client.init(allocator, io, .{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    });
    defer test_client.deinit();

    // Create test bucket and objects
    const bucket_name = "test-list-objects";

    const test_objects = [_]struct { key: []const u8, content: []const u8 }{
        .{ .key = "test1.txt", .content = "Hello 1" },
        .{ .key = "test2.txt", .content = "Hello 2" },
        .{ .key = "folder/test3.txt", .content = "Hello 3" },
    };

    // List all objects
    const objects = try listObjects(test_client, .{ .bucket_name = bucket_name });
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

test "list objects with prefix" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_client = try S3Client.init(allocator, io, .{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    });
    defer test_client.deinit();

    // Create test bucket and objects
    const bucket_name = "test-list-prefix";

    // List objects with prefix
    const objects = try listObjects(test_client, .{
        .bucket_name = bucket_name,
        .prefix = "folder1/",
    });
    defer {
        for (objects) |object| {
            allocator.free(object.key);
            allocator.free(object.last_modified);
            allocator.free(object.etag);
        }
        allocator.free(objects);
    }

    try std.testing.expectEqual(@as(usize, 2), objects.len);

    // Verify each object starts with prefix
    for (objects) |object| {
        try std.testing.expect(std.mem.startsWith(u8, object.key, "folder1/"));
    }
}

test "list objects pagination" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_client = try S3Client.init(allocator, io, .{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    });
    defer test_client.deinit();

    // Create test bucket and objects
    const bucket_name = "test-list-pagination";

    // List first page (2 objects)
    const page1 = try listObjects(test_client, .{
        .bucket_name = bucket_name,
        .max_keys = 2,
    });
    defer {
        for (page1) |object| {
            allocator.free(object.key);
            allocator.free(object.last_modified);
            allocator.free(object.etag);
        }
        allocator.free(page1);
    }

    try std.testing.expectEqual(@as(usize, 2), page1.len);

    // List second page using start_after
    const page2 = try listObjects(test_client, .{
        .bucket_name = bucket_name,
        .max_keys = 2,
        .start_after = page1[1].key,
    });
    defer {
        for (page2) |object| {
            allocator.free(object.key);
            allocator.free(object.last_modified);
            allocator.free(object.etag);
        }
        allocator.free(page2);
    }

    try std.testing.expectEqual(@as(usize, 2), page2.len);
    try std.testing.expect(!std.mem.eql(u8, page1[0].key, page2[0].key));
    try std.testing.expect(!std.mem.eql(u8, page1[1].key, page2[0].key));
}

test "list objects error cases" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_client = try S3Client.init(allocator, io, .{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    });
    defer test_client.deinit();

    // Test non-existent bucket
    try std.testing.expectError(
        error.BucketNotFound,
        listObjects(test_client, .{ .bucket_name = "nonexistent-bucket" }),
    );

    const bucket_name = "error-cases-test";

    // Test invalid max_keys
    try std.testing.expectError(
        error.InvalidResponse,
        listObjects(test_client, .{
            .bucket_name = bucket_name,
            .max_keys = 1001, // Max allowed is 1000
        }),
    );
}

test "list objects empty bucket" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_client = try S3Client.init(allocator, io, .{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    });
    defer test_client.deinit();

    // List objects in empty bucket
    const objects = try listObjects(test_client, .{ .bucket_name = "test-empty-bucket" });
    defer allocator.free(objects);

    try std.testing.expectEqual(@as(usize, 0), objects.len);
}

test "list objects with multiple prefixes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_client = try S3Client.init(allocator, io, .{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    });
    defer test_client.deinit();

    const bucket_name = "test-prefix-bucket";

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
        const objects = try listObjects(test_client, .{
            .bucket_name = bucket_name,
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

    var test_client = try S3Client.init(allocator, io, .{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    });
    defer test_client.deinit();

    const bucket_name = "test-pagination-bucket";

    // Create 25 test objects
    const total_objects = 25;

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
            const page = try listObjects(test_client, .{
                .bucket_name = bucket_name,
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

    var test_client = try S3Client.init(allocator, io, .{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    });
    defer test_client.deinit();

    const bucket_name = "test-special-chars";

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

    // Test listing with various special character prefixes
    for (test_objects) |obj| {
        const prefix = obj.key[0 .. std.mem.indexOf(u8, obj.key, "/").? + 1];
        const objects = try listObjects(test_client, .{
            .bucket_name = bucket_name,
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

test "After All - List Objects" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_client = try S3Client.init(allocator, io, client_impl.S3Config{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    });
    defer test_client.deinit();

    const buckets_name: [8][]const u8 = .{
        "test-list-objects",      "test-list-prefix",
        "test-list-pagination",   "error-cases-test",
        "test-empty-bucket",      "test-prefix-bucket",
        "test-pagination-bucket", "test-special-chars",
    };

    const test_objects = [49]struct { bucket_name: []const u8, key: []const u8, content: []const u8 }{
        .{ .bucket_name = "test-list-objects", .key = "test1.txt", .content = "Hello 1" },
        .{ .bucket_name = "test-list-objects", .key = "test2.txt", .content = "Hello 2" },
        .{ .bucket_name = "test-list-objects", .key = "folder/test3.txt", .content = "Hello 3" },
        .{ .bucket_name = "test-list-prefix", .key = "folder1/test1.txt", .content = "Hello 1" },
        .{ .bucket_name = "test-list-prefix", .key = "folder1/test2.txt", .content = "Hello 2" },
        .{ .bucket_name = "test-list-prefix", .key = "folder2/test3.txt", .content = "Hello 3" },
        .{ .bucket_name = "test-list-pagination", .key = "test1.txt", .content = "Content 1" },
        .{ .bucket_name = "test-list-pagination", .key = "test2.txt", .content = "Content 2" },
        .{ .bucket_name = "test-list-pagination", .key = "test3.txt", .content = "Content 3" },
        .{ .bucket_name = "test-list-pagination", .key = "test4.txt", .content = "Content 4" },
        .{ .bucket_name = "test-list-pagination", .key = "test5.txt", .content = "Content 5" },
        .{ .bucket_name = "test-prefix-bucket", .key = "folder1/a.txt", .content = "a" },
        .{ .bucket_name = "test-prefix-bucket", .key = "folder1/b.txt", .content = "b" },
        .{ .bucket_name = "test-prefix-bucket", .key = "folder2/c.txt", .content = "c" },
        .{ .bucket_name = "test-prefix-bucket", .key = "folder2/subfolder/d.txt", .content = "d" },
        .{ .bucket_name = "test-prefix-bucket", .key = "folder3/e.txt", .content = "e" },
        .{ .bucket_name = "test-prefix-bucket", .key = "root.txt", .content = "root" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj000.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj001.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj002.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj003.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj004.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj005.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj006.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj007.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj008.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj009.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj010.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj011.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj012.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj013.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj014.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj015.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj016.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj017.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj018.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj019.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj020.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj021.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj022.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj023.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-pagination-bucket", .key = "obj024.txt", .content = "Content pagination" },
        .{ .bucket_name = "test-special-chars", .key = "special!chars/test1.txt", .content = "1" },
        .{ .bucket_name = "test-special-chars", .key = "special@chars/test2.txt", .content = "2" },
        .{ .bucket_name = "test-special-chars", .key = "special*chars/test3.txt", .content = "3" },
        .{ .bucket_name = "test-special-chars", .key = "special$chars/test4.txt", .content = "4" },
        .{ .bucket_name = "test-special-chars", .key = "special_chars/test5.txt", .content = "5" },
        .{ .bucket_name = "test-special-chars", .key = "special:20chars/test6.txt", .content = "6" },
        .{ .bucket_name = "test-special-chars", .key = "special+chars/test7.txt", .content = "7" },
    };

    var threaded: std.Io.Threaded = .init(
        allocator,
        .{ .async_limit = .unlimited, .concurrent_limit = .unlimited },
    );
    defer threaded.deinit();
    var group: std.Io.Group = .init;
    const io_threaded = threaded.io();

    // Clean up
    for (test_objects) |obj| {
        try group.concurrent(
            io_threaded,
            struct {
                fn deleteObjectFn(client: *S3Client, bucket_name: []const u8, key: []const u8) !void {
                    _ = deleteObject(client, .{ .bucket_name = bucket_name, .key = key }) catch {};
                }
            }.deleteObjectFn,
            .{ test_client, obj.bucket_name, obj.key },
        );
    }

    try group.await(io_threaded);

    for (buckets_name) |name| {
        try group.concurrent(
            io_threaded,
            struct {
                fn deleteBucketFn(client: *S3Client, bucket_name: []const u8) !void {
                    _ = deleteBucket(client, .{ .bucket_name = bucket_name }) catch {};
                }
            }.deleteBucketFn,
            .{ test_client, name },
        );
    }

    try group.await(io_threaded);
}
