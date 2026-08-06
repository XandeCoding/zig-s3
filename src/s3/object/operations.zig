/// Object operations for S3 client.
/// This module implements basic object operations like upload, download, and deletion.
const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;
const Uri = std.Uri;
const fmt = std.fmt;
const fs = std.fs;
const Writer = std.Io.Writer;

const client_impl = @import("../client/implementation.zig");
const bucket_ops = @import("../bucket/operations.zig");
const encoding = @import("../common/encoding.zig");
const xml = @import("../common/xml.zig");
const validators = @import("../common/validators.zig");
const S3Error = @import("../common/errors.zig").S3Error;
const S3Client = client_impl.S3Client;

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
///   - InvalidResponse: If upload fails
///   - BucketNotFound: If the bucket doesn't exist
///   - ConnectionFailed: Network or connection issues
///   - OutOfMemory: Memory allocation failure
pub fn putObject(self: *S3Client, bucket_name: []const u8, key: []const u8, data: []const u8) !void {
    if (validators.objectNameIsValid(key) == false) return S3Error.InvalidObjectKey;

    const uri_str = try std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{ self.config.endpoint, bucket_name, key });
    defer self.allocator.free(uri_str);

    const req = try self.request(.PUT, try Uri.parse(uri_str), null, data);

    if (req.status == .bad_request) {
        return S3Error.InvalidObjectKey;
    }
    if (req.status != .ok) {
        return S3Error.InvalidResponse;
    }
}

/// Download an object from S3.
///
/// Currently limited to objects up to 1MB in size.
/// For larger objects, streaming download support is needed (TODO).
///
/// Parameters:
///   - self: Pointer to initialized S3Client
///   - bucket_name: Name of the bucket containing the object
///   - key: Object key (path) in the bucket
///
/// Returns: Object content as a slice. Caller owns the memory.
///
/// Errors:
///   - ObjectNotFound: If the object doesn't exist
///   - BucketNotFound: If the bucket doesn't exist
///   - InvalidResponse: If download fails
///   - ConnectionFailed: Network or connection issues
///   - OutOfMemory: Memory allocation failure
pub fn getObject(self: *S3Client, bucket_name: []const u8, key: []const u8) ![]const u8 {
    const uri_str = try fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{ self.config.endpoint, bucket_name, key });
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

fn deleteObjectCancellableFn(self: *S3Client, bucket_name: []const u8, key: []const u8) error{Canceled}!void {
    const uri_str = fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{ self.config.endpoint, bucket_name, key }) catch {
        return;
    };
    defer self.allocator.free(uri_str);
    const uri = Uri.parse(uri_str) catch {
        return;
    };

    _ = self.request(.DELETE, uri, null, null) catch {
        return;
    };
}
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
pub fn deleteObject(self: *S3Client, bucket_name: []const u8, key: []const u8) !void {
    const uri_str = try fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{ self.config.endpoint, bucket_name, key });
    defer self.allocator.free(uri_str);

    const req = try self.request(.DELETE, try Uri.parse(uri_str), null, null);

    if (req.status != .no_content) {
        return S3Error.InvalidResponse;
    }
}

pub const DeleteObjectParam = struct {
    /// Key (path) of the object
    key: []const u8,
};
/// Delete a list of object from S3.
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
pub fn deleteObjectList(self: *S3Client, bucket_name: []const u8, object_list: []const DeleteObjectParam) !void {
    var threaded: std.Io.Threaded = .init(self.allocator, .{ .async_limit = .unlimited, .concurrent_limit = .unlimited });
    defer threaded.deinit();

    const io = threaded.io();
    var group: std.Io.Group = .init;
    defer group.cancel(io);

    for (object_list) |object| {
        group.concurrent(io, deleteObjectCancellableFn, .{ self, bucket_name, object.key }) catch |err| {
            std.debug.print("ERROR: {}\n", .{err});
            return S3Error.InvalidResponse;
        };
    }

    group.await(io) catch |err| {
        std.debug.print("ERROR: {}\n", .{err});
        return S3Error.InvalidResponse;
    };
}

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

