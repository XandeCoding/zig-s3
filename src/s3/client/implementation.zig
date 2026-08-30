/// S3 client implementation.
/// Handles authentication, request signing, and HTTP communication with S3 services.
const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;
const Uri = std.Uri;
const fmt = std.fmt;
const time = std.time;
const tls = std.crypto.tls;
const HttpClient = http.Client;
const Writer = std.Io.Writer;
const FetchOptions = http.Client.FetchOptions;

const signer = @import("auth/signer.zig");
const time_utils = @import("auth/time.zig");
const errors = @import("../common/errors.zig");
const S3Error = errors.S3Error;

/// Configuration for the S3 client.
/// This includes AWS credentials and regional settings.
pub const S3Config = struct {
    /// AWS access key ID or compatible credential
    access_key_id: []const u8,
    /// AWS secret access key or compatible credential
    secret_access_key: []const u8,
    /// AWS region (e.g., "us-east-1")
    region: []const u8,
    /// custom endpoint for S3-compatible services (e.g., MinIO, LocalStack) when not passed points to AWS S3 solution
    endpoint: []const u8,
};

pub const RequestOptions = struct {
    params: FetchOptions,
    content_hash: []const u8,
    amz_date: []const u8,
    auth_header: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: S3Config,
        method: http.Method,
        uri: Uri,
        writer: ?*std.Io.Writer,
        payload: ?[]const u8,
    ) !*RequestOptions {
        const self = try allocator.create(RequestOptions);

        const uri_host = try normalizeURIHost(uri.host);
        const uri_path = try normalizeURIPath(uri.path);
        const uri_query = normalizeURIQuery(uri.query);

        // Calculate content hash
        const content_hash = try signer.hashPayload(allocator, payload);

        // Get current timestamp and format it properly
        const now = std.Io.Timestamp.now(io, std.Io.Clock.real);
        const timestamp = now.toSeconds();

        // Format current time as x-amz-date header
        const amz_date = try time_utils.formatAmzDateTime(allocator, timestamp);

        const credentials = signer.Credentials{
            .access_key = config.access_key_id,
            .secret_key = config.secret_access_key,
            .region = config.region,
            .service = "s3",
        };

        var headers = try signer.createSignHeaders(
            allocator,
            uri_host,
            content_hash,
            amz_date,
        );
        defer headers.deinit();

        const params = signer.SigningParams{
            .method = @tagName(method),
            .path = uri_path,
            .headers = headers,
            .body = payload,
            .query = uri_query,
            .timestamp = timestamp, // Use same timestamp for signing
        };

        // Generate authorization header
        const auth_header = try signer.signRequest(allocator, credentials, params);

        const options = FetchOptions{
            .location = .{
                .uri = uri,
            },
            .method = method,
            .response_writer = writer,
            .payload = normalizePayload(method, payload),
            .headers = .{
                .host = .{ .override = uri_host },
                .content_type = .{ .override = "application/xml" },
            },
            .extra_headers = &[_]http.Header{
                .{ .name = "Accept", .value = "application/xml" },
                .{ .name = "x-amz-content-sha256", .value = content_hash },
                .{ .name = "x-amz-date", .value = amz_date },
                .{ .name = "Authorization", .value = auth_header },
            },
        };

        self.* = .{
            .params = options,
            .content_hash = content_hash,
            .amz_date = amz_date,
            .auth_header = auth_header,
        };

        return self;
    }

    pub fn deinit(self: *RequestOptions, allocator: std.mem.Allocator) void {
        allocator.free(self.content_hash);
        allocator.free(self.amz_date);
        allocator.free(self.auth_header);
        allocator.destroy(self);
    }

    fn normalizeURIHost(uri_host: ?Uri.Component) ![]const u8 {
        switch (uri_host orelse return S3Error.InvalidResponse) {
            .raw => |h| return h,
            .percent_encoded => |h| return h,
        }
    }

    fn normalizeURIPath(uri_path: ?Uri.Component) ![]const u8 {
        const path = switch (uri_path orelse return S3Error.InvalidResponse) {
            .raw => |p| if (p.len == 0) "/" else p,
            .percent_encoded => |p| if (p.len == 0) "/" else p,
        };

        return path;
    }

    fn normalizeURIQuery(uri_query: ?Uri.Component) []const u8 {
        const query = switch (uri_query orelse Uri.Component.empty) {
            .raw => |p| if (p.len == 0) "" else p,
            .percent_encoded => |p| if (p.len == 0) "" else p,
        };

        return query;
    }

    fn normalizePayload(method: std.http.Method, payload: ?[]const u8) ?[]const u8 {
        if (method.requestHasBody()) {
            return payload orelse "";
        }

        return null;
    }
};

