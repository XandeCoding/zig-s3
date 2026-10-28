const std = @import("std");
const fmt = std.fmt;
const Uri = std.Uri;
const Writer = std.Io.Writer;
const S3Error = @import("../common/errors.zig").S3Error;
const client_impl = @import("../client/implementation.zig");
const S3Client = client_impl.S3Client;

// TODO: IMPLEMENT OPTIONS IN https://docs.aws.amazon.com/AmazonS3/latest/API/API_DeleteObject.html
pub const DeleteObjectOptions = struct {};

/// Delete an object from S3.
///
/// This operation cannot be undone unless versioning is enabled on the bucket.
///
/// Parameters:
///   - self: Pointer to initialized S3Client
///   - options: Struct with delete options
///     - bucket_name: Name of the bucket containing the object
///     - key: Object key (path) to delete
///
/// Errors:
///   - InvalidResponse: If deletion fails
///   - BucketNotFound: If the bucket doesn't exist
///   - ConnectionFailed: Network or connection issues
///   - OutOfMemory: Memory allocation failure
pub fn deleteObject(self: *S3Client, bucket_name: []const u8, key: []const u8, _: DeleteObjectOptions) !void {
    const uri_str = try fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{ self.config.endpoint, bucket_name, key });
    defer self.allocator.free(uri_str);

    const req = try self.request(.DELETE, try Uri.parse(uri_str), null, null);

    if (req.status != .no_content) {
        return S3Error.InvalidResponse;
    }
}

test "delete object from inexistent bucket" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_client = try S3Client.init(allocator, io, client_impl.S3Config{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    });
    defer test_client.deinit();

    const bucket_name = "object-delete-objects-list";

    try std.testing.expectError(deleteObject(test_client, bucket_name, "object_key", .{}));
}
