const createBucketOps = @import("create_bucket.zig");
pub const createBucket = createBucketOps.createBucket;
pub const createBucketOptions = createBucketOps.CreateBucketOptions;

const deleteBucketOps = @import("delete_bucket.zig");
pub const deleteBucket = deleteBucketOps.deleteBucket;
pub const deleteBucketOptions = deleteBucketOps.DeleteBucketOptions;

const listBucketsOps = @import("list_buckets.zig");
pub const listBuckets = listBucketsOps.listBuckets;
pub const listBucketsOptions = listBucketsOps.ListBucketsOptions;

// TODO: CHECAR SE FAZ SENTIDO ESTAR AQUI
pub const BucketInfo = listBucketsOps.BucketInfo;

test "test buckets" {
    _ = .{
        @import("create_bucket.zig"),
        @import("delete_bucket.zig"),
        @import("list_buckets.zig"),
    };
}
