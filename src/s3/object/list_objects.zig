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
///   - options: Optional listing parameters (prefix, pagination)
///     - bucket_name: Name of the bucket to list
///     - prefix: Filter for initial file name
///     - max_keys: Maximum number of objects to return
///     - start_after: Used for pagination
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
    bucket_name: []const u8,
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

    const uri_str = try fmt.allocPrint(self.allocator, "{s}/{s}?{s}", .{ self.config.endpoint, bucket_name, query.items });
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
        listObjects(test_client, "nonexistent-bucket", .{}),
    );

    const bucket_name = "error-cases-test";

    // Test invalid max_keys
    // Max allowed is 1000
    try std.testing.expectError(
        error.InvalidResponse,
        listObjects(test_client, bucket_name, .{ .max_keys = 1001 }),
    );
}