pub const ObjectUploader = struct {
    client: *S3Client,

    pub fn init(client: *S3Client) ObjectUploader {
        return .{
            .client = client,
        };
    }

    /// Uploads a file from the filesystem to S3
    /// Handles the file reading and binary conversion automatically
    pub fn uploadFile(
        self: *ObjectUploader,
        bucket_name: []const u8,
        key: []const u8,
        file_path: []const u8,
    ) !void {
        // Open the file
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        const directory = std.Io.Dir.cwd();
        const file = try directory.openFile(io, file_path, .{});
        defer file.close(io);

        // Get file size
        const file_size = try file.length(io);

        // Allocate buffer and read file
        const buffer = try self.client.allocator.alloc(u8, file_size);
        defer self.client.allocator.free(buffer);

        const bytes_read = try file.readPositionalAll(io, buffer, 0);
        if (bytes_read != file_size) {
            return error.IncompleteRead;
        }

        // Upload the binary data
        try putObject(self.client, bucket_name, key, buffer);
    }

    /// Uploads string data to S3
    /// Automatically converts the string to binary
    pub fn uploadString(
        self: *ObjectUploader,
        bucket_name: []const u8,
        key: []const u8,
        content: []const u8,
    ) !void {
        // String data is already in []const u8 format
        try putObject(self.client, bucket_name, key, content);
    }

    /// Uploads JSON data to S3
    /// Handles the serialization automatically
    pub fn uploadJson(
        self: *ObjectUploader,
        bucket_name: []const u8,
        key: []const u8,
        data: anytype,
    ) !void {
        // Create a writer for JSON string
        var out = try Writer.Allocating.initCapacity(self.client.allocator, 4096);
        defer out.deinit();

        // Serialize to JSON
        try std.json.Stringify.value(data, .{}, &out.writer);
        const data_raw = out.written();

        // Upload the JSON data
        try putObject(self.client, bucket_name, key, data_raw);
    }
};

test "upload different types" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_client = try S3Client.init(allocator, io, .{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    });
    defer test_client.deinit();
    const bucket_name = "test-upload-different-types";
    try bucket_ops.createBucket(test_client, bucket_name);
    defer _ = bucket_ops.deleteBucket(test_client, bucket_name) catch {};

    const directory = std.Io.Dir.cwd();
    const file = try directory.createFile(io, "upload.txt", .{});
    defer {
        file.close(io);
        _ = directory.deleteFile(io, "upload.txt") catch {};
    }

    try file.writePositionalAll(io, "upload file test", 0);

    var uploader = ObjectUploader.init(test_client);

    // File upload
    try uploader.uploadFile(
        bucket_name,
        "images/upload.txt",
        "upload.txt",
    );
    defer _ = deleteObject(test_client, bucket_name, "images/upload.txt") catch {};

    // String upload
    try uploader.uploadString(
        bucket_name,
        "text/hello.txt",
        "Hello, World!",
    );

    defer _ = deleteObject(test_client, bucket_name, "text/hello.txt") catch {};
    // JSON upload
    const json_data = .{
        .name = "John",
        .age = 30,
    };
    try uploader.uploadJson(
        bucket_name,
        "data/user.json",
        json_data,
    );
    defer _ = deleteObject(test_client, bucket_name, "data/user.json") catch {};
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
    try bucket_ops.createBucket(test_client, bucket_name);
    defer {
        const start = std.Io.Timestamp.now(io, .awake);
        _ = bucket_ops.deleteBucket(test_client, bucket_name) catch {};
        const end = std.Io.Timestamp.now(io, .awake);

        std.debug.print("DELETE BUCKET DURATION: {d}s\n", .{std.Io.Timestamp.durationTo(start, end).toSeconds()});
    }

    const test_objects = [_]struct { key: []const u8, content: []const u8 }{
        .{ .key = "test1.txt", .content = "Hello 1" },
        .{ .key = "test2.txt", .content = "Hello 2" },
        .{ .key = "folder/test3.txt", .content = "Hello 3" },
    };

    // Upload test objects
    for (test_objects) |obj| {
        try putObject(test_client, bucket_name, obj.key, obj.content);
    }
    defer {
        var delete_list = std.ArrayList(DeleteObjectParam).empty;
        defer delete_list.deinit(allocator);

        for (test_objects) |object| {
            _ = delete_list.append(allocator, .{ .key = object.key }) catch {};
        }
        _ = deleteObjectList(test_client, bucket_name, delete_list.items) catch {};
    }

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
    try bucket_ops.createBucket(test_client, bucket_name);
    defer _ = bucket_ops.deleteBucket(test_client, bucket_name) catch {};

    const test_objects = [_]struct { key: []const u8, content: []const u8 }{
        .{ .key = "folder1/test1.txt", .content = "Hello 1" },
        .{ .key = "folder1/test2.txt", .content = "Hello 2" },
        .{ .key = "folder2/test3.txt", .content = "Hello 3" },
    };

    // Upload test objects
    for (test_objects) |obj| {
        try putObject(test_client, bucket_name, obj.key, obj.content);
    }
    defer {
        var delete_list = std.ArrayList(DeleteObjectParam).empty;
        defer delete_list.deinit(allocator);

        for (test_objects) |object| {
            _ = delete_list.append(allocator, .{ .key = object.key }) catch {};
        }
        _ = deleteObjectList(test_client, bucket_name, delete_list.items) catch {};
    }

    // List objects with prefix
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
    try bucket_ops.createBucket(test_client, bucket_name);
    defer _ = bucket_ops.deleteBucket(test_client, bucket_name) catch {};

    // Create 5 test objects
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const key = try fmt.allocPrint(allocator, "test{d}.txt", .{i});
        defer allocator.free(key);
        const content = try fmt.allocPrint(allocator, "Content {d}", .{i});
        defer allocator.free(content);
        try putObject(test_client, bucket_name, key, content);
    }
    defer {
        var delete_list = std.ArrayList(DeleteObjectParam).empty;
        defer delete_list.deinit(allocator);

        _ = deleteObjectList(test_client, bucket_name, delete_list.items) catch {};

        i = 0;
        while (i < 5) : (i += 1) {
            const key = fmt.allocPrint(allocator, "test{d}.txt", .{i}) catch continue;
            _ = delete_list.append(allocator, .{ .key = key }) catch {};
        }
        _ = deleteObjectList(test_client, bucket_name, delete_list.items) catch {};
        for (delete_list.items) |object| {
            allocator.free(object.key);
        }
    }

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
    try bucket_ops.createBucket(test_client, bucket_name);
    defer _ = bucket_ops.deleteBucket(test_client, bucket_name) catch {};

    // Test invalid max_keys
    try std.testing.expectError(
        error.InvalidResponse,
        listObjects(test_client, bucket_name, .{
            .max_keys = 1001, // Max allowed is 1000
        }),
    );
}

