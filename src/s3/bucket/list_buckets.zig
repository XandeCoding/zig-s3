const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;
const Uri = std.Uri;
const fmt = std.fmt;
const Writer = std.Io.Writer;

const client_impl = @import("../client/implementation.zig");
const S3Error = @import("../common/errors.zig").S3Error;
const S3Client = client_impl.S3Client;
const xml = @import("../common/xml.zig");
const createBucket = @import("create_bucket.zig").createBucket;
const deleteBucket = @import("delete_bucket.zig").deleteBucket;

pub const ListBucketsOptions = struct {
    continuation_token: ?[]const u8 = null,
    max_buckets: ?u16 = null,
    prefix: ?[]const u8 = null,
};

// Bucket information returned by listBuckets
pub const BucketInfo = struct {
    /// Name of the bucket
    name: []const u8,
    /// Creation date of the bucket as ISO-8601 string
    creation_date: []const u8,
};

/// List all buckets in the account.
///
/// For S3-compatible services, this will list buckets available
/// at the configured endpoint.
///
/// Parameters:
///   - self: Pointer to initialized S3Client
///   - options: Possible values to query or paginate
///     - continuation_token: Token used to paginate the buckets list
///     - max_buckets: Maximum number of buckets returned in response
///     - prefix: Limits the response for buckets that begin with this value
///
/// Returns: Slice of BucketInfo structs. Caller owns the memory.
///
/// Errors:
///   - InvalidCredentials: If authentication fails
///   - InvalidResponse: If listing fails or response is malformed
///   - ConnectionFailed: Network or connection issues
///   - OutOfMemory: Memory allocation failure
pub fn listBuckets(self: *S3Client, options: ListBucketsOptions) ![]BucketInfo {
    _ = options; // TODO: REMOVE THIS AFTER OPTIONS BE IMPLEMENTED
    var alloc_writer = try Writer.Allocating.initCapacity(self.allocator, 4096);
    defer alloc_writer.deinit();

    const response = try self.request(.GET, try Uri.parse(self.config.endpoint), &alloc_writer.writer, null);
    switch (response.status) {
        .ok => {},
        .unauthorized, .forbidden => {
            return S3Error.InvalidCredentials;
        },
        .bad_request => {
            return S3Error.InvalidResponse;
        },
        else => {
            return S3Error.InvalidResponse;
        },
    }

    const body = try alloc_writer.toOwnedSlice();
    defer self.allocator.free(body);

    var buckets = std.ArrayList(BucketInfo).empty;
    errdefer {
        for (buckets.items) |bucket| {
            self.allocator.free(bucket.name);
            self.allocator.free(bucket.creation_date);
        }
        buckets.deinit(self.allocator);
    }

    var it = std.mem.splitSequence(u8, body, "<Bucket>");
    _ = it.first(); // Skip first part before any <Bucket>

    while (it.next()) |bucket_xml| {
        const name = try xml.getByKey(self.allocator, bucket_xml, "Name");
        const date = try xml.getByKey(self.allocator, bucket_xml, "CreationDate");

        // TODO: ANALISAR SE É NECESSÁRIO ALOCACAO DINAMICA
        try buckets.append(self.allocator, .{
            .name = name,
            .creation_date = date,
        });
    }

    return buckets.toOwnedSlice(self.allocator);
}

test "list buckets error handling" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_client = try S3Client.init(allocator, io, client_impl.S3Config{
        .access_key_id = "admin",
        .secret_access_key = "INVALID_ACCESS_KEY",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    });
    defer test_client.deinit();

    // Test with invalid credentials
    try std.testing.expectError(
        error.InvalidCredentials,
        listBuckets(test_client, .{}),
    );
}
