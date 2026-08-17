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

// TODO: CHECK IF CAN BE MOVED TO INTEGRATION TESTS

//test "object operations" {
//    const allocator = std.testing.allocator;
//    const io = std.testing.io;
//
//    const config = client_impl.S3Config{
//        .access_key_id = "admin",
//        .secret_access_key = "admin",
//        .region = "us-east-1",
//        .endpoint = "http://localhost:9000",
//    };
//
//    var test_client = try S3Client.init(allocator, io, config);
//    defer test_client.deinit();
//
//    const bucket_name = "object-operations-test";
//    try bucket_ops.createBucket(test_client, bucket_name);
//    defer _ = bucket_ops.deleteBucket(test_client, .{ .bucket_name = bucket_name }) catch {};
//
//    // Test basic object lifecycle
//    const test_data = "Hello, S3!";
//    try putObject(test_client, bucket_name, "admin", test_data);
//
//    const retrieved = try getObject(test_client, bucket_name, "admin");
//    defer allocator.free(retrieved);
//    try std.testing.expectEqualStrings(test_data, retrieved);
//
//    try deleteObject(test_client, bucket_name, "admin");
//}

//test "object operations with custom endpoint" {
//    const allocator = std.testing.allocator;
//    const io = std.testing.io;
//
//    const config = client_impl.S3Config{
//        .access_key_id = "admin",
//        .secret_access_key = "admin",
//        .region = "us-east-1",
//        .endpoint = "http://localhost:9000",
//    };
//
//    var test_client = try S3Client.init(allocator, io, config);
//    defer test_client.deinit();
//
//    // Test object operations with custom endpoint
//    const bucket_name = "custom-endpoint-bucket";
//    try bucket_ops.createBucket(test_client, bucket_name);
//    defer _ = bucket_ops.deleteBucket(test_client, .{ .bucket_name = bucket_name }) catch {};
//
//    const test_data = "Testing with custom endpoint";
//    try putObject(test_client, bucket_name, "custom-endpoint-test.txt", test_data);
//
//    const retrieved = try getObject(test_client, bucket_name, "custom-endpoint-test.txt");
//    defer allocator.free(retrieved);
//
//    try std.testing.expectEqualStrings(test_data, retrieved);
//
//    try deleteObject(test_client, bucket_name, "custom-endpoint-test.txt");
//}
