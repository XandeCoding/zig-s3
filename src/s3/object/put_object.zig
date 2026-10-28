const std = @import("std");
const Uri = std.Uri;
const validators = @import("../common/validators.zig");
const S3Error = @import("../common/errors.zig").S3Error;
const client_impl = @import("../client/implementation.zig");
const S3Client = client_impl.S3Client;

// TODO: implement object_lock
pub const PutObjectOptions = struct {
    object_lock: ?bool = null,
};

/// Upload an object to S3.
///
/// Currently supports objects up to the size of available memory.
/// For larger objects, streaming upload support is needed (TODO).
///
/// Parameters:
///   - self: Pointer to initialized S3Client
///   - options: Optional listing parameters (prefix, pagination)
///     - bucket_name: Name of the target bucket
///     - key: Object key (path) in the bucket
///     - data: Object content to upload
///     - object_lock: not implemented yet
///
/// Errors:
///   - InvalidObjectKey: Invalid object key
///   - InvalidResponse: If upload fails
///   - BucketNotFound: If the bucket doesn't exist
///   - ConnectionFailed: Network or connection issues
///   - OutOfMemory: Memory allocation failure
pub fn putObject(
    self: *S3Client,
    bucket_name: []const u8,
    key: []const u8,
    data: []const u8,
    _: PutObjectOptions,
) !void {
    if (validators.objectNameIsValid(key) == false) return S3Error.InvalidObjectKey;

    const uri_str = try std.fmt.allocPrint(
        self.allocator,
        "{s}/{s}/{s}",
        .{ self.config.endpoint, bucket_name, key },
    );
    defer self.allocator.free(uri_str);

    const req = try self.request(
        .PUT,
        try Uri.parse(uri_str),
        null,
        data,
    );

    if (req.status == .bad_request) {
        return S3Error.InvalidObjectKey;
    }
    if (req.status != .ok) {
        return S3Error.InvalidResponse;
    }
}

test "put objects with invalid keys" {
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
    const long_key: [1025]u8 = @splat('a');
    const invalid_keys = [_][]const u8{
        "", // Empty
        "key\nwith\nnewlines", // Contains newlines
        "key with\x00null", // Contains null byte
        &long_key, // Too long (max is 1024)
    };

    for (invalid_keys) |key| {
        try std.testing.expectError(
            error.InvalidObjectKey,
            putObject(test_client, bucket_name, key, "test data", .{}),
        );
    }
}
