const std = @import("std");
const fmt = std.fmt;
const Uri = std.Uri;
const Writer = std.Io.Writer;
const S3Error = @import("../common/errors.zig").S3Error;
const client_impl = @import("../client/implementation.zig");
const S3Client = client_impl.S3Client;
const putObject = @import("put_object.zig").putObject;
const createBucket = @import("../bucket/lib.zig").createBucket;
const deleteBucket = @import("../bucket/lib.zig").deleteBucket;

pub const DeleteObjectOptions = struct {
    bucket_name: []const u8,
    key: []const u8,
};

/// Delete an object from S3.
///
/// This operation cannot be undone unless versioning is enabled on the bucket.
///
/// Parameters:
///   - self: Pointer to initialized S3Client
///   - bucket_name: Name of the bucket containing the object
///   - key: Object key (path) to delete
///
/// Errors:
///   - InvalidResponse: If deletion fails
///   - BucketNotFound: If the bucket doesn't exist
///   - ConnectionFailed: Network or connection issues
///   - OutOfMemory: Memory allocation failure
pub fn deleteObject(self: *S3Client, options: DeleteObjectOptions) !void {
    const uri_str = try fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{ self.config.endpoint, options.bucket_name, options.key });
    defer self.allocator.free(uri_str);

    const req = try self.request(.DELETE, try Uri.parse(uri_str), null, null);

    if (req.status != .no_content) {
        return S3Error.InvalidResponse;
    }
}

test "Before All - Delete Object" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_client = try S3Client.init(allocator, io, client_impl.S3Config{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    });
    defer test_client.deinit();

    const buckets_name: [1][]const u8 = .{"object-delete-objects-list"};

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
    const test_objects = [_]struct { bucket_name: []const u8, key: []const u8, content: []const u8 }{
        .{ .bucket_name = "object-delete-objects-list", .key = "1", .content = "Hello, S3!" },
        .{ .bucket_name = "object-delete-objects-list", .key = "2", .content = "Hello, S3!" },
        .{ .bucket_name = "object-delete-objects-list", .key = "3", .content = "Hello, S3!" },
    };

    // TODO: DEIXAR PARALELO
    for (test_objects) |obj| {
        try putObject(test_client, .{ .bucket_name = obj.bucket_name, .key = obj.key, .data = obj.content });
    }
}

// TODO: REFACTOR THIS TEST
//test "delete objects list" {
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
//    const bucket_name = "object-delete-objects-list";
//
//    const test_data = "Hello, S3!";
//}

// TODO: CHECAR SE É NECESSÁRIO DELETAR OS OBJETOS
test "After All - Delete Objects" {
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
