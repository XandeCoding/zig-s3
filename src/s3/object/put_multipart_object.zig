const std = @import("std");
const Uri = std.Uri;
const client_impl = @import("../client/implementation.zig");
const S3Client = client_impl.S3Client;
const errors = @import("../common/errors.zig");
const xml = @import("../common/xml.zig");
const S3Error = errors.S3Error;

const UPLOAD_PART_SIZE: usize = 1024 * 1024 * 5;

pub const PutMultipartUploadOptions = struct {};

pub fn putMultipartObject(
    self: *S3Client,
    bucket_name: []const u8,
    key: []const u8,
    upload_id: []const u8,
    part_number: u8,
    data: []const u8,
    _: PutMultipartUploadOptions,
) ![]const u8 {
    const uri_string = try std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}?partNumber={d}&uploadId={s}", .{
        self.config.endpoint,
        bucket_name,
        key,
        part_number,
        upload_id,
    });
    defer self.allocator.free(uri_string);
    const uri = try Uri.parse(uri_string);

    const req = try self.requestWriter(.{
        .method = .PUT,
        .uri = uri,
        .payload = data,
        .response_body_writer = null,
    });
    defer {
        if (req.headers.content_type != null) self.allocator.free(req.headers.content_type.?);
    }

    if (req.status == .bad_request) {
        return error.InvalidObjectKey;
    }
    if (req.status != .ok) {
        return error.InvalidResponse;
    }

    return if (req.headers.e_tag != null and req.headers.e_tag.?.len == 0) req.header.e_tag else error.InvalidResponse;
}
