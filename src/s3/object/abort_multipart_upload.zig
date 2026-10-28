const std = @import("std");
const Uri = std.Uri;
const client_impl = @import("../client/implementation.zig");
const S3Client = client_impl.S3Client;
const errors = @import("../common/errors.zig");
const S3Error = errors.S3Error;

// TODO: IMPLEMENT ANOTHER OPTIONS FROM AWS DOC
pub const AbortMultipartUploadOptions = struct {};

pub fn abortMultipartUpload(
    self: *S3Client,
    bucket_name: []const u8,
    key: []const u8,
    upload_id: []const u8,
    _: AbortMultipartUploadOptions,
) !void {
    const uri = try std.fmt.allocPrint(
        self.allocator,
        "{s}/{s}/{s}?uploadId={s}",
        .{ self.config.endpoint, bucket_name, key, upload_id },
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
