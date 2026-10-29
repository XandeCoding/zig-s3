const s3 = @import("s3.zig");

// Re-export all the types and functions from s3.zig
pub const S3Error = s3.S3Error;
pub const S3Config = s3.S3Config;
pub const S3Client = s3.S3Client;
