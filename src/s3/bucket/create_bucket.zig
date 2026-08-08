const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;
const Uri = std.Uri;
const fmt = std.fmt;

const client_impl = @import("../client/implementation.zig");
const S3Error = @import("../common/errors.zig").S3Error;
const S3Client = client_impl.S3Client;
const validators = @import("../common/validators.zig");
const operations = @import("./operations.zig");

pub const CreateBucketOptions = struct {
    bucket_name: []const u8,
    object_lock: ?bool = null,
};

/// Create a new bucket in S3.
///
/// The bucket name must be globally unique across all AWS accounts.
/// For S3-compatible services, uniqueness might only be required within your endpoint.
///
/// Parameters:
///   - self: Pointer to initialized S3Client
///   - bucket_name: Name of the bucket to create
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
pub fn createBucket(self: *S3Client, create_bucket_params: CreateBucketOptions) !void {
    const bucket_name = create_bucket_params.bucket_name;
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
            // RustFS yet implemented name validation partially
            .not_implemented => {
                return S3Error.ServerNotImplemented;
            },
            else => {
                return S3Error.InvalidResponse;
            },
        }
    }
}


test "create simple bucket" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Initialize test client with dummy credentials
    var test_client = try S3Client.init(allocator, io, client_impl.S3Config{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    });
    defer test_client.deinit();

    // Test basic bucket lifecycle
    try createBucket(test_client, .{ .bucket_name = "test-bucket" });
}

test "bucket operations with custom endpoint" {
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

    // Test bucket operations with custom endpoint
    const bucket_name = "test-bucket-local";
    try createBucket(test_client, bucket_name);
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
        createBucket(test_client, .{ .bucket_name = "" }),
    );

// TODO: CREATE TEST TO DELETE AN EMPTY BUCKET
   // try std.testing.expectError(
   //     error.InvalidResponse,
   //     deleteBucket(test_client, ""),
   // );
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
        createBucket(test_client, "Invalid.Bucket.Name"),
    );

    // Test creating bucket with invalid length
    try std.testing.expectError(
        error.InvalidBucketName,
        createBucket(test_client, "a"),
    );

    // Create a bucket and try to create it again
    const bucket_name = "duplicate-test-bucket";
    try createBucket(test_client, bucket_name);

    // RustFS permits to recreate a bucket with the same name multiple times (MinIO no)
    createBucket(test_client, bucket_name) catch |err| {
        try std.testing.expect(S3Error.BucketAlreadyExists == err);
        return;
    };
}

test "bucket operations region handling" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Test different regions
    const regions = [_][]const u8{
        "us-east-1",
        "us-west-1",
        "eu-west-1",
        "ap-southeast-1",
    };

    for (regions) |region| {
        const config = client_impl.S3Config{
            .access_key_id = "admin",
            .secret_access_key = "admin",
            .region = region,
            .endpoint = "http://localhost:9000",
        };

        var test_client = try S3Client.init(allocator, io, config);
        defer test_client.deinit();

        const bucket_name = try fmt.allocPrint(
            allocator,
            "region-test-bucket-{s}",
            .{region},
        );
        defer allocator.free(bucket_name);

        // Basic operations should work in any region
        createBucket(test_client, .{ .bucket_name = bucket_name });
    }
}

test "create multiple buckets and check if exists" {
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

    // Create multiple buckets concurrently
    const bucket_names = [_][]const u8{
        "concurrent-bucket-1",
        "concurrent-bucket-2",
        "concurrent-bucket-3",
        "concurrent-bucket-4",
        "concurrent-bucket-5",
    };

    // Create all buckets
    for (bucket_names) |name| {
        try createBucket(test_client, name);
    }

    // Verify all buckets exist
    const buckets = try operations.listBuckets(test_client);
    defer {
        for (buckets) |bucket| {
            allocator.free(bucket.name);
            allocator.free(bucket.creation_date);
        }
        allocator.free(buckets);
    }

    for (bucket_names) |name| {
        var found = false;
        for (buckets) |bucket| {
            if (std.mem.eql(u8, bucket.name, name)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

// TODO: BREAK THIS TEST IN TWO?
test "create buckets with special characters" {
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

    // Test bucket names with various special characters
    const test_cases = [_]struct {
        name: []const u8,
        should_succeed: bool,
    }{
        .{ .name = "normal-bucket-123", .should_succeed = true },
        .{ .name = "bucket-with-dash", .should_succeed = true },
        .{ .name = "bucket.with.dots", .should_succeed = true },
        .{ .name = "bucket_with_underscore", .should_succeed = false },
        .{ .name = "UPPERCASE-bucket", .should_succeed = false },
        .{ .name = "bucket@with@at", .should_succeed = false },
        .{ .name = "bucket#with#hash", .should_succeed = false },
        .{ .name = "3-numeric-prefix", .should_succeed = true },
        .{ .name = "-invalid-prefix", .should_succeed = false },
        .{ .name = "invalid-suffix-", .should_succeed = false },
        .{ .name = "a", .should_succeed = false }, // Too short
        .{ .name = "ab", .should_succeed = false }, // Too short
        .{ .name = "a" ** 64, .should_succeed = false }, // Too long
    };

    for (test_cases) |case| {
        if (case.should_succeed) {
            // Should succeed
            try createBucket(test_client, case.name);

            // Verify bucket exists
            const buckets = try operations.listBuckets(test_client);
            defer {
                for (buckets) |bucket| {
                    allocator.free(bucket.name);
                    allocator.free(bucket.creation_date);
                }
                allocator.free(buckets);
            }

            var found = false;
            for (buckets) |bucket| {
                if (std.mem.eql(u8, bucket.name, case.name)) {
                    found = true;
                    break;
                }
            }
            try std.testing.expect(found);
        } else {
            // Should fail
            try std.testing.expectError(
                error.InvalidBucketName,
                createBucket(test_client, case.name),
            );
        }
    }
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
    const invalid_names = [_][]const u8{
        "", // Empty
        "a", // Too short
        "ab", // Too short
        "ThisHasUpperCase", // Contains uppercase
        "contains_underscore", // Contains underscore
        "a" ** 64, // Too long
    };

    for (invalid_names) |name| {
        try std.testing.expectError(
            error.InvalidBucketName,
            createBucket(test_client, .{ .bucket_name = name }),
        );
    }

    // Test valid bucket names
    const valid_names = [_][]const u8{
        "valid-bucket-name",
        "another-valid-bucket",
        "123-numeric-prefix",
        "bucket-with-numbers-123",
        "contains.period",
    };

    for (valid_names) |name| {
        createBucket(test_client, .{ .bucket_name = name });
    }
}



test "After all" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_client = try S3Client.init(allocator, io, client_impl.S3Config{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    });
    defer test_client.deinit();

    //try operations.deleteBucket(test_client, "test-bucket");
    //TODO: Delete buckets from region test
}