test "object operations" {
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

    const bucket_name = "object-operations-test";
    try bucket_ops.createBucket(test_client, bucket_name);
    defer _ = bucket_ops.deleteBucket(test_client, bucket_name) catch {};

    // Test basic object lifecycle
    const test_data = "Hello, S3!";
    try putObject(test_client, bucket_name, "admin", test_data);

    const retrieved = try getObject(test_client, bucket_name, "admin");
    defer allocator.free(retrieved);
    try std.testing.expectEqualStrings(test_data, retrieved);

    try deleteObject(test_client, bucket_name, "admin");
}

test "delete objects list" {
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

    const bucket_name = "object-delete-objects-list";
    try bucket_ops.createBucket(test_client, bucket_name);
    defer _ = bucket_ops.deleteBucket(test_client, bucket_name) catch {};

    const test_data = "Hello, S3!";
    try putObject(test_client, bucket_name, "1", test_data);
    try putObject(test_client, bucket_name, "2", test_data);
    try putObject(test_client, bucket_name, "3", test_data);

    const list_objects: [3]DeleteObjectParam = .{
        .{ .key = "1" },
        .{ .key = "2" },
        .{ .key = "3" },
    };

    try deleteObjectList(test_client, bucket_name, &list_objects);
}

test "object operations error handling" {
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
        getObject(test_client, "test-bucket", "nonexistent-key"),
    );

    // Test invalid object key
    const invalid_key = "";
    try std.testing.expectError(
        error.InvalidObjectKey,
        putObject(test_client, "test-bucket", invalid_key, "test data"),
    );
}

test "object operations with large data" {
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
    try bucket_ops.createBucket(test_client, bucket_name);
    defer _ = bucket_ops.deleteBucket(test_client, bucket_name) catch {};

    // Test large object operations
    try putObject(test_client, bucket_name, "large-file.bin", large_data);

    const retrieved = try getObject(test_client, bucket_name, "large-file.bin");
    defer allocator.free(retrieved);

    try std.testing.expectEqualSlices(u8, large_data, retrieved);

    try deleteObject(test_client, bucket_name, "large-file.bin");
}

