pub const createBucket = @import("create_bucket.zig").createBucket;
pub const bucket_ops = @import("operations.zig");


test "test buckets" {
    _ = .{
        @import("create_bucket.zig"),
        //@import("operations.zig"),
    };
}
