//! S3 Client Library for Zig
//!
//! This library provides a simple interface for interacting with Amazon S3 and S3-compatible services.
//! It supports basic operations like creating/deleting buckets and uploading/downloading objects.
//!
//! Basic usage:
//! ```zig
//! const S3Client = @import("s3").S3Client;
//! const S3Config = @import("s3").S3Config;
//!
//! // Initialize client
//! var client = try S3Client.init(allocator, .{
//!     .access_key_id = "your-key",
//!     .secret_access_key = "your-secret",
//!     .region = "us-east-1",
//! });
//! defer client.deinit();
//!
//! // Use the client
//! try client.createBucket("my-bucket");
//! try client.putObject("my-bucket", "hello.txt", "Hello, S3!");
//! ```
const std = @import("std");
const client = @import("client/implementation.zig");
const bucket_ops = @import("bucket/operations.zig");
const object_ops = @import("object/operations.zig");
const errors = @import("common/errors.zig");

/// Configuration for the S3 client handler.
/// This includes AWS credentials and regional settings.
pub const S3ClientConfig = struct {
    /// AWS access key ID or compatible credential
    access_key_id: []const u8,
    /// AWS secret access key or compatible credential
    secret_access_key: []const u8,
    /// AWS region (e.g., "us-east-1") - default is "us-east-1"
    region: ?[]const u8 = null,
    /// custom endpoint for S3-compatible services (e.g., MinIO, LocalStack) when not passed points to AWS S3 solution
    endpoint: ?[]const u8 = null,
};

pub const S3Error = errors.S3Error;

/// Configuration type for S3 client
pub const S3Config = client.S3Config;

/// Information about a bucket in S3
pub const BucketInfo = bucket_ops.BucketInfo;

/// Information about an object in S3
pub const ObjectInfo = object_ops.ObjectInfo;

/// Options for listing objects in a bucket
pub const ListObjectsOptions = object_ops.ListObjectsOptions;

/// Helper struct for uploading different types of content to S3
pub const ObjectUploader = object_ops.ObjectUploader;

/// Main client interface that provides S3 operations.
/// This struct wraps the internal implementation and provides a clean public API.
pub const S3Client = struct {
    /// Internal client implementation
    inner: *client.S3Client,

    /// Initialize a new S3 client with the given configuration.
    /// Memory is allocated for the client and must be freed with deinit.
    ///
    /// Arguments:
    ///     allocator: Memory allocator for the client
    ///     config: S3 configuration including credentials
    ///
    /// Returns: Initialized S3Client
    ///
    /// Errors:
    ///     OutOfMemory: If client allocation fails
    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: S3ClientConfig) !S3Client {
        const region = config.region orelse "us-east-1";
        const endpoint_blk = blk: {
            var buffer: [128]u8 = undefined;
            const endpoint = try std.fmt.bufPrint(
                &buffer,
                "https://s3.{s}.amazonaws.com",
                .{region},
            );
            break :blk endpoint;
        };
        const endpoint = config.endpoint orelse endpoint_blk;

        return S3Client{
            .inner = try client.S3Client.init(allocator, io, .{
                .access_key_id = config.access_key_id,
                .secret_access_key = config.secret_access_key,
                .region = region,
                .endpoint = endpoint,
            }),
        };
    }

    /// Clean up resources used by the client.
    /// This must be called when done with the client to avoid memory leaks.
    pub fn deinit(self: *S3Client) void {
        self.inner.deinit();
    }

    /// Create a new bucket.
    /// See bucket/operations.zig for details.
    pub fn createBucket(self: *S3Client, bucket_name: []const u8) !void {
        return bucket_ops.createBucket(self.inner, bucket_name);
    }

    /// Delete an existing bucket.
    /// See bucket/operations.zig for details.
    pub fn deleteBucket(self: *S3Client, bucket_name: []const u8) !void {
        return bucket_ops.deleteBucket(self.inner, bucket_name);
    }

    /// List all buckets owned by the authenticated user.
    /// Memory for the returned slice and its contents must be freed by the caller.
    ///
    /// Returns: Slice of BucketInfo structs
    ///
    /// Errors:
    ///     InvalidCredentials: If authentication fails
    ///     InvalidResponse: If listing fails
    ///     ConnectionFailed: Network or connection issues
    ///     OutOfMemory: Memory allocation failure
    pub fn listBuckets(self: *S3Client) ![]BucketInfo {
        return bucket_ops.listBuckets(self.inner);
    }

    /// Upload an object to S3.
    /// See object/operations.zig for details.
    pub fn putObject(self: *S3Client, bucket_name: []const u8, key: []const u8, data: []const u8) !void {
        return object_ops.putObject(self.inner, bucket_name, key, data);
    }

    /// Download an object from S3.
    /// See object/operations.zig for details.
    pub fn getObject(self: *S3Client, bucket_name: []const u8, key: []const u8) ![]const u8 {
        return object_ops.getObject(self.inner, bucket_name, key);
    }

    /// Delete an object from S3.
    /// See object/operations.zig for details.
    pub fn deleteObject(self: *S3Client, bucket_name: []const u8, key: []const u8) !void {
        return object_ops.deleteObject(self.inner, bucket_name, key);
    }

    /// List objects in a bucket with optional filtering and pagination.
    /// Memory for the returned slice and its contents must be freed by the caller.
    ///
    /// Arguments:
    ///     bucket_name: Name of the bucket to list
    ///     options: Optional parameters for filtering and pagination
    ///
    /// Returns: Slice of ObjectInfo structs
    ///
    /// Errors:
    ///     BucketNotFound: If the bucket doesn't exist
    ///     InvalidResponse: If listing fails
    ///     ConnectionFailed: Network or connection issues
    ///     OutOfMemory: Memory allocation failure
    pub fn listObjects(self: *S3Client, bucket_name: []const u8, options: ListObjectsOptions) ![]ObjectInfo {
        return object_ops.listObjects(self.inner, bucket_name, options);
    }

    /// Create an object uploader helper for this client
    pub fn uploader(self: *S3Client) ObjectUploader {
        return ObjectUploader.init(self.inner);
    }
};

