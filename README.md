# 🚧 Under Construction

This project is currently under construction and subject to changes.

# S3 Client for Zig 🚀

[![Zig](https://img.shields.io/badge/Zig-0.16.0-orange.svg)](https://ziglang.org)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.2.0-green.svg)](https://github.com/algoflows/zig-s3)

A simple and efficient S3 client library for Zig, supporting AWS S3 and
S3-compatible services.

## 📑 Table of Contents

- [Features](#features)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [API Reference](#api-reference)
- [Error Handling](#error-handling)
- [Testing](#testing)
- [Development](#development)
- [Contributing](#contributing)
- [Community](#community)
- [License](#license)

## ✨ Features

- ✅ Basic S3 operations (create/delete buckets, upload/download objects)
- 🔐 AWS Signature V4 authentication
- 🔌 Support for custom endpoints (MinIO, LocalStack, etc.)
- 📝 Pagination support for listing objects
- 📦 Convenient upload helpers for different content types:
  - String content upload
  - JSON serialization and upload
  - File system file upload
- 🛡️ Memory-safe implementation using Zig's standard library
- 🧪 Comprehensive test suite:
  - Unit tests for all components
  - Integration tests with MinIO
  - Test assets for real-world scenarios

## 🔧 Prerequisites

- Zig 0.16.0 or newer
- For integration testing: Docker (optional, for running MinIO or RustFS)

## 📥 Installation

Add the package to your `build.zig.zon`:

```zig
.{
    .name = "your-project",
    .version = "0.2.0",
    .dependencies = .{
        .s3 = .{
            .url = "https://github.com/algoflows/zig-s3/archive/v0.3.0.tar.gz",
            // Don't forget to update hash after publishing
            .hash = "...",
        },
    },
}
```

Then in your `build.zig`:

```zig
const s3_dep = b.dependency("s3", .{
    .target = target,
    .optimize = optimize,
});
exe.addModule("s3", s3_dep.module("s3"));
```

## 🚀 Quick Start

```zig
const std = @import("std");
const s3 = @import("s3");

pub fn main(init: std.process.Init) !void {
    // Get allocator
    std.log.info("Initializing GeneralPurposeAllocator", .{});
    const allocator = init.gpa;

    // Initialize client
    var client = try s3.S3Client.init(allocator, .{
        .access_key_id = "your-key",
        .secret_access_key = "your-secret",
        .region = "us-east-1",
        // Optional: Use with MinIO or other S3-compatible services
        // .endpoint = "http://localhost:9000",
    });
    defer client.deinit();

    // Create bucket
    try client.createBucket("my-bucket");

    // Upload string content
    var uploader = client.uploader();
    try uploader.uploadString("my-bucket", "hello.txt", "Hello, S3!");
}
```

## 📚 API Reference

### S3Client

The main client interface for S3 operations.

```zig
const client = try s3.S3Client.init(allocator, .{
    .access_key_id = "your-key",
    .secret_access_key = "your-secret",
    .region = "us-east-1",
    .endpoint = "http://localhost:9000", // Optional, for S3-compatible services
});
```

### 🪣 Bucket Operations

- `createBucket(bucket_name: []const u8) !void`
- `deleteBucket(bucket_name: []const u8) !void`
- `listBuckets() ![]BucketInfo`

### 📦 Object Operations

- `putObject(bucket_name: []const u8, key: []const u8, data: []const u8) !void`
- `getObject(bucket_name: []const u8, key: []const u8) ![]const u8`
- `deleteObject(bucket_name: []const u8, key: []const u8) !void`
- `listObjects(bucket_name: []const u8, options: ListObjectsOptions) ![]ObjectInfo`

### 📤 ObjectUploader

A helper for uploading different types of content:

```zig
var uploader = client.uploader();

// Upload string content
try uploader.uploadString("my-bucket", "hello.txt", "Hello, World!");

// Upload JSON data
const data = .{ .name = "example", .value = 42 };
try uploader.uploadJson("my-bucket", "data.json", data);

// Upload file from filesystem
try uploader.uploadFile("my-bucket", "image.jpg", "path/to/local/image.jpg");
```

## ⚠️ Error Handling

The library uses Zig's error union type for robust error handling:

| Error Type                   | Description                         |
| ---------------------------- | ----------------------------------- |
| `S3Error.InvalidCredentials` | Invalid AWS credentials             |
| `S3Error.BucketNotFound`     | Requested bucket doesn't exist      |
| `S3Error.ObjectNotFound`     | Requested object doesn't exist      |
| `S3Error.ConnectionFailed`   | Network or connection issues        |
| `S3Error.InvalidResponse`    | Unexpected response from S3 service |

## 🛤️ Roadmap

[ ] Remove dotenv
[ ] Improve tests perfomance 
[ ] Streaming files
[ ] Use UTC at creating amz credentials

## 🧪 Testing

### Unit Tests

Run the unit test suite:

```bash
zig build test
```

### Integration Tests

Integration tests require a running MinIO instance:

1. Start MinIO:

```bash
docker run -d \
  --name rustfs-server \
  -p 9000:9000 \
  -p 9001:9001 \
  -e RUSTFS_ACCESS_KEY=admin \
  -e RUSTFS_SECRET_KEY=admin \
  rustfs/rustfs:latest
```

2. Run integration tests:

```bash
zig build integration-test
```

See `tests/integration/README.md` for detailed information about the integration
tests.

## 🛠️ Development

- Written in Zig 0.16.0
- Uses only standard library (no external dependencies)
- Memory safe with proper allocation and cleanup
- Follows Zig style guide and best practices

## 🤝 Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes
4. Add tests for your changes
5. Run the test suite
6. Create a pull request

## 👥 Community

- 📫 Report issues on
  [GitHub Issues](https://github.com/algoflows/zig-s3/issues)
- 💬 Join discussions in
  [GitHub Discussions](https://github.com/algoflows/zig-s3/discussions)
- 🌟 Star the repository if you find it helpful!

## 📄 License

MIT License - see [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- AWS S3 Documentation
- MinIO Documentation
- Zig Standard Library
