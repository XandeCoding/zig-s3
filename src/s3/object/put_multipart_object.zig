const std = @import("std");
const Uri = std.Uri;
const client_impl = @import("../client/implementation.zig");
const S3Client = client_impl.S3Client;
const errors = @import("../common/errors.zig");
const xml = @import("../common/xml.zig");
const S3Error = errors.S3Error;
const createBucket = @import("../bucket/lib.zig").createBucket;
const deleteBucket = @import("../bucket/lib.zig").deleteBucket;

const CreateMultipartObjectOptions = struct {
    bucket_name: []const u8,
    key: []const u8,
};

const AbortMultipartObjectOptions = struct {
    bucket_name: []const u8,
    key: []const u8,
    upload_id: []const u8,
};

pub const PutMultipartObjectOptions = struct {
    bucket_name: []const u8,
    key: []const u8,
    reader: *std.Io.Reader,
};

// TODO: COLOCAR EM ARQUIVO ESPECIFICO
fn listMultipartUpload(self: *S3Client, options: AbortMultipartObjectOptions) !void {
    const uri = try std.fmt.allocPrint(
        self.allocator,
        "{s}/{s}/{s}?max-parts=100&uploadId={s}",
        .{ self.config.endpoint, options.bucket_name, options.key, options.upload_id },
    );
    defer self.allocator.free(uri);
    var buffer: [8096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);

    const req = try self.request(
        .GET,
        try Uri.parse(uri),
        &out,
        null,
    );

    if (req.status != .ok) {
        return S3Error.InvalidResponse;
    }

    const data = out.buffered();
    std.debug.print("\n{s}\n", .{data});
}

fn createMultipartUpload(self: *S3Client, options: CreateMultipartObjectOptions) ![]const u8 {
    const uri = try std.fmt.allocPrint(
        self.allocator,
        "{s}/{s}/{s}?uploads=",
        .{ self.config.endpoint, options.bucket_name, options.key },
    );
    defer self.allocator.free(uri);
    var buffer: [8096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);

    const req = try self.request(
        .POST,
        try Uri.parse(uri),
        &out,
        null,
    );

    if (req.status != .ok) {
        return S3Error.InvalidResponse;
    }

    const data = out.buffered();
    std.debug.print("\n{s}\n", .{data});
    const upload_id = try xml.getByKey(self.allocator, data, "UploadId");

    std.debug.print("\nUploadId: {s}\n", .{upload_id});

    return upload_id;
}

fn abortMultipartUpload(self: *S3Client, options: AbortMultipartObjectOptions) !void {
    const uri = try std.fmt.allocPrint(
        self.allocator,
        "{s}/{s}/{s}?uploadId={s}",
        .{ self.config.endpoint, options.bucket_name, options.key, options.upload_id },
    );
    defer self.allocator.free(uri);
    const req = try self.request(
        .DELETE,
        try Uri.parse(uri),
        null,
        null,
    );

    if (req.status != .ok) {
        return S3Error.InvalidResponse;
    }
}

pub fn putMultipartObject(self: *S3Client, options: PutMultipartObjectOptions) !void {
    const upload_id = try createMultipartUpload(self, .{
        .bucket_name = options.bucket_name,
        .key = options.key,
    });
    defer self.allocator.free(upload_id);
    //errdefer {
    //    _ = abortMultipartUpload(
    //        self, .{
    //            .bucket_name = options.bucket_name,
    //            .key = options.key,
    //            .upload_id = upload_id,
    //        }
    //    ) catch {
    //        return S3Error.InvalidObjectKey;
    //    };
    //}

    // TODO: GERAR EM UM LOOP PARA ITERAR O PART_NUMBER
    const uri = try std.fmt.allocPrint(
        self.allocator,
        "{s}/{s}/{s}?partNumber=1&uploadId={s}",
        .{
            self.config.endpoint,
            options.bucket_name,
            options.key,
            upload_id,
        },
    );
    defer self.allocator.free(uri);
    try listMultipartUpload(self, .{
        .bucket_name = options.bucket_name,
        .key = options.key,
        .upload_id = upload_id,
    });
    // TODO: FAZER LEITURA EM BLOCOS
    var upload_buffer: [1024 * 1024 * 10]u8 = undefined;
    _ = try options.reader.readSliceAll(&upload_buffer);

    var buffer: [8096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);

    const req = try self.request(
        .PUT,
        try Uri.parse(uri),
        &out,
        options.reader.buffered(),
    );

    const response_data = out.buffered();
    std.debug.print("\nResponse: {s}\n", .{response_data});

    if (req.status == .bad_request) {
        return S3Error.InvalidObjectKey;
    }
    if (req.status != .ok) {
        return S3Error.InvalidResponse;
    }

}

test "Before All - Put Multipart Object" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var test_client = try S3Client.init(allocator, io, client_impl.S3Config{
        .access_key_id = "admin",
        .secret_access_key = "admin",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    });
    defer test_client.deinit();

    const buckets_name: [1][]const u8 = .{
        "multipart-object-upload",
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

    try group.await(io_threaded);
}

test "put multipart upload object" {
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

    const bucket_name = "multipart-object-upload";
    var upload_reader: std.Io.Reader = .fixed("1multipart" ** 2000000);

    try putMultipartObject(test_client, .{ .bucket_name = bucket_name, .key = "test_multipart", .reader = &upload_reader });
}
