const std = @import("std");
const Writer = std.Io.Writer;
const S3Error = @import("../common/errors.zig").S3Error;
const client_impl = @import("../client/implementation.zig");
const S3Client = client_impl.S3Client;
const putObject = @import("put_object.zig").putObject; 
const createBucket = @import("../bucket/create_bucket.zig").createBucket;
const deleteBucket = @import("../bucket/delete_bucket.zig").deleteBucket;

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
        try putObject(
            self.client,
            .{ .bucket_name = bucket_name, .key = key, .data = buffer }
        );
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
        try putObject(
            self.client,
            .{ .bucket_name = bucket_name, .key = key, .data = content }
        );
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
        try putObject(
            self.client,
            .{ .bucket_name = bucket_name, .key = key, .data = data_raw }
        );
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

    const buckets_name: [1][]const u8 = .{ "test-upload-different-types" };

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
}
