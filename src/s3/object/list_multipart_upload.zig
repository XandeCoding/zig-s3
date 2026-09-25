const std = @import("std");
const Uri = std.Uri;
const client_impl = @import("../client/implementation.zig");
const S3Client = client_impl.S3Client;
const errors = @import("../common/errors.zig");
const S3Error = errors.S3Error;

const ListMultipartObjectOptions = struct {
    bucket_name: []const u8,
    key: []const u8,
    upload_id: []const u8,
    max_parts: u8 = 100,
};

fn listMultipartUpload(self: *S3Client, options: ListMultipartObjectOptions) !void {
    const uri = try std.fmt.allocPrint(
        self.allocator,
        "{s}/{s}/{s}?max-parts={d}&uploadId={s}",
        .{ 
            self.config.endpoint,
            options.bucket_name, 
            options.key,
            options.max_parts,
            options.upload_id,
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

    const data = out.buffered();
    std.debug.print("\n{s}\n", .{data});
}
