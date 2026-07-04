const std = @import("std");
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

// TODO: CHECK BUFFER SIZE
pub fn createMemoryWriter(allocator: Allocator) !Writer.Allocating {
    return try Writer.Allocating.initCapacity(allocator, 4096);
}