test "object operations with custom endpoint" {
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

    // Test object operations with custom endpoint
    const bucket_name = "custom-endpoint-bucket";
    try bucket_ops.createBucket(test_client, bucket_name);
    defer _ = bucket_ops.deleteBucket(test_client, bucket_name) catch {};

    const test_data = "Testing with custom endpoint";
    try putObject(test_client, bucket_name, "custom-endpoint-test.txt", test_data);

    const retrieved = try getObject(test_client, bucket_name, "custom-endpoint-test.txt");
    defer allocator.free(retrieved);

    try std.testing.expectEqualStrings(test_data, retrieved);

    try deleteObject(test_client, bucket_name, "custom-endpoint-test.txt");
}

test "object key validation" {
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

    const bucket_name = "object-validation-bucket";
    try bucket_ops.createBucket(test_client, bucket_name);
    defer _ = bucket_ops.deleteBucket(test_client, bucket_name) catch {};

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
            putObject(test_client, bucket_name, key, "test data"),
        );
    }

    // Test valid object keys
    const valid_keys = [_][]const u8{
        "valid/key.txt",
        "path/to/object.json",
        "special-chars_!@$&*().txt",
    };
    var delete_object_list = std.ArrayList(DeleteObjectParam).empty;
    defer delete_object_list.deinit(allocator);

    for (valid_keys) |key| {
        const test_data = "Test data";
        try putObject(test_client, bucket_name, key, test_data);

        const retrieved = try getObject(test_client, bucket_name, key);
        defer allocator.free(retrieved);

        try std.testing.expectEqualStrings(test_data, retrieved);

        try delete_object_list.append(allocator, .{ .key = key });
    }

    try deleteObjectList(test_client, bucket_name, delete_object_list.items);
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

    // Create empty bucket
    const bucket_name = "test-empty-bucket";
    try bucket_ops.createBucket(test_client, bucket_name);
    defer _ = bucket_ops.deleteBucket(test_client, bucket_name) catch {};

    // List objects in empty bucket
    const objects = try listObjects(test_client, bucket_name, .{});
    defer allocator.free(objects);

    try std.testing.expectEqual(@as(usize, 0), objects.len);
}

test "list objects with multiple prefixes" {
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

    const bucket_name = "test-prefix-bucket";
    try bucket_ops.createBucket(test_client, bucket_name);
    defer _ = bucket_ops.deleteBucket(test_client, bucket_name) catch {};

    // Create objects with different prefixes
    const test_objects = [_]struct { key: []const u8, content: []const u8 }{
        .{ .key = "folder1/a.txt", .content = "a" },
        .{ .key = "folder1/b.txt", .content = "b" },
        .{ .key = "folder2/c.txt", .content = "c" },
        .{ .key = "folder2/subfolder/d.txt", .content = "d" },
        .{ .key = "folder3/e.txt", .content = "e" },
        .{ .key = "root.txt", .content = "root" },
    };

    // Upload test objects
    for (test_objects) |obj| {
        try putObject(test_client, bucket_name, obj.key, obj.content);
    }
    defer {
        var delete_list = std.ArrayList(DeleteObjectParam).empty;
        defer delete_list.deinit(allocator);

        for (test_objects) |object| {
            _ = delete_list.append(allocator, .{ .key = object.key }) catch {};
        }
        _ = deleteObjectList(test_client, bucket_name, delete_list.items) catch {};
    }

    // Test different prefix scenarios
    const test_cases = [_]struct {
        prefix: []const u8,
        expected_count: usize,
    }{
        .{ .prefix = "folder1/", .expected_count = 2 },
        .{ .prefix = "folder2/", .expected_count = 2 },
        .{ .prefix = "folder2/subfolder/", .expected_count = 1 },
        .{ .prefix = "folder3/", .expected_count = 1 },
        .{ .prefix = "", .expected_count = 6 }, // All objects
        .{ .prefix = "nonexistent/", .expected_count = 0 },
    };

    for (test_cases) |case| {
        const objects = try listObjects(test_client, bucket_name, .{
            .prefix = case.prefix,
        });
        defer {
            for (objects) |object| {
                allocator.free(object.key);
                allocator.free(object.last_modified);
                allocator.free(object.etag);
            }
            allocator.free(objects);
        }

        try std.testing.expectEqual(case.expected_count, objects.len);

        // Verify all objects start with prefix
        for (objects) |object| {
            if (case.prefix.len > 0) {
                try std.testing.expect(std.mem.startsWith(u8, object.key, case.prefix));
            }
        }
    }
}

