const std = @import("std");
const mem = std.mem;
const Writer = std.Io.Writer;

const query_symbols: [19]u8 = .{ '/', '=', ':', '?', '#', '[', ']', '@', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '%' };

pub fn encodeURI(allocator: mem.Allocator, text: []const u8) ![]const u8 {
    var out = try Writer.Allocating.initCapacity(allocator, text.len * 3);
    defer out.deinit();

    try std.Uri.Component.percentEncode(&out.writer, text, isNotQuerySymbol);
    try out.writer.flush();
    return try std.fmt.allocPrint(allocator, "{s}", .{out.written()});
}

fn isNotQuerySymbol(char: u8) bool {
    for (query_symbols) |symbol| {
        if (char == symbol) {
            return false;
        }
    }

    return true;
}

test "encode URI" {
    const allocator = std.testing.allocator;
    const values = [2]struct { value: []const u8, expected: []const u8 }{
        .{ .value = "bucket%/Prefix", .expected = "bucket%25%2FPrefix" },
        .{ .value = "bucket=encodedUri", .expected = "bucket%3DencodedUri" },
    };

    for (values) |uri| {
        const actual = try encodeURI(allocator, uri.value);
        defer allocator.free(actual);

        try std.testing.expectEqualSlices(u8, actual, uri.expected);
    }
}
