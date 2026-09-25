const std = @import("std");

const URLQueryParam = struct {
    name: []const u8,
    value: []const u8,
};

// TODO: TRATAR ANOTHER TYPES OF HOST
pub fn create_url(
    allocator: std.mem.Allocator, 
    endpoint: []const u8,
    path_params: [][]const u8, 
    query_params: ?[]const URLQueryParam,
) ![]const u8 {
    const out: std.Io.Writer.Allocating = .allocating(allocator);
    defer out.deinit();

    out.writer.writeAll(endpoint);

    for (path_params) |path| {
        out.writer.writeAll("/");
        out.writer.writeAll(path);
    }

    if (query_params == null) return out.written();

    out.writer.writeAll("?");
    out.writer.writeAll(query_params[0]);

    for (query_params[1..]) |query| {
        out.writer.writeAll("&");
        out.writer.writeAll(query);
    }
    
    return out.written();
}

test "Create basic URL" {
    const allocator = std.testing.allocator;
    std.testing.expectEqualStrings(
        create_url(allocator, "localhost:9000", "bucket", null),
        "localhost:9000/bucket",
    );
}
