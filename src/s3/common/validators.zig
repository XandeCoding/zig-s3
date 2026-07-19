const std = @import("std");
const ascii = std.ascii;

pub fn bucketNameIsValid(name: []const u8) bool {
    if (name.len < 3) return false;
    if (name.len > 63) return false;
    if (name[0] == '-') return false;
    if (name[0] == '.') return false;
    if (name[name.len - 1] == '-') return false;
    if (name[name.len - 1] == '.') return false;

    for (name) |char| {
        switch (char) {
            'a'...'z' => continue,
            '0'...'9' => continue,
            '-', '.' => continue,
            else => return false,
        }
    }

    return true;
}

pub fn objectNameIsValid(name: []const u8) bool {
    if (name.len < 1) return false;
    if (name.len > 1024) return false;

    for (name) |char| {
        switch (char) {
            'a'...'z' => continue,
            'A'...'Z' => continue,
            '0'...'9' => continue,
            '!', '-', '_', '.', '*', '\'', '(', ')' => continue,
            // THAT SPECIAL CHARACTERS MUST BE ENCODED
            '&', '$', '@', '=', ';', '/', ':', '+', ',', '?' => continue,
            else => return false,
        }
    }

    return true;
}

test "invalid bucket names" {
    const bucket_names: [8][]const u8 = .{
        "aa",               "film-jurassic-park-undiscovered-world-bucket-name-long-sized-not",
        "-abcd",            ".abcd",
        "abcd-",            "abcd.",
        "UPPERCASE-BUCKET", "bucket-#",
    };

    for (bucket_names) |name| {
        try std.testing.expect(bucketNameIsValid(name) == false);
    }
}

test "valid bucket names" {
    const bucket_names: [4][]const u8 = .{
        "test-bucket", "bucket.test",
        "1-test",      "test-01",
    };

    for (bucket_names) |name| {
        try std.testing.expect(bucketNameIsValid(name) == true);
    }
}

test "invalid object names" {
    var buffer: [1025]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    for (0..1025) |_| {
        try writer.print("{s}", .{"a"});
    }

    const long_object_name = writer.buffered();
    const object_names: [6][]const u8 = .{
        "",           long_object_name,
        "\tes",       "&%test",
        "]~brackets", "\"quotation_mark",
    };

    for (object_names) |name| {
        try std.testing.expect(objectNameIsValid(name) == false);
    }
}

test "valid object names" {
    const object_names: [6][]const u8 = .{
        "test_object_name", "TEST_OBJECT_NAME",
        "01-Object",        "Object*Special",
        "(Test).Name",      "!..T",
    };

    for (object_names) |name| {
        try std.testing.expect(objectNameIsValid(name) == true);
    }
}