test "list objects pagination with various sizes" {
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

    const bucket_name = "test-pagination-bucket";
    try bucket_ops.createBucket(test_client, bucket_name);
    defer _ = bucket_ops.deleteBucket(test_client, bucket_name) catch {};

    // Create 25 test objects
    const total_objects = 25;
    var i: usize = 0;
    while (i < total_objects) : (i += 1) {
        const key = try fmt.allocPrint(allocator, "obj{d:0>3}.txt", .{i}); // pad with zeros for correct sorting
        defer allocator.free(key);

        const content = try fmt.allocPrint(allocator, "Content {d}", .{i});
        defer allocator.free(content);

        try putObject(test_client, bucket_name, key, content);
    }
    defer {
        var delete_list = std.ArrayList(DeleteObjectParam).empty;
        defer delete_list.deinit(allocator);

        i = 0;
        while (i < total_objects) : (i += 1) {
            const key = fmt.allocPrint(allocator, "obj{d:0>3}.txt", .{i}) catch continue;
            _ = delete_list.append(allocator, .{ .key = key }) catch {};
        }

        _ = deleteObjectList(test_client, bucket_name, delete_list.items) catch {};

        for (delete_list.items) |object| {
            allocator.free(object.key);
        }
    }

    // Test different page sizes
    const page_sizes = [_]u32{ 5, 10, 15 };
    for (page_sizes) |page_size| {
        var collected_objects = std.ArrayList([]const u8).empty;
        defer {
            for (collected_objects.items) |key| {
                allocator.free(key);
            }
            collected_objects.deinit(allocator);
        }

        var last_key: ?[]const u8 = null;
        while (true) {
            const page = try listObjects(test_client, bucket_name, .{
                .max_keys = page_size,
                .start_after = last_key,
            });
            defer {
                for (page) |object| {
                    allocator.free(object.last_modified);
                    allocator.free(object.etag);
                    allocator.free(object.key);
                }
                allocator.free(page);
            }

            if (page.len == 0) break;

            for (page) |object| {
                if (last_key == null or !std.mem.eql(u8, object.key, last_key.?)) {
                    try collected_objects.append(allocator, try allocator.dupe(u8, object.key));
                }
            }

            if (page.len < page_size) break;

            if (last_key) |key| {
                allocator.free(key);
            }
            last_key = try allocator.dupe(u8, page[page.len - 1].key);
        }

        if (last_key) |key| {
            allocator.free(key);
        }

        // Verify we got all objects and they're in order
        try std.testing.expectEqual(@as(usize, total_objects), collected_objects.items.len);
        for (collected_objects.items, 0..) |key, idx| {
            const expected = try fmt.allocPrint(allocator, "obj{d:0>3}.txt", .{idx});
            defer allocator.free(expected);
            try std.testing.expectEqualStrings(expected, key);
        }
    }
}

test "list objects with special characters in prefix" {
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

    const bucket_name = "test-special-chars";
    try bucket_ops.createBucket(test_client, bucket_name);
    defer _ = bucket_ops.deleteBucket(test_client, bucket_name) catch {};

    // Create objects with special characters in paths
    const test_objects = [_]struct { key: []const u8, content: []const u8 }{
        .{ .key = "special!chars/test1.txt", .content = "1" },
        .{ .key = "special@chars/test2.txt", .content = "2" },
        .{ .key = "special*chars/test3.txt", .content = "3" },
        .{ .key = "special$chars/test4.txt", .content = "4" },
        .{ .key = "special_chars/test5.txt", .content = "5" },
        .{ .key = "special:20chars/test6.txt", .content = "6" },
        .{ .key = "special+chars/test7.txt", .content = "7" },
    };

    // Upload test objects
    for (test_objects) |obj| {
        try putObject(test_client, bucket_name, obj.key, obj.content);
    }
    defer {
        var delete_list = std.ArrayList(DeleteObjectParam).empty;
        defer delete_list.deinit(allocator);

        for (test_objects) |object| {
            _ = delete_list.append(allocator, .{ .key = object.key }) catch {};
        }
        _ = deleteObjectList(test_client, bucket_name, delete_list.items) catch {};
    }

    // Test listing with various special character prefixes
    for (test_objects) |obj| {
        const prefix = obj.key[0 .. std.mem.indexOf(u8, obj.key, "/").? + 1];
        const objects = try listObjects(test_client, bucket_name, .{
            .prefix = prefix,
        });
        defer {
            for (objects) |object| {
                allocator.free(object.key);
                allocator.free(object.last_modified);
                allocator.free(object.etag);
            }
            allocator.free(objects);
        }

        try std.testing.expectEqual(@as(usize, 1), objects.len);
        try std.testing.expectEqualStrings(obj.key, objects[0].key);
    }
}

