const mem = @import("std").mem;

const query_symbols: [1]u8 = .{ '/' };

pub fn mustEncodeQuerySymbol(char: u8) bool {
    for (query_symbols) |symbol| {
        if (char == symbol) {
            return false;
        }
    }

    return true;
}
