const std = @import("std");
const client_impl = @import("../client/implementation.zig");
const S3Client = client_impl.S3Client; 

const URLQueryParam = struct {
    name: []const u8,
    value: []const u8,
};

// TODO: TRATAR ANOTHER TYPES OF HOST
pub fn create_url(
    client: *S3Client, 
    path_params: [][]const u8, 
    query_params: []const URLQueryParam,
) ![]const u8 {
    const out: std.Io.Writer.Allocating = .allocating(client.allocator);
    defer out.deinit();

    out.writer.writeAll(client.config.endpoint);

    for (path_params) |path| {
        out.writer.writeAll("/");
        out.writer.writeAll(path);
    }

    if (query_params.len == 0) return out.written();

    out.writer.writeAll("?");
    out.writer.writeAll(query_params[0]);

    for (query_params[1..]) |query| {
        out.writer.writeAll("&");
        out.writer.writeAll(query);
    }
    
    return out.written();
}
