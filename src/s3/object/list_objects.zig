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
const createBucket = @import("../bucket/create_bucket.zig").createBucket;
const deleteBucket = @import("../bucket/delete_bucket.zig").deleteBucket;

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

    const uri_str = try fmt.allocPrint(
        self.allocator, 
        "{s}/{s}?{s}",
        .{ self.config.endpoint, options.bucket_name, query.items }
    );
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

    const buckets_name: [1][]const u8 = .{ 
        "test-list-objects", "test-list-prefix",
        "test-list-pagination", "error-cases-test",
        "test-empty-bucket"
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

    // TODO: CHECK IF IT'S NECESSARY CREATE OTHER BUCKETS
    const test_objects = [_]struct { key: []const u8, content: []const u8 }{
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
    };

    // TODO: DEIXAR PARALELO
    for (test_objects) |obj| {
        try putObject(test_client, obj.bucket_name, obj.key, obj.content);
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
    const objects = try listObjects(test_client, bucket_name, .{});
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

    const config = client_impl.S3Config{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    };

    var test_client = try S3Client.init(allocator, io, config);
    defer test_client.deinit();

    // Create test bucket and objects
    const bucket_name = "test-list-prefix";

    // List objects with prefix
    // TODO: CHECK WITH PREFIX folder2/
    const objects = try listObjects(test_client, bucket_name, .{
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

    const config = client_impl.S3Config{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    };

    var test_client = try S3Client.init(allocator, io, config);
    defer test_client.deinit();

    // Create test bucket and objects
    const bucket_name = "test-list-pagination";

    // List first page (2 objects)
    const page1 = try listObjects(test_client, bucket_name, .{
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
    const page2 = try listObjects(test_client, bucket_name, .{
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

    // TODO: MAYBE IT'S GOOD TO CHECK THE CONTENT
    try std.testing.expectEqual(@as(usize, 2), page2.len);
    try std.testing.expect(!std.mem.eql(u8, page1[0].key, page2[0].key));
    try std.testing.expect(!std.mem.eql(u8, page1[1].key, page2[0].key));
}

test "list objects error cases" {
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

    // Test non-existent bucket
    try std.testing.expectError(
        error.BucketNotFound,
        listObjects(test_client, "nonexistent-bucket", .{}),
    );

    const bucket_name = "error-cases-test";

    // Test invalid max_keys
    try std.testing.expectError(
        error.InvalidResponse,
        listObjects(test_client, bucket_name, .{
            .max_keys = 1001, // Max allowed is 1000
        }),
    );
}

test "list objects empty bucket" {
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

    // List objects in empty bucket
    const objects = try listObjects(test_client, "test-empty-bucket", .{});
    defer allocator.free(objects);

    try std.testing.expectEqual(@as(usize, 0), objects.len);
}

// TODO: CHECAR SE É NECESSÁRIO DELETAR OS OBJETOS
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

    const buckets_name: [2][]const u8 = .{ "test-bucket-1", "test-bucket-2" };

    var threaded: std.Io.Threaded = .init(
        allocator,
        .{ .async_limit = .unlimited, .concurrent_limit = .unlimited },
    );
    defer threaded.deinit();
    var group: std.Io.Group = .init;
    const io_threaded = threaded.io();

    // Clean up
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
}
