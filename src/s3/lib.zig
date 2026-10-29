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
//! try client.createBucket(.{ .bucket_name = "my-bucket" });
//! try client.putObject(.{ .bucket_name = "my-bucket", .key = "hello.txt", .data = "Hello, S3!" });
//! ```
const std = @import("std");
const client = @import("client/implementation.zig");
const errors = @import("common/errors.zig");
const object_uploader = @import("object/object_uploader.zig");
const list_buckets = @import("bucket/list_buckets.zig");
const create_bucket = @import("bucket/create_bucket.zig");
const delete_bucket = @import("bucket/delete_bucket.zig");
const put_object = @import("object/put_object.zig");
const get_object = @import("object/get_object.zig");
const delete_object = @import("object/delete_object.zig");
const list_objects = @import("object/list_objects.zig");
const create_multipart_object = @import("object/create_multipart_upload.zig");
const list_multipart_object = @import("object/list_multipart_upload.zig");
const abort_multipart_object = @import("object/abort_multipart_upload.zig");
const put_multipart_object = @import("object/put_multipart_object.zig");
const complete_multipart_object = @import("object/complete_multipart_upload.zig");

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
pub const BucketInfo = list_buckets.BucketInfo;

/// Information about an object in S3
pub const ObjectInfo = list_objects.ObjectInfo;

/// Options for listing objects in a bucket
pub const ListObjectsOptions = list_objects.ListObjectsOptions;

/// Helper struct for uploading different types of content to S3
pub const ObjectUploader = object_uploader.ObjectUploader;

/// Options to create the helper struct to upload objects
pub const ObjectUploaderOptions = object_uploader.ObjectUploaderOptions;

/// Options to list multipart upload parts
pub const ListMultipartUploadOptions = list_multipart_object.ListMultipartUploadOptions;

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
    /// See bucket/create_bucket.zig for details.
    pub fn createBucket(self: *S3Client, bucket_name: []const u8, options: create_bucket.CreateBucketOptions) !void {
        return create_bucket.createBucket(self.inner, bucket_name, options);
    }

    /// Delete an existing bucket.
    /// See bucket/delete_bucket.zig for details.
    pub fn deleteBucket(self: *S3Client, bucket_name: []const u8, options: delete_bucket.DeleteBucketOptions) !void {
        return delete_bucket.deleteBucket(self.inner, bucket_name, options);
    }

    /// List all buckets owned by the authenticated user.
    /// See bucket/delete_bucket.zig for details.
    pub fn listBuckets(self: *S3Client, options: list_buckets.ListBucketsOptions) ![]BucketInfo {
        return list_buckets.listBuckets(self.inner, options);
    }

    /// Upload an object to S3.
    /// See object/put_object.zig for details.
    pub fn putObject(
        self: *S3Client,
        bucket_name: []const u8,
        key: []const u8,
        data: []const u8,
        options: put_object.PutObjectOptions,
    ) !void {
        return put_object.putObject(self.inner, bucket_name, key, data, options);
    }

    /// Download an object from S3.
    /// See object/get_object.zig for details.
    pub fn getObject(
        self: *S3Client,
        bucket_name: []const u8,
        key: []const u8,
        options: get_object.GetObjectOptions,
    ) ![]const u8 {
        return get_object.getObject(self.inner, bucket_name, key, options);
    }

    /// Delete an object from S3.
    /// See object/delete_object.zig for details.
    pub fn deleteObject(
        self: *S3Client,
        bucket_name: []const u8,
        key: []const u8,
        options: delete_object.DeleteObjectOptions,
    ) !void {
        return delete_object.deleteObject(self.inner, bucket_name, key, options);
    }

    /// List objects in a bucket with optional filtering and pagination.
    /// See object/list_objects.zig for details.
    pub fn listObjects(
        self: *S3Client,
        bucket_name: []const u8,
        options: list_objects.ListObjectsOptions,
    ) ![]ObjectInfo {
        return list_objects.listObjects(self.inner, bucket_name, options);
    }

    /// Create multipart upload
    /// See object/create_multipart_upload.zig for details
    pub fn createMultipartUpload(
        self: *S3Client,
        bucket_name: []const u8,
        key: []const u8,
        options: create_multipart_object.CreateMultipartUploadOptions,
    ) ![]const u8 {
        return create_multipart_object.createMultipartUpload(self.inner, bucket_name, key, options);
    }

    /// List multipart upload parts already uploaded
    /// See object/list_multipart_upload.zig for details
    pub fn listMultipartUpload(
        self: *S3Client,
        bucket_name: []const u8,
        key: []const u8,
        upload_id: []const u8,
        options: list_multipart_object.ListMultipartUploadOptions,
    ) ![]const u8 {
        return list_multipart_object.listMultipartUpload(self.inner, bucket_name, key, upload_id, options);
    }

    /// Abort a multipart upload process
    /// See object/abort_multipart_upload.zig for details
    pub fn abortMultipartUpload(
        self: *S3Client,
        bucket_name: []const u8,
        key: []const u8,
        upload_id: []const u8,
        options: abort_multipart_object.AbortMultipartUploadOptions,
    ) !void {
        return abort_multipart_object.abortMultipartUpload(self.inner, bucket_name, key, upload_id, options);
    }

    /// Put a multipart upload part
    /// See object/put_multipart_upload.zig for details
    pub fn putMultipartUpload(
        self: *S3Client,
        bucket_name: []const u8,
        key: []const u8,
        upload_id: []const u8,
        part_number: u8,
        data: []const u8,
        options: put_multipart_object.PutMultipartUploadOptions,
    ) ![]const u8 {
        return put_multipart_object.putMultipartUpload(
            self.inner,
            bucket_name,
            key,
            upload_id,
            part_number,
            data,
            options,
        );
    }

    /// Complete the multipart upload part
    /// See object/complete_multipart_upload.zig
    pub fn completeMultipartUpload(
        self: *S3Client,
        bucket_name: []const u8,
        key: []const u8,
        upload_id: []const u8,
        e_tag_list: [][]const u8,
        options: complete_multipart_object.CompleteMultipartUploadOptions,
    ) !void {
        return complete_multipart_object.completeMultipartUpload(
            self.inner,
            bucket_name,
            key,
            upload_id,
            e_tag_list,
            options,
        );
    }

    /// Create an object uploader helper for this client
    pub fn uploader(self: *S3Client, options: object_uploader.ObjectUploaderOptions) ObjectUploader {
        return ObjectUploader.init(self.inner, options);
    }
};
