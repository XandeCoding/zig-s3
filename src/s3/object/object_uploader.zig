const std = @import("std");
const Writer = std.Io.Writer;
const S3Error = @import("../common/errors.zig").S3Error;
const client_impl = @import("../client/implementation.zig");
const S3Client = client_impl.S3Client;
const putObject = @import("put_object.zig").putObject;
const createMultipartUpload = @import("create_multipart_upload.zig").createMultipartUpload;
const abortMultipartUpload = @import("abort_multipart_upload.zig").abortMultipartUpload;
const putMultipartObject = @import("put_multipart_object.zig").putMultipartObject;
const completeMultipartUpload = @import("complete_multipart_upload.zig").completeMultipartUpload;

pub const ObjectUploaderOptions = struct {
    // DISCLAIMER: This param will be removed in the future for a dynamic size calculation
    comptime upload_part_size_mb: u32 = 5,
    comptime minimum_multipart_upload_mb: u32 = 50,
};

pub const ObjectUploader = struct {
    client: *S3Client,
    comptime upload_part_size: u32 = 5 * 1024 * 1024,
    comptime minimum_multipart_upload: u32 = 50 * 1024 * 1024,

    pub fn init(client: *S3Client, options: ObjectUploaderOptions) ObjectUploader {
        return .{
            .client = client,
            .upload_part_size = options.upload_part_size_mb * 1024 * 1024,
            .minimum_multipart_upload = options.minimum_multipart_upload_mb * 1024 * 1024,
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
        // TODO: add io as parameter?
        // Open the file
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        const directory = std.Io.Dir.cwd();
        const file = try directory.openFile(io, file_path, .{});
        defer file.close(io);

        // Get file size
        const file_size = try file.length(io);

        if (file_size < self.minimum_multipart_upload) {
            // Allocate buffer and read file
            const buffer = try self.client.allocator.alloc(u8, file_size);
            defer self.client.allocator.free(buffer);

            const bytes_read = try file.readPositionalAll(io, buffer, 0);
            if (bytes_read != file_size) {
                return error.IncompleteRead;
            }

            // Upload the binary data
            try putObject(self.client, .{
                .bucket_name = bucket_name,
                .key = key,
                .data = buffer,
            });
            return;
        }

        // create multipart upload to get the upload id
        const upload_id = try createMultipartUpload(self.client, .{
            .bucket_name = bucket_name,
            .key = key,
        });
        defer self.client.allocator.free(upload_id);

        // abort in case of error
        errdefer {
            _ = abortMultipartUpload(self.client, .{
                .bucket_name = bucket_name,
                .key = key,
                .upload_id = upload_id,
            }) catch {};
        }

        // Creating buffer
        const upload_buffer: []u8 = try self.client.allocator.create(
            [self.upload_part_size]u8,
        );
        defer self.client.allocator.free(upload_buffer);

        // Creating Writer and e_tag list
        var e_tag_list: std.ArrayList([]const u8) = .empty;
        defer {
            for (e_tag_list.items) |object| {
                self.client.allocator.free(object);
            }
            e_tag_list.deinit(self.client.allocator);
        }

        // Iterate the file content
        var out_size: usize = 1;
        var offset: usize = 0;
        var part_number: u8 = 1;

        while (out_size > 0) : (part_number += 1) {
            out_size = try file.readPositionalAll(io, upload_buffer, offset);

            // End of file check
            if (out_size == 0) break;

            offset += out_size;

            const etag = try putMultipartObject(self.client, .{
                .bucket_name = bucket_name,
                .key = key,
                .upload_id = upload_id,
                .part_number = part_number,
                .data = upload_buffer[0..out_size],
            });

            try e_tag_list.append(self.client.allocator, etag);
        }

        try completeMultipartUpload(self.client, .{
            .bucket_name = bucket_name,
            .key = key,
            .upload_id = upload_id,
            .e_tag_list = e_tag_list.items,
        });
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
            .{ .bucket_name = bucket_name, .key = key, .data = content },
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
        try putObject(self.client, .{ .bucket_name = bucket_name, .key = key, .data = data_raw });
    }
};

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

    var uploader = ObjectUploader.init(test_client, .{});

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
        uploader.uploadFile(
            "test-bucket",
            "test.txt",
            "nonexistent/file.txt",
        ),
    );
}
