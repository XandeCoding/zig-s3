const std = @import("std");
const s3 = @import("s3");

const testing = std.testing;
const io = testing.io;
const allocator = testing.allocator;

fn createS3ClientConfig() !s3.S3ClientConfig {
    return s3.S3ClientConfig{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-west-1",
        .endpoint = "http://localhost:9000",
    };
}

test "upload simple string" {
    const config = try createS3ClientConfig();
    var client = try s3.S3Client.init(allocator, io, config);
    defer client.deinit();

    const bucket_name = "test-simple-file-bucket";
    const file_content = "Hello from Zig!";
    const file_key = "hello.txt";

    // Create bucket just to insure the upload will be successfull
    try client.createBucket(bucket_name, .{});
    defer _ = client.deleteBucket(bucket_name, .{}) catch {};

    // Create uploader and upload string
    var uploader = client.uploader(.{});
    uploader.uploadString(bucket_name, file_key, file_content) catch |err| {
        std.debug.print("Failed to upload file: {any}\n", .{err});
        return err;
    };
    defer _ = client.deleteObject(bucket_name, file_key, .{}) catch {};

    // Verify the upload by downloading the content
    const downloaded = client.getObject(bucket_name, file_key, .{}) catch |err| {
        std.debug.print("Failed to download file: {any}\n", .{err});
        return err;
    };
    defer allocator.free(downloaded);

    try testing.expectEqualStrings(file_content, downloaded);
}

test "full client lifecycle" {
    const config = try createS3ClientConfig();
    var client = try s3.S3Client.init(allocator, io, config);
    defer client.deinit();

    // Create test bucket
    const bucket_name = "integration-test-bucket";
    try client.createBucket(bucket_name, .{});
    defer _ = client.deleteBucket(bucket_name, .{}) catch {};

    // List buckets and verify our bucket exists
    const buckets = try client.listBuckets(.{});
    defer {
        for (buckets) |bucket| {
            allocator.free(bucket.name);
            allocator.free(bucket.creation_date);
        }
        allocator.free(buckets);
    }

    var found_bucket = false;
    for (buckets) |bucket| {
        if (std.mem.eql(u8, bucket.name, bucket_name)) {
            found_bucket = true;
            break;
        }
    }
    try testing.expect(found_bucket);

    // Test object operations
    {
        var uploader = client.uploader(.{});

        // Upload different types of content
        try uploader.uploadString(
            bucket_name,
            "hello.txt",
            "Hello, Integration Tests!",
        );

        const timestamp = std.Io.Timestamp.now(io, std.Io.Clock.real).toMilliseconds();
        const config_data = .{
            .app = try allocator.dupe(u8, "integration-test"),
            .version = try allocator.dupe(u8, "1.0.0"),
            .timestamp = timestamp,
        };
        defer allocator.free(config_data.app);
        defer allocator.free(config_data.version);
        try uploader.uploadJson(bucket_name, "config.json", config_data);

        // Create and upload a test file
        var directory = std.testing.tmpDir(.{});
        const filename = "test.dat";
        defer directory.cleanup();

        // Create and write test file
        {
            const file = try directory.dir.createFile(io, filename, .{});
            defer file.close(io);
            try file.writePositionalAll(io, "Test file content", 0);
        }

        // Test file upload
        const file_path = try directory.dir.realPathFileAlloc(io, filename, allocator);
        defer allocator.free(file_path);
        try uploader.uploadFile(bucket_name, "files/test.dat", file_path);

        // List objects and verify
        const objects = try client.listObjects(bucket_name, .{});
        defer {
            for (objects) |object| {
                allocator.free(object.key);
                allocator.free(object.last_modified);
                allocator.free(object.etag);
            }
            allocator.free(objects);
        }

        try testing.expectEqual(3, objects.len);

        // Download and verify content
        const hello_content = try client.getObject(bucket_name, "hello.txt", .{});
        defer allocator.free(hello_content);
        try testing.expectEqualStrings("Hello, Integration Tests!", hello_content);

        const config_content = try client.getObject(bucket_name, "config.json", .{});
        defer allocator.free(config_content);

        // Parse and verify JSON
        const parsed = try std.json.parseFromSlice(
            @TypeOf(config_data),
            allocator,
            config_content,
            .{},
        );
        defer parsed.deinit();

        try testing.expectEqualStrings("integration-test", parsed.value.app);
        try testing.expectEqualStrings("1.0.0", parsed.value.version);

        // Test object deletion
        try client.deleteObject(bucket_name, "hello.txt", .{});
        try client.deleteObject(bucket_name, "config.json", .{});
        try client.deleteObject(bucket_name, "files/test.dat", .{});

        // Verify objects are gone
        const remaining_objects = try client.listObjects(bucket_name, .{});
        defer {
            for (remaining_objects) |object| {
                allocator.free(object.key);
                allocator.free(object.last_modified);
                allocator.free(object.etag);
            }
            allocator.free(remaining_objects);
        }
        try testing.expectEqual(0, remaining_objects.len);
    }
}

