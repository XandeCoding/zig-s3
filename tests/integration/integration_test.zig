const bucket_and_object_test = @import("bucket_and_objects_test.zig");
const uploader_test = @import("uploader_test.zig");

test "integration tests" {
    _ = .{
        bucket_and_object_test,
        uploader_test,
    };
}
