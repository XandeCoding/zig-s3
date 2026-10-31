const common_operations = @import("common_operations.zig");
const uploader_test = @import("uploader_test.zig");

test "integration tests" {
    _ = .{
        common_operations,
        uploader_test,
    };
}
