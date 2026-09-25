const std = @import("std");
const Uri = std.Uri;
const client_impl = @import("../client/implementation.zig");
const S3Client = client_impl.S3Client;
const errors = @import("../common/errors.zig");
const S3Error = errors.S3Error;

const AbortMultipartObjectOptions = struct {
    bucket_name: []const u8,
    key: []const u8,
    upload_id: []const u8,
};

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