test "ObjectUploader using multipart file upload" {
    const config = try createS3ClientConfig();
    var client = try s3.S3Client.init(allocator, io, config);
    defer client.deinit();

    // Create test bucket
    const bucket_name = "test-uploader";

    var uploader = client.uploader(.{});

    // Test string upload
    const test_string: [1024 * 100]u8 = @splat('A');
    // Create temporary directory for test files
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();

    const filename = "multipart_file.txt";
    const file = try directory.dir.createFile(io, filename, .{ .read = true });
    defer file.close(io);

    var count: u8 = 0;
    const max = 50;
    while (count < max) : (count += 1) {
        try file.writePositionalAll(io, &test_string, count * test_string.len);
    }
    const file_path = try directory.dir.realPathFileAlloc(io, filename, allocator);
    defer allocator.free(file_path);

    try uploader.uploadFile("test-uploader", "multipart_file.txt", file_path);

    const retrieved_file = try client.getObject(bucket_name, filename, .{});
    defer allocator.free(retrieved_file);

    try std.testing.expectEqual(test_string.len * max, retrieved_file.len);

    var out_size: usize = 1;
    var offset: usize = 0;
    var upload_buffer: [1024 * 1024]u8 = undefined;

    while (out_size != 0) : (offset += out_size) {
        out_size = try file.readPositionalAll(io, &upload_buffer, offset);
        try std.testing.expectEqualStrings(
            upload_buffer[0..out_size],
            retrieved_file[offset .. offset + out_size],
        );
    }
}

test "file upload and download" {
    const config = try createS3ClientConfig();
    var client = try s3.S3Client.init(allocator, io, config);
    defer client.deinit();

    // Setup test bucket
    const bucket_name = "file-upload-test-bucket";
    try client.createBucket(bucket_name, .{});
    defer _ = client.deleteBucket(bucket_name, .{}) catch {};

    var uploader = client.uploader(.{});

    // Test text file upload
    {
        const s3_key = "text/sample.txt";
        try uploader.uploadFile(
            bucket_name,
            s3_key,
            "tests/integration/assets/sample.txt",
        );

        // Verify uploaded content
        const downloaded = try client.getObject(bucket_name, s3_key, .{});
        defer allocator.free(downloaded);

        // Read original file for comparison
        const dir = std.Io.Dir.cwd();
        const original_file = try dir.openFile(io, "tests/integration/assets/sample.txt", .{});
        defer original_file.close(io);

        var content_buffer: [124]u8 = undefined;
        _ = try original_file.readPositionalAll(io, &content_buffer, 0);

        try testing.expectEqualStrings(&content_buffer, downloaded);
    }

    // Test JSON file upload
    {
        const s3_key = "json/config.json";
        try uploader.uploadFile(
            bucket_name,
            s3_key,
            "tests/integration/assets/config.json",
        );

        // Verify uploaded content
        const downloaded = try client.getObject(bucket_name, s3_key, .{});
        defer allocator.free(downloaded);

        // Read original file for comparison
        const dir = std.Io.Dir.cwd();
        const original_file = try dir.openFile(io, "tests/integration/assets/config.json", .{});
        defer original_file.close(io);

        var content_buffer: [279]u8 = undefined;
        _ = try original_file.readPositionalAll(io, &content_buffer, @as(usize, 0));

        try testing.expectEqualStrings(&content_buffer, downloaded);

        // Verify JSON parsing still works
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            downloaded,
            .{},
        );
        defer parsed.deinit();

        try testing.expect(parsed.value.object.get("name").?.string.len > 0);
        try testing.expect(parsed.value.object.get("version").?.string.len > 0);
    }

    // Test file metadata and listing
    {
        const objects = try client.listObjects(bucket_name, .{});
        defer {
            for (objects) |object| {
                allocator.free(object.key);
                allocator.free(object.last_modified);
                allocator.free(object.etag);
            }
            allocator.free(objects);
        }

        try testing.expectEqual(@as(usize, 2), objects.len);

        // Verify objects are listed with correct prefixes
        var found_text = false;
        var found_json = false;
        for (objects) |object| {
            if (std.mem.startsWith(u8, object.key, "text/")) found_text = true;
            if (std.mem.startsWith(u8, object.key, "json/")) found_json = true;
        }
        try testing.expect(found_text);
        try testing.expect(found_json);
    }

    // Cleanup: Delete the uploaded files
    try client.deleteObject(bucket_name, "text/sample.txt", .{});
    try client.deleteObject(bucket_name, "json/config.json", .{});

    // Verify deletion
    const remaining = try client.listObjects(bucket_name, .{});
    defer {
        for (remaining) |object| {
            allocator.free(object.key);
            allocator.free(object.last_modified);
            allocator.free(object.etag);
        }
        allocator.free(remaining);
    }
    try testing.expectEqual(@as(usize, 0), remaining.len);
}
