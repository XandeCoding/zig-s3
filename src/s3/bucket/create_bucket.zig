const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;
const Uri = std.Uri;
const fmt = std.fmt;

const client_impl = @import("../client/implementation.zig");
const S3Error = @import("../common/errors.zig").S3Error;
const S3Client = client_impl.S3Client;
const validators = @import("../common/validators.zig");

pub const CreateBucketOptions = struct {
    object_lock: ?bool = null,
};

/// Create a new bucket in S3.
///
/// The bucket name must be globally unique across all AWS accounts.
/// For S3-compatible services, uniqueness might only be required within your endpoint.
///
/// Parameters:
///   - self: Pointer to initialized S3Client
///   - options: Struct with create options
///     - bucket_name: Name of the bucket to create
///     - object_lock: Flag to lock objects deletion
///
/// Errors:
///   - Conflict: The bucket name already exists
///   - BadRequest: Invalid bucket name
///   - Forbidden: Access Denied
///   - ServiceUnavailable: Service it's unavailable
///   - NotImplemented: This function it's not implemented in current S3 server
///   - InvalidResponse: If bucket creation fails (e.g., name already taken)
///   - ConnectionFailed: Network or connection issues
///   - OutOfMemory: Memory allocation failure
pub fn createBucket(self: *S3Client, bucket_name: []const u8, _: CreateBucketOptions) !void {
    // TODO: IMPLEMENT OBJECT LOCK
    if (validators.bucketNameIsValid(bucket_name) == false) {
        return S3Error.InvalidBucketName;
    }

    const uri_str = try fmt.allocPrint(
        self.allocator,
        "{s}/{s}",
        .{ self.config.endpoint, bucket_name },
    );
    defer self.allocator.free(uri_str);

    const req = try self.request(.PUT, try Uri.parse(uri_str), null, null);

    if (req.status != .ok and req.status != .created) {
        switch (req.status) {
            .conflict => {
                return S3Error.BucketAlreadyExists;
            },
            .bad_request => {
                return S3Error.InvalidBucketName;
            },
            .forbidden => {
                return S3Error.AccessDenied;
            },
            .service_unavailable => {
                return S3Error.ServiceUnavailable;
            },
            // RustFS implemented name validation partially
            .not_implemented => {
                return S3Error.ServerNotImplemented;
            },
            else => {
                return S3Error.InvalidResponse;
            },
        }
    }
}

test "create bucket with empty strings" {
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

    // Test empty bucket name
    try std.testing.expectError(
        error.InvalidBucketName,
        createBucket(test_client, "", .{}),
    );
}

test "create bucket operation error cases" {
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

    // Test creating bucket with invalid characters
    try std.testing.expectError(
        error.InvalidBucketName,
        createBucket(test_client, "Invalid.Bucket.Name", .{}),
    );

    // Test creating bucket with invalid length
    try std.testing.expectError(
        error.InvalidBucketName,
        createBucket(test_client, "a", .{}),
    );

    // TODO: ADD DUPLICATE BUCKET TEST AFTER RUSTFS IMPLEMENT THIS CHECK
}

test "create bucket name validation" {
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

    // Test various invalid bucket names
    const long_name: [64]u8 = @splat('A');
    const invalid_names = [_][]const u8{
        "", // Empty
        "a", // Too short
        "ab", // Too short
        "ThisHasUpperCase", // Contains uppercase
        "contains_underscore", // Contains underscore
        &long_name, // Too long
    };

    for (invalid_names) |name| {
        try std.testing.expectError(
            error.InvalidBucketName,
            createBucket(test_client, name, .{}),
        );
    }
}