/// Main S3 client implementation.
/// Handles low-level HTTP communication and request signing.
pub const S3Client = struct {
    /// Memory allocator used for dynamic allocations
    allocator: Allocator,
    /// Client configuration
    config: S3Config,
    /// HTTP client for making requests
    http_client: HttpClient,

    /// Initialize a new S3 client with the given configuration.
    /// Caller owns the returned client and must call deinit when done.
    /// Memory is allocated for the client instance.
    pub fn init(allocator: Allocator, io: std.Io, config: S3Config) !*S3Client {
        const self = try allocator.create(S3Client);

        // Initialize HTTP client
        var client = HttpClient{
            .io = io,
            .allocator = allocator,
        };

        // Load system root certificates for HTTPS
        if (!HttpClient.disable_tls) {
            const timestamp = std.Io.Timestamp.now(io, std.Io.Clock.real);
            try client.ca_bundle.rescan(allocator, io, timestamp);
        }

        errdefer client.deinit();

        self.* = .{
            .allocator = allocator,
            .config = config,
            .http_client = client,
        };

        return self;
    }

    /// Clean up resources used by the client.
    /// This includes the HTTP client and the client instance itself.
    pub fn deinit(self: *S3Client) void {
        self.http_client.deinit();
        self.allocator.destroy(self);
    }

    /// Generic HTTP request handler used by all S3 operations.
    /// Handles request setup, authentication, and execution.
    ///
    /// Parameters:
    ///   - method: HTTP method to use (GET, PUT, DELETE, etc.)
    ///   - uri: Fully qualified URI for the request
    ///   - body: Optional request body data
    ///
    /// Returns: An HTTP request that must be deinit'd by the caller
    pub fn request(
        self: *S3Client,
        method: http.Method,
        uri: Uri,
        writer: ?*std.Io.Writer,
        payload: ?[]const u8,
    ) !HttpClient.FetchResult {
        const options = try RequestOptions.init(
            self.allocator,
            self.http_client.io,
            self.config,
            method,
            uri,
            writer,
            payload,
        );
        defer options.deinit(self.allocator);

        return try self.http_client.fetch(options.params);
    }
};

test "S3Client request signing" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const config = S3Config{
        .access_key_id = "AKIAIOSFODNN7EXAMPLE",
        .secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        .region = "us-east-1",
        .endpoint = "https://s3.us-east-1.amazonaws.com",
    };

    var client = try S3Client.init(allocator, io, config);
    defer client.deinit();

    const uri = try Uri.parse("https://examplebucket.s3.amazonaws.com/test.txt");
    const req = try client.request(.GET, uri, null, null);

    try std.testing.expectEqual(req.status, .forbidden);
}

test "S3Client initialization" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const config = S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
        .endpoint = "https://s3.us-east-1.amazonaws.com",
    };

    var client = try S3Client.init(allocator, io, config);
    defer client.deinit();

    try std.testing.expectEqualStrings("test-key", client.config.access_key_id);
    try std.testing.expectEqualStrings("us-east-1", client.config.region);
    try std.testing.expectEqualStrings("https://s3.us-east-1.amazonaws.com", client.config.endpoint);
}

test "S3Client custom endpoint" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const config = S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
        .endpoint = "http://localhost:9000",
    };

    var client = try S3Client.init(allocator, io, config);
    defer client.deinit();

    try std.testing.expectEqualStrings("http://localhost:9000", client.config.endpoint);
}

test "S3Client request with body" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const config = S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
        .endpoint = "https://s3.us-east-1.amazonaws.com",
    };

    var client = try S3Client.init(allocator, io, config);
    defer client.deinit();

    const uri = try Uri.parse("https://example.s3.amazonaws.com/test.txt");
    const body = "Hello, S3!";
    const req = try client.request(.PUT, uri, null, body);
    try std.testing.expectEqual(req.status, .forbidden);
}

test "S3Client error handling" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const config = S3Config{
        .access_key_id = "test-key",
        .secret_access_key = "test-secret",
        .region = "us-east-1",
        .endpoint = "https://s3.us-east-1.amazonaws.com",
    };

    var client = try S3Client.init(allocator, io, config);
    defer client.deinit();

    const uri = try Uri.parse("https://example.s3.amazonaws.com/test.txt");
    const req = try client.request(.GET, uri, null, null);

    const invalid_cred_error_union: anyerror!void = S3Error.InvalidCredentials;
    const bucket_not_found_error_union: anyerror!void = S3Error.BucketNotFound;
    // Test error mapping
    switch (req.status) {
        .unauthorized => try std.testing.expectError(S3Error.InvalidCredentials, invalid_cred_error_union),
        .forbidden => try std.testing.expectError(S3Error.InvalidCredentials, invalid_cred_error_union),
        .not_found => try std.testing.expectError(S3Error.BucketNotFound, bucket_not_found_error_union),
        else => {},
    }
}
