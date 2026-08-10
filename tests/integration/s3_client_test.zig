const std = @import("std");
const s3 = @import("s3");

const testing = std.testing;
const io = testing.io;
const allocator = testing.allocator;

// At the top of the file, add ConnectionRefused to possible errors
const TestError = error{
    BucketNotFound,
    ConnectionRefused,
    MissingAccessKey,
    MissingSecretKey,
    MissingEndpoint,
    InvalidEndpoint,
    OperationTimeout,
    // ... other errors ...
};

fn createS3ClientConfig() !s3.S3ClientConfig {
    return s3.S3ClientConfig{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-west-1",
        .endpoint = "http://localhost:9000",
    };
}

test "initialize client" {
    std.debug.print("\n=== Starting client initialization test ===\n", .{});
    const config = try createS3ClientConfig();
    std.debug.print("Loaded config with endpoint: {?s}\n", .{config.endpoint});

    std.debug.print("Initializing client...\n", .{});
    var client = try s3.S3Client.init(allocator, io, config);
    defer client.deinit();

    std.debug.print("Client initialized successfully\n", .{});
}

test "validate endpoint" {
    std.debug.print("\n=== Starting endpoint validation test ===\n", .{});

    // Initialize client
    std.debug.print("Loading env vars...\n", .{});

    const config = try createS3ClientConfig();
    std.debug.print("Loaded config with endpoint: {?s}\n", .{config.endpoint});

    // Validate endpoint is not empty and accessible
    if (config.endpoint) |endpoint| {
        if (endpoint.len == 0) {
            std.debug.print("Error: Empty endpoint URL\n", .{});
            return error.InvalidEndpoint;
        }
        std.debug.print("Using endpoint: {s}\n", .{endpoint});
        std.debug.print("Access Key ID: {s}\n", .{config.access_key_id});
        std.debug.print("Region: {?s}\n", .{config.region});

        // Try to parse the endpoint URL
        const uri = std.Uri.parse(endpoint) catch |err| {
            std.debug.print("Error parsing endpoint URL: {}\n", .{err});
            return error.InvalidEndpoint;
        };

        // Validate scheme
        if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) {
            std.debug.print("Error: Invalid scheme (must be http or https)\n", .{});
            return error.InvalidEndpoint;
        }

        std.debug.print("Endpoint validation successful\n", .{});
    } else {
        std.debug.print("Error: Missing endpoint URL\n", .{});
        return error.MissingEndpoint;
    }
}

test "create simple bucket" {
    std.debug.print("\n=== Starting simple bucket creation test ===\n", .{});

    // Initialize client
    std.debug.print("Loading env vars...\n", .{});

    const config = try createS3ClientConfig();
    std.debug.print("Loaded config with endpoint: {?s}\n", .{config.endpoint});

    std.debug.print("Initializing client...\n", .{});
    var client = try s3.S3Client.init(allocator, io, config);
    defer client.deinit();
    std.debug.print("Client initialized successfully\n", .{});

    const bucket_name = "integration-test-bucket-123";

    // Create bucket
    std.debug.print("Creating bucket '{s}'...\n", .{bucket_name});
    try client.createBucket(bucket_name);
    std.debug.print("Bucket '{s}' created successfully\n", .{bucket_name});

    // Verify the bucket exists by listing buckets
    std.debug.print("Listing buckets to verify creation...\n", .{});
    const buckets = try client.listBuckets();
    defer {
        for (buckets) |bucket| {
            allocator.free(bucket.name);
            allocator.free(bucket.creation_date);
        }
        allocator.free(buckets);
    }

    var bucket_found = false;
    for (buckets) |bucket| {
        if (std.mem.eql(u8, bucket.name, bucket_name)) {
            bucket_found = true;
            break;
        }
    }

    try testing.expect(bucket_found);
    std.debug.print("Bucket '{s}' verified successfully\n", .{bucket_name});

    // Clean up by deleting the bucket
    std.debug.print("Deleting bucket '{s}'...\n", .{bucket_name});
    try client.deleteBucket(bucket_name);
    std.debug.print("Bucket '{s}' deleted successfully\n", .{bucket_name});
}

test "upload simple file to test-bucket" {
    std.debug.print("\n=== Starting simple file upload test ===\n", .{});

    // Initialize client

    const config = try createS3ClientConfig();
    var client = try s3.S3Client.init(allocator, io, config);
    defer client.deinit();

    const bucket_name = "test-bucket";
    const file_content = "Hello from Zig!";
    const file_key = "hello.txt";

    // Create bucket just to insure the upload will be successfull
    std.debug.print("Creating bucket '{s}'...\n", .{bucket_name});
    try client.createBucket(bucket_name);
    defer _ = client.deleteBucket(bucket_name) catch {};

    // Create uploader and upload string
    var uploader = client.uploader();
    uploader.uploadString(bucket_name, file_key, file_content) catch |err| {
        std.debug.print("Failed to upload file: {any}\n", .{err});
        return err;
    };
    defer _ = client.deleteObject(bucket_name, file_key) catch {};

    std.debug.print("Successfully uploaded file '{s}' to bucket '{s}'\n", .{ file_key, bucket_name });

    // Verify the upload by downloading the content
    const downloaded = client.getObject(bucket_name, file_key) catch |err| {
        std.debug.print("Failed to download file: {any}\n", .{err});
        return err;
    };
    defer allocator.free(downloaded);

    try testing.expectEqualStrings(file_content, downloaded);
    std.debug.print("Successfully verified file content\n", .{});
}

