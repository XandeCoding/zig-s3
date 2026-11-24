const std = @import("std");
const s3 = @import("s3");

pub fn createS3ClientConfig() !s3.S3ClientConfig {
    const environ: std.process.Environ = .empty;
    const env_map = try environ.createMap(std.testing.allocator);
    const endpoint = env_map.get("S3_ENDPOINT") orelse "http://localhost:9000";

    return s3.S3ClientConfig{
        .access_key_id = "rustfsadmin",
        .secret_access_key = "rustfsadmin",
        .region = "us-west-1",
        .endpoint = endpoint,
    };
}
