const std = @import("std");
const Uri = std.Uri;
const client_impl = @import("../client/implementation.zig");
const xml = @import("../common/xml.zig");
const S3Client = client_impl.S3Client;
const errors = @import("../common/errors.zig");
const S3Error = errors.S3Error;

const CreateMultipartObjectOptions = struct {
    bucket_name: []const u8,
    key: []const u8,
};

fn createMultipartUpload(
    self: *S3Client, 
    options: CreateMultipartObjectOptions
) ![]const u8 {
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
    const upload_id = try xml.getByKey(self.allocator, data, "UploadId");

    return upload_id;
}


