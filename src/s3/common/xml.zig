const std = @import("std");
const mem = std.mem;

const XMLError = error{ KeyNotFound, UnableToAllocateKey };

pub fn getByKey(allocator: mem.Allocator, xml: []const u8, key: []const u8) ![]const u8 {
    const key_initial_bracket = try std.fmt.allocPrint(allocator, "<{s}>", .{key});
    defer allocator.free(key_initial_bracket);
    const key_end_bracket = try std.fmt.allocPrint(allocator, "</{s}>", .{key});
    defer allocator.free(key_end_bracket);

    const key_start = mem.indexOf(u8, xml, key_initial_bracket);
    const key_end = mem.indexOf(u8, xml, key_end_bracket);

    if (key_start == null or key_end == null) {
        return XMLError.KeyNotFound;
    }

    const initial_pos = (key_start orelse 0) + key_initial_bracket.len;
    const final_pos = key_end orelse 0;
    const value = allocator.dupe(u8, xml[initial_pos..final_pos]) catch {
        return XMLError.UnableToAllocateKey;
    };

    return value;
}

test "search xml" {
    const allocator = std.testing.allocator;
    const xml =
        \\<root>
        \\<random>51</random>
        \\<bool>true</bool>
        \\<name>Jillayne</name>
        \\</root>
    ;

    const test_items = [3]struct { key: []const u8, expected: []const u8 }{
        .{ .key = "random", .expected = "51" },
        .{ .key = "bool", .expected = "true" },
        .{ .key = "name", .expected = "Jillayne" },
    };

    for (test_items) |item| {
        const value_found = try getByKey(allocator, xml, item.key);
        defer allocator.free(value_found);

        try std.testing.expectEqualStrings(item.expected, value_found);
    }
}
