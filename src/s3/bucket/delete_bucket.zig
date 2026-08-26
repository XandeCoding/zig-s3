const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;
const Uri = std.Uri;
const fmt = std.fmt;

const client_impl = @import("../client/implementation.zig");
const S3Error = @import("../common/errors.zig").S3Error;
const S3Client = client_impl.S3Client;

pub const DeleteBucketOptions = struct {
    bucket_name: []const u8,
    expected_bucket_owner: ?[]const u8 = null,
};

// TODO: IMPLEMENTS EXPECTED BUCKET OWNER
/// Delete an existing bucket from S3.
///
/// The bucket must be empty before it can be deleted.
/// This operation cannot be undone.
///
/// Parameters:
///   - self: Pointer to initialized S3Client
///   - options: Struct with delete options
///     - bucket_name: Name of the bucket to delete
///
/// Errors:
///   - InvalidResponse: If bucket deletion fails (e.g., bucket not empty)
///   - InvalidCredentials: Invalid credentials used
///   - BucketNotFound: If the bucket doesn't exist
///   - ConnectionFailed: Network or connection issues
///   - OutOfMemory: Memory allocation failure
pub fn deleteBucket(self: *S3Client, options: DeleteBucketOptions) !void {
    const bucket_name = options.bucket_name;
    const uri_str = try fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.config.endpoint, bucket_name });
    defer self.allocator.free(uri_str);

    const response = try self.request(.DELETE, try Uri.parse(uri_str), null, null);

    switch (response.status) {
        .no_content => {},
        .unauthorized, .forbidden => {
            return S3Error.InvalidCredentials;
        },
        .not_found => {
            return S3Error.BucketNotFound;
        },
        .bad_request => {
            return S3Error.InvalidResponse;
        },
        else => {
            return S3Error.InvalidResponse;
        },
    }
}

test "delete bucket operations error handling" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_client = try S3Client.init(allocator, io, client_impl.S3Config{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    });
    defer test_client.deinit();

    // Test bucket not found
    try std.testing.expectError(
        error.BucketNotFound,
        deleteBucket(test_client, .{ .bucket_name = "nonexistent-bucket" }),
    );
}

test "bucket delete with custom endpoint" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_client = try S3Client.init(allocator, io, client_impl.S3Config{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    });
    defer test_client.deinit();

    // Test bucket operations with custom endpoint
    try deleteBucket(test_client, .{ .bucket_name = "test-bucket-local" });
}