test "full client lifecycle" {
    std.debug.print("\n=== Starting full client lifecycle test ===\n", .{});
    // Initialize client

    const config = try createS3ClientConfig();
    var client = try s3.S3Client.init(allocator, io, config);
    defer client.deinit();

    // Create test bucket
    const bucket_name = "integration-test-bucket";
    try client.createBucket(bucket_name);
    defer _ = client.deleteBucket(bucket_name) catch {};

    // List buckets and verify our bucket exists
    const buckets = try client.listBuckets();
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
    std.debug.print("found bucket '{}'...\n", .{found_bucket});

    // Test object operations
    {
        var uploader = client.uploader();

        // Upload different types of content
        try uploader.uploadString(bucket_name, "hello.txt", "Hello, Integration Tests!");
        std.debug.print("String upload succesfull...\n", .{});

        const timestamp = std.Io.Timestamp.now(io, std.Io.Clock.real).toMilliseconds();
        const config_data = .{
            .app = try allocator.dupe(u8, "integration-test"),
            .version = try allocator.dupe(u8, "1.0.0"),
            .timestamp = timestamp,
        };
        defer allocator.free(config_data.app);
        defer allocator.free(config_data.version);
        try uploader.uploadJson(bucket_name, "config.json", config_data);

        std.debug.print("config_data upload  succesfull '{}'...\n", .{config_data});
        // Create and upload a test file
        var directory = std.testing.tmpDir(.{});
        const filename = "test.dat";
        defer directory.cleanup();

        // Create and write test file
        {
            const file = try directory.dir.createFile(io, filename, .{});
            defer file.close(io);
            try file.writePositionalAll(io, "Test file content", 0);
            std.debug.print("test file created succesfull...\n", .{});
        }

        // Test file upload
        const file_path = try directory.dir.realPathFileAlloc(io, filename, allocator);
        defer allocator.free(file_path);
        try uploader.uploadFile(bucket_name, "files/test.dat", file_path);

        std.debug.print("test file upload succesfull...\n", .{});
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
        const hello_content = try client.getObject(bucket_name, "hello.txt");
        defer allocator.free(hello_content);
        try testing.expectEqualStrings("Hello, Integration Tests!", hello_content);
        std.debug.print("hello downloaded ...\n", .{});

        const config_content = try client.getObject(bucket_name, "config.json");
        std.debug.print("config content {s}...\n", .{config_content});
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
        try client.deleteObject(bucket_name, "hello.txt");
        try client.deleteObject(bucket_name, "config.json");
        try client.deleteObject(bucket_name, "files/test.dat");

        std.debug.print("Objects deleted...\n", .{});
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

test "error handling" {
    std.debug.print("\n=== Starting error handling test ===\n", .{});
    // Initialize client

    const config = try createS3ClientConfig();
    var client = try s3.S3Client.init(allocator, io, config);
    defer client.deinit();

    // Test non-existent bucket
    try testing.expectError(
        error.ObjectNotFound,
        client.getObject("nonexistent-bucket", "test.txt"),
    );

    // Test non-existent object
    const bucket_name = "error-test-bucket";
    try client.createBucket(bucket_name);
    defer _ = client.deleteBucket(bucket_name) catch {};

    try testing.expectError(
        error.ObjectNotFound,
        client.getObject(bucket_name, "nonexistent.txt"),
    );

    // Test invalid bucket names
    try testing.expectError(
        error.InvalidBucketName,
        client.createBucket(""),
    );

    try testing.expectError(
        error.InvalidBucketName,
        client.createBucket("invalid..bucket"),
    );

    // Test invalid object keys
    try testing.expectError(
        error.InvalidObjectKey,
        client.putObject(bucket_name, "", "test"),
    );
}

test "pagination and prefixes" {
    std.debug.print("\n=== Starting pagination and prefixes test ===\n", .{});
    // Initialize client

    const config = try createS3ClientConfig();
    var client = try s3.S3Client.init(allocator, io, config);
    defer client.deinit();

    const bucket_name = "pagination-test-bucket";
    client.createBucket(bucket_name) catch {};
    defer _ = client.deleteBucket(bucket_name) catch {};
    std.debug.print("Bucket created: {s}...\n", .{bucket_name});

    var uploader = client.uploader();

    // Create test objects with different prefixes
    const prefixes = [_][]const u8{ "folder1/", "folder2/", "folder3/" };
    var total_objects: usize = 0;

    for (prefixes) |prefix| {
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            const key = try std.fmt.allocPrint(
                allocator,
                "{s}file{d}.txt",
                .{ prefix, i },
            );
            defer allocator.free(key);
            const content = try std.fmt.allocPrint(
                allocator,
                "Content {d}",
                .{i},
            );
            defer allocator.free(content);
            try uploader.uploadString(bucket_name, key, content);
            total_objects += 1;
        }
    }
    std.debug.print("Files created ...\n", .{});

    // Test listing with different page sizes
    {
        const page_size: u32 = 7;
        var all_objects: std.ArrayList([]u8) = .empty;
        defer {
            for (all_objects.items) |object| {
                allocator.free(object);
            }
            all_objects.deinit(allocator);
        }

        std.debug.print("All objects array created ...\n", .{});
        var max_attempts: u16 = 10;
        while (max_attempts > 0) {
            max_attempts = max_attempts - 1;
            const page = try client.listObjects(bucket_name, .{
                .max_keys = page_size,
                .start_after = all_objects.getLastOrNull(),
            });

            defer {
                for (page) |item| {
                    allocator.free(item.key);
                    allocator.free(item.last_modified);
                    allocator.free(item.etag);
                }
                allocator.free(page);
            }

            if (page.len == 0) break;
            for (page) |data| {
                const key = try allocator.dupe(u8, data.key);
                try all_objects.append(allocator, key);
            }

            std.debug.print("\nSlice appended: {s} ...\n", .{all_objects.getLast()});

            if (page.len < page_size) break;
        }

        std.debug.print("Object appended, total objects: {d}, all objects: {d}...\n", .{ total_objects, all_objects.items.len });
        try testing.expectEqual(total_objects, all_objects.items.len);
    }

    std.debug.print("Object appended ...\n", .{});
    // Test listing with prefix
    for (prefixes) |prefix| {
        const objects = try client.listObjects(bucket_name, .{
            .prefix = prefix,
        });
        defer {
            var delete_list = std.ArrayList(s3.DeleteObjectParam).empty;
            defer delete_list.deinit(allocator);
            for (objects) |item| {
                _ = delete_list.append(allocator, .{ .key = item.key }) catch {};
            }
            _ = client.deleteObjectList(bucket_name, delete_list.items) catch {};

            for (objects) |object| {
                allocator.free(object.key);
                allocator.free(object.last_modified);
                allocator.free(object.etag);
            }
            allocator.free(objects);
        }

        try testing.expectEqual(@as(usize, 5), objects.len);
        for (objects) |object| {
            try testing.expect(std.mem.startsWith(u8, object.key, prefix));
        }
    }

    std.debug.print("Prefixes listed ...\n", .{});
}

test "file upload and download" {
    std.debug.print("\n=== Starting file upload and download test ===\n", .{});
    // Initialize client

    const config = try createS3ClientConfig();
    var client = try s3.S3Client.init(allocator, io, config);
    defer client.deinit();

    // Setup test bucket
    const bucket_name = "file-upload-test-bucket";
    try client.createBucket(bucket_name);
    defer _ = client.deleteBucket(bucket_name) catch {};

    var uploader = client.uploader();

    // Test text file upload
    {
        const s3_key = "text/sample.txt";
        try uploader.uploadFile(bucket_name, s3_key, "tests/integration/assets/sample.txt");

        // Verify uploaded content
        const downloaded = try client.getObject(bucket_name, s3_key);
        defer allocator.free(downloaded);
        std.debug.print("\nDownloaded: {s} ...\n", .{downloaded});

        // Read original file for comparison
        const dir = std.Io.Dir.cwd();
        const original_file = try dir.openFile(io, "tests/integration/assets/sample.txt", .{});
        defer original_file.close(io);

        std.debug.print("\nFile Size: {d} ...\n", .{try original_file.length(io)});
        var content_buffer: [124]u8 = undefined;
        _ = try original_file.readPositionalAll(io, &content_buffer, 0);

        std.debug.print("\nOriginal file: {s} ...\n", .{content_buffer});
        try testing.expectEqualStrings(&content_buffer, downloaded);
    }

    // Test JSON file upload
    {
        const s3_key = "json/config.json";
        try uploader.uploadFile(bucket_name, s3_key, "tests/integration/assets/config.json");

        // Verify uploaded content
        const downloaded = try client.getObject(bucket_name, s3_key);
        defer allocator.free(downloaded);

        // Read original file for comparison
        const dir = std.Io.Dir.cwd();
        const original_file = try dir.openFile(io, "tests/integration/assets/config.json", .{});
        defer original_file.close(io);

        std.debug.print("\nFile Size: {d} ...\n", .{try original_file.length(io)});
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
    try client.deleteObject(bucket_name, "text/sample.txt");
    try client.deleteObject(bucket_name, "json/config.json");

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
