/// Possible errors that can occur during S3 operations.
/// These errors cover both AWS-specific issues and general HTTP/network problems.
pub const S3Error = error{
    /// Invalid AWS credentials or signature
    InvalidCredentials,
    /// Network or connection failure
    ConnectionFailed,
    /// Requested bucket does not exist
    BucketNotFound,
    /// Requested object does not exist
    ObjectNotFound,
    /// Unexpected response from S3 service
    InvalidResponse,
    /// Error during request signing
    SignatureError,
    /// Memory allocation failure
    OutOfMemory,
    /// Invalid object key
    InvalidObjectKey,
    /// Bucket already exists
    BucketAlreadyExists,
    /// Invalid bucket name
    InvalidBucketName,
    /// Access denied
    AccessDenied,
    /// Service unavailable
    ServiceUnavailable,
    /// Server not implemented this function
    ServerNotImplemented,
};
