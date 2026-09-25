const std = @import("std");
const Uri = std.Uri;
const client_impl = @import("../client/implementation.zig");
const xml = @import("../common/xml.zig");
const S3Client = client_impl.S3Client;
const errors = @import("../common/errors.zig");
const S3Error = errors.S3Error;


const CompleteMultipartObjectOptions = struct {
    bucket_name: []const u8,
    key: []const u8,
    upload_id: []const u8,
    e_tag_list: [][]const u8,
};

fn completeMultipartUpload(self: *S3Client, options: CompleteMultipartObjectOptions) !void {
    const uri = try std.fmt.allocPrint(
        self.allocator,
        "{s}/{s}/{s}?uploadId={s}",
        .{ self.config.endpoint, options.bucket_name, options.key, options.upload_id },
    );
    defer self.allocator.free(uri);

    var out: std.Io.Writer.Allocating = try .initCapacity(self.allocator, 8096);
    defer out.deinit();
    
    var part_number: u8 = 1;
    try out.writer.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
    try out.writer.writeAll("<CompleteMultipartUpload xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">");
    for (options.e_tag_list) |e_tag| {
        try out.writer.writeAll("<Part>");
        try out.writer.print("<PartNumber>{d}</PartNumber>", .{ part_number });
        try out.writer.print("<ETag>{s}</ETag>", .{ e_tag });
        try out.writer.writeAll("</Part>");
        
        part_number += 1;
    }

    try out.writer.writeAll("</CompleteMultipartUpload>");
    try out.writer.flush();

    const data = out.writer.buffered();

    std.debug.print("\nComplete\n {s}\n", .{ data });

    var buff: [4096]u8 = undefined;
    var body_writer: std.Io.Writer = .fixed(&buff);

    const req = try self.request(
        .POST,
        try Uri.parse(uri),
        &body_writer,
        data,
    );

    const response = body_writer.buffered();
    std.debug.print("\nBody Response: {s}", .{ response });

    _  = xml.getByKey(self.allocator, response, "Error") catch |err| {
        if (err != xml.XMLError.KeyNotFound) return S3Error.InvalidResponse;
    };

    if (req.status != .ok) {
        return S3Error.InvalidResponse;
    }
}

