const std = @import("std");
const Uri = std.Uri;
const validators = @import("../common/validators.zig");
const S3Error = @import("../common/errors.zig").S3Error;
const client_impl = @import("../client/implementation.zig");
const S3Client = client_impl.S3Client;
const createBucket = @import("../bucket/lib.zig").createBucket;
const deleteBucket = @import("../bucket/lib.zig").deleteBucket;
const getObject = @import("./get_object.zig").getObject;
const deleteObject = @import("./delete_object.zig").deleteObject;

// TODO: implement object_lock
pub const PutObjectOptions = struct {
    bucket_name: []const u8,
    key: []const u8,
    data: []const u8,
    object_lock: ?bool = null,
};

/// Upload an object to S3.
///
/// Currently supports objects up to the size of available memory.
/// For larger objects, streaming upload support is needed (TODO).
///
/// Parameters:
///   - self: Pointer to initialized S3Client
///   - bucket_name: Name of the target bucket
///   - key: Object key (path) in the bucket
///   - data: Object content to upload
///
/// Errors:
///   - InvalidObjectKey: Invalid object key
///   - InvalidResponse: If upload fails
///   - BucketNotFound: If the bucket doesn't exist
///   - ConnectionFailed: Network or connection issues
///   - OutOfMemory: Memory allocation failure
pub fn putObject(self: *S3Client, options: PutObjectOptions) !void {
    const key = options.key;
    if (validators.objectNameIsValid(key) == false) return S3Error.InvalidObjectKey;

    const uri_str = try std.fmt.allocPrint(
        self.allocator,
        "{s}/{s}/{s}",
        .{ self.config.endpoint, options.bucket_name, key },
    );
    defer self.allocator.free(uri_str);

    const req = try self.request(.PUT, try Uri.parse(uri_str), null, options.data);

    if (req.status == .bad_request) {
        return S3Error.InvalidObjectKey;
    }
    if (req.status != .ok) {
        return S3Error.InvalidResponse;
    }
}

test "Before All - Put Object" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_client = try S3Client.init(allocator, io, client_impl.S3Config{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    });
    defer test_client.deinit();

    const buckets_name: [3][]const u8 = .{
        "large-data-test",          "object-invalid-name-bucket",
        "object-valid-name-bucket",
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
}

test "put an invalid key" {
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

    // Test invalid object key
    const invalid_key = "";
    try std.testing.expectError(
        error.InvalidObjectKey,
        putObject(test_client, .{
            .bucket_name = "test-bucket",
            .key = invalid_key,
            .data = "test data",
        }),
    );
}

test "put large file" {
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

    // Create large test data (1MB)
    const data_size = 1024 * 1024;
    var large_data = try allocator.alloc(u8, data_size);
    defer allocator.free(large_data);

    for (0..data_size) |i| {
        large_data[i] = @as(u8, @truncate(i));
    }
    const bucket_name = "large-data-test";

    // Test large object operations
    try putObject(test_client, .{
        .bucket_name = bucket_name,
        .key = "large-file.bin",
        .data = large_data,
    });

    const retrieved = try getObject(test_client, .{ .bucket_name = bucket_name, .key = "large-file.bin" });
    defer allocator.free(retrieved);

    try std.testing.expectEqualSlices(u8, large_data, retrieved);
}

test "put invalid keys" {
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

    const bucket_name = "object-invalid-name-bucket";

    // Test various invalid object keys
    const invalid_keys = [_][]const u8{
        "", // Empty
        "key\nwith\nnewlines", // Contains newlines
        "key with\x00null", // Contains null byte
        "a" ** 1025, // Too long (max is 1024)
    };

    for (invalid_keys) |key| {
        try std.testing.expectError(
            error.InvalidObjectKey,
            putObject(test_client, .{
                .bucket_name = bucket_name,
                .key = key,
                .data = "test data",
            }),
        );
    }
}

test "put valid keys" {
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

    const bucket_name = "object-valid-name-bucket";

    // Test valid object keys
    const valid_keys = [_][]const u8{
        "valid/key.txt",
        "path/to/object.json",
        "special-chars_!@$&*().txt",
    };

    for (valid_keys) |key| {
        const test_data = "Test data";
        try putObject(test_client, .{
            .bucket_name = bucket_name,
            .key = key,
            .data = test_data,
        });

        const retrieved = try getObject(
            test_client,
            .{ .bucket_name = bucket_name, .key = key },
        );
        defer allocator.free(retrieved);

        try std.testing.expectEqualStrings(test_data, retrieved);
    }
}

test "After All - Put Object" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_client = try S3Client.init(allocator, io, client_impl.S3Config{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    });
    defer test_client.deinit();

    const buckets_name: [3][]const u8 = .{
        "large-data-test",          "object-invalid-name-bucket",
        "object-valid-name-bucket",
    };
    var threaded: std.Io.Threaded = .init(
        allocator,
        .{ .concurrent_limit = .unlimited },
    );
    defer threaded.deinit();
    var group: std.Io.Group = .init;
    const io_threaded = threaded.io();

    const test_objects = [_]struct { bucket_name: []const u8, key: []const u8 }{
        .{ .bucket_name = "large-data-test", .key = "large-file.bin" },
        .{ .bucket_name = "object-valid-name-bucket", .key = "valid/key.txt" },
        .{ .bucket_name = "object-valid-name-bucket", .key = "path/to/object.json" },
        .{ .bucket_name = "object-valid-name-bucket", .key = "special-chars_!@$&*().txt" },
    };

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

    try group.await(io_threaded);
}