test "ObjectUploader basic functionality" {
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

    // Create test bucket
    const bucket_name = "test-uploader";
    try bucket_ops.createBucket(test_client, bucket_name);
    defer _ = bucket_ops.deleteBucket(test_client, bucket_name) catch {};

    var uploader = ObjectUploader.init(test_client);

    // Test string upload
    const test_string = "Hello, World!";
    try uploader.uploadString(bucket_name, "test.txt", test_string);

    // Verify string upload
    const retrieved_string = try getObject(test_client, bucket_name, "test.txt");
    defer allocator.free(retrieved_string);
    try std.testing.expectEqualStrings(test_string, retrieved_string);

    // Test JSON upload
    const TestStructType = struct {
        name: []const u8,
        value: i32,
        tags: [2][]const u8,
    };

    const test_json: TestStructType = .{
        .name = "test",
        .value = 42,
        .tags = [2][]const u8{ "tag1", "tag2" },
    };
    try uploader.uploadJson(bucket_name, "test.json", test_json);

    // Verify JSON upload
    const retrieved_json = try getObject(test_client, bucket_name, "test.json");
    defer allocator.free(retrieved_json);

    // Parse and verify JSON content
    const parsed = try std.json.parseFromSlice(
        TestStructType,
        allocator,
        retrieved_json,
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("test", parsed.value.name);
    try std.testing.expectEqual(@as(i64, 42), parsed.value.value);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.tags.len);
    try std.testing.expectEqualStrings("tag1", parsed.value.tags[0]);
    try std.testing.expectEqualStrings("tag2", parsed.value.tags[1]);

    // Clean up test objects
    var delete_object_list: [2]DeleteObjectParam = .{
        .{ .key = "test.txt" }, .{ .key = "test.json" },
    };
    try deleteObjectList(test_client, bucket_name, &delete_object_list);
}

test "ObjectUploader file operations" {
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

    // Create test bucket
    const bucket_name = "test-file-uploader";
    try bucket_ops.createBucket(test_client, bucket_name);
    defer _ = bucket_ops.deleteBucket(test_client, bucket_name) catch {};

    var uploader = ObjectUploader.init(test_client);

    // Create a temporary test file
    const test_content = "Test file content";
    const test_filename = "test-upload.txt";

    // Create temporary directory for test files
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();

    // Create and write test file
    {
        const file = try directory.dir.createFile(io, test_filename, .{});
        defer file.close(io);
        try file.writePositionalAll(io, test_content, 0);
    }

    // Test file upload
    const file_path = try directory.dir.realPathFileAlloc(io, test_filename, allocator);
    defer allocator.free(file_path);
    try uploader.uploadFile(bucket_name, "uploaded.txt", file_path);

    // Verify file upload
    const retrieved_content = try getObject(test_client, bucket_name, "uploaded.txt");
    defer allocator.free(retrieved_content);
    try std.testing.expectEqualStrings(test_content, retrieved_content);

    // Clean up test object
    try deleteObject(test_client, bucket_name, "uploaded.txt");
}

test "ObjectUploader error cases" {
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

    var uploader = ObjectUploader.init(test_client);

    // Test non-existent bucket
    try std.testing.expectError(
        error.InvalidResponse,
        uploader.uploadString("nonexistent-bucket", "test.txt", "test"),
    );

    // Test invalid object key
    try std.testing.expectError(
        error.InvalidObjectKey,
        uploader.uploadString("test-bucket", "", "test"),
    );

    // Test non-existent file
    try std.testing.expectError(
        error.FileNotFound,
        uploader.uploadFile("test-bucket", "test.txt", "nonexistent/file.txt"),
    );
}

test "ObjectUploader with custom endpoint" {
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

    var uploader = ObjectUploader.init(test_client);

    // Create test bucket
    const bucket_name = "test-custom-endpoint";
    try bucket_ops.createBucket(test_client, bucket_name);
    defer _ = bucket_ops.deleteBucket(test_client, bucket_name) catch {};

    // Test basic upload with custom endpoint
    const test_data = "Testing with custom endpoint";
    try uploader.uploadString(bucket_name, "test.txt", test_data);

    // Verify upload
    const retrieved = try getObject(test_client, bucket_name, "test.txt");
    defer allocator.free(retrieved);
    try std.testing.expectEqualStrings(test_data, retrieved);

    // Clean up
    try deleteObject(test_client, bucket_name, "test.txt");
}
