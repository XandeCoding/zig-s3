const std = @import("std");
const Uri = std.Uri;
const client_impl = @import("../client/implementation.zig");
const S3Client = client_impl.S3Client;
const errors = @import("../common/errors.zig");
const S3Error = errors.S3Error;

// TODO: ADD KEYMARKER OPTION TO PAGINATE
pub const ListMultipartUploadOptions = struct {
    max_parts: u8 = 100,
};

pub fn listMultipartUpload(
    self: *S3Client,
    bucket_name: []const u8,
    key: []const u8,
    upload_id: []const u8,
    options: ListMultipartUploadOptions,
) ![]const u8 {
    if (options.max_parts > 1000) {
        return S3Error.UnprocessableParameter;
    }

    const uri = try std.fmt.allocPrint(
        self.allocator,
        "{s}/{s}/{s}?max-parts={d}&uploadId={s}",
        .{
            self.config.endpoint,
            bucket_name,
            key,
            options.max_parts,
            upload_id,
        },
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

    // TODO: IMPROVE THIS
    return out.buffered();
}
