const std = @import("std");
const Writer = std.Io.Writer;
const S3Error = @import("../common/errors.zig").S3Error;
const client_impl = @import("../client/implementation.zig");
const S3Client = client_impl.S3Client;
const putObject = @import("put_object.zig").putObject;
const getObject = @import("get_object.zig").getObject;
const deleteObject = @import("delete_object.zig").deleteObject;
const createBucket = @import("../bucket/lib.zig").createBucket;
const deleteBucket = @import("../bucket/lib.zig").deleteBucket;

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
        try putObject(self.client, .{ .bucket_name = bucket_name, .key = key, .data = buffer });
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
        try putObject(self.client, .{ .bucket_name = bucket_name, .key = key, .data = content });
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
        try putObject(self.client, .{ .bucket_name = bucket_name, .key = key, .data = data_raw });
    }
};

test "Before All - Object Uploader" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_client = try S3Client.init(allocator, io, client_impl.S3Config{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    });
    defer test_client.deinit();

    const buckets_name: [4][]const u8 = .{
        "test-upload-different-types", "test-uploader",
        "test-file-uploader",          "test-custom-endpoint",
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
}

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

    // String upload
    try uploader.uploadString(
        bucket_name,
        "text/hello.txt",
        "Hello, World!",
    );

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
}

test "ObjectUploader basic functionality" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_client = try S3Client.init(allocator, io, .{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    });
    defer test_client.deinit();

    // Create test bucket
    const bucket_name = "test-uploader";

    var uploader = ObjectUploader.init(test_client);

    // Test string upload
    const test_string = "Hello, World!";
    try uploader.uploadString(bucket_name, "test.txt", test_string);

    // Verify string upload
    const retrieved_string = try getObject(test_client, .{ .bucket_name = bucket_name, .key = "test.txt" });
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
    const retrieved_json = try getObject(test_client, .{ .bucket_name = bucket_name, .key = "test.json" });
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
}

test "ObjectUploader file operations" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_client = try S3Client.init(allocator, io, .{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    });
    defer test_client.deinit();

    // Create test bucket
    const bucket_name = "test-file-uploader";

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
    const retrieved_content = try getObject(test_client, .{ .bucket_name = bucket_name, .key = "uploaded.txt" });
    defer allocator.free(retrieved_content);
    try std.testing.expectEqualStrings(test_content, retrieved_content);
}

test "ObjectUploader error cases" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_client = try S3Client.init(allocator, io, .{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    });
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

    // Test basic upload with custom endpoint
    const test_data = "Testing with custom endpoint";
    try uploader.uploadString(bucket_name, "test.txt", test_data);

    // Verify upload
    const retrieved = try getObject(test_client, .{ .bucket_name = bucket_name, .key = "test.txt" });
    defer allocator.free(retrieved);
    try std.testing.expectEqualStrings(test_data, retrieved);
}

// TODO: CHECAR SE É NECESSÁRIO DELETAR OS OBJETOS
test "After All - Object Uploader" {
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

    // const test_objects = [_]struct { key: []const u8, content: []const u8 }{
    //     .{ .bucket_name = "test-upload-different-types", .key = "images/upload.txt" },
    //     .{ .bucket_name = "test-upload-different-types", .key = "text/hello.txt" },
    //     .{ .bucket_name = "test-upload-different-types", .key = "data/user.json" },
    // };

    // // TODO: DEIXAR PARALELO
    // for (test_objects) |obj| {
    //     try deleteObject(test_client, obj.bucket_name, obj.key, obj.content);
    // }

}
