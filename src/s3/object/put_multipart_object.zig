const std = @import("std");
const Uri = std.Uri;
const client_impl = @import("../client/implementation.zig");
const S3Client = client_impl.S3Client;
const errors = @import("../common/errors.zig");
const xml = @import("../common/xml.zig");
const S3Error = errors.S3Error;
const createBucket = @import("../bucket/lib.zig").createBucket;
const deleteBucket = @import("../bucket/lib.zig").deleteBucket;

const UPLOAD_PART_SIZE: usize = 1024 * 1024 * 5;





pub const PutMultipartObjectOptions = struct {
    bucket_name: []const u8,
    key: []const u8,
    reader: *std.Io.Reader,
};



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
    
    var out_size: usize = 1;
    var part_number: u8 = 1;

    // TODO: ANALISAR COMO DEIXAR DINÂMICO
    var upload_buffer: [UPLOAD_PART_SIZE]u8 = undefined;
    var upload_writer: std.Io.Writer = .fixed(&upload_buffer); 
    var e_tag_list: std.ArrayList([] const u8) = .empty;
    defer {
        for (e_tag_list.items) |object| {
            self.allocator.free(object);
        }
        e_tag_list.deinit(self.allocator);
    }


    while (out_size > 0) {
        out_size = options.reader.stream(&upload_writer, .limited(UPLOAD_PART_SIZE)) catch |err| {
            if (err == std.Io.Reader.StreamError.EndOfStream) break;
            // TODO: ABORTAR OPERACAO
            return S3Error.AbortedMultipartUpload;
        };
        defer _ = upload_writer.consumeAll();
        if (out_size == 0) break;

        const uri_string = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/{s}?partNumber={d}&uploadId={s}",
            .{
                self.config.endpoint,
                options.bucket_name,
                options.key,
                part_number,
                upload_id,
            }
        );
        defer self.allocator.free(uri_string);
        const uri = try Uri.parse(uri_string);

        std.debug.print("URL: {s}\n", .{ uri_string });

        std.debug.print("out_size: {d}\n", .{ out_size });
        part_number += 1;

        const upload_data = upload_writer.buffered();
        //std.debug.print("Data: {s}\n", .{ upload_data });

        const req = try self.requestWriter(.{
            .method = .PUT, 
            .uri = uri, 
            .payload = upload_data, 
            .response_body_writer = null,
        });
        defer {
            if (req.headers.content_type != null) self.allocator.free(req.headers.content_type.?);
        }

        //std.debug.print("\nResponse: {any}\n", .{req.headers});
        if (req.headers.e_tag) |e_tag| {
           try e_tag_list.append(self.allocator, e_tag);
        }

        if (req.status == .bad_request) {
            return S3Error.InvalidObjectKey;
        }
        if (req.status != .ok) {
            return S3Error.InvalidResponse;
        }
    }

    //try listMultipartUpload(self, .{
    //    .bucket_name = options.bucket_name,
    //    .key = options.key,
    //    .upload_id = upload_id,
    //});

    std.debug.print("\nEtags: {any}", .{e_tag_list.items});
    try completeMultipartUpload(self, .{
        .bucket_name = options.bucket_name,
        .key = options.key,
        .upload_id = upload_id,
        .e_tag_list = e_tag_list.items,
    });
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
    var upload_reader: std.Io.Reader = .fixed("o" ** (1024 * 1024 * 15));

    try putMultipartObject(test_client, .{ .bucket_name = bucket_name, .key = "test_multipart.o", .reader = &upload_reader });
}
