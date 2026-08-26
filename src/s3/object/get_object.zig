const std = @import("std");
const fmt = std.fmt;
const Uri = std.Uri;
const Writer = std.Io.Writer;
const S3Error = @import("../common/errors.zig").S3Error;
const client_impl = @import("../client/implementation.zig");
const S3Client = client_impl.S3Client;

pub const GetObjectOptions = struct {
    bucket_name: []const u8,
    key: []const u8,
};

/// Download an object from S3.
///
/// Currently limited to objects up to 1MB in size.
/// For larger objects, streaming download support is needed (TODO).
///
/// Parameters:
///   - self: Pointer to initialized S3Client
///   - options: Struct with get options
///     - bucket_name: Name of the bucket containing the object
///     - key: Object key (path) in the bucket
///
/// Returns: Object content as a slice. Caller owns the memory.
///
/// Errors:
///   - ObjectNotFound: If the object doesn't exist
///   - BucketNotFound: If the bucket doesn't exist
///   - InvalidResponse: If download fails
///   - ConnectionFailed: Network or connection issues
///   - OutOfMemory: Memory allocation failure
pub fn getObject(self: *S3Client, options: GetObjectOptions) ![]const u8 {
    const uri_str = try fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{ self.config.endpoint, options.bucket_name, options.key });
    defer self.allocator.free(uri_str);

    var alloc_writer = try Writer.Allocating.initCapacity(self.allocator, 1024 * 1024);
    defer alloc_writer.deinit();
    const req = try self.request(.GET, try Uri.parse(uri_str), &alloc_writer.writer, null);

    if (req.status == .not_found) {
        return S3Error.ObjectNotFound;
    }
    if (req.status != .ok) {
        return S3Error.InvalidResponse;
    }

    return alloc_writer.toOwnedSlice();
}

test "get not existent object" {
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

    // Test object not found
    try std.testing.expectError(
        error.ObjectNotFound,
        getObject(test_client, .{ .bucket_name = "test-bucket", .key = "nonexistent-key" }),
    );
}
