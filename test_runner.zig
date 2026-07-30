const std = @import("std");
const builtin = @import("builtin");

const ResultName = enum { passed, failed, leaked, };
const Result = struct {
    passed: usize,
    failed: usize,
    leaked: usize,
    protected: struct {
        mutex: std.Io.Mutex,
        io: std.Io,
    },

    pub fn init(io: std.Io) Result {
        return .{
            .passed = 0,
            .failed = 0,
            .leaked = 0,
            .protected = .{
                .mutex = .init,
                .io = io
            }
        };
    }

    pub fn increase(self: *Result, name: ResultName) anyerror!void {
        try self.protected.mutex.lock(self.protected.io);
        defer self.protected.mutex.unlock(self.protected.io);

        switch (name) {
            .passed => self.passed += 1,
            .failed => self.failed += 1,
            .leaked => self.leaked += 1,
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var result = Result.init(io);

    for (builtin.test_functions) |t| {
        std.testing.allocator_instance = .{};
        std.testing.io_instance = .init(gpa, .{});

        t.func() catch |err| {
            try result.increase(.failed);
            std.debug.print("\nFAIL: {s}: {s}\n", .{ t.name, @errorName(err) });
            continue;
        };

        try result.increase(.passed);
        std.debug.print("\nPASSED: {s}", .{ t.name });

        std.testing.io_instance.deinit();
        if (std.testing.allocator_instance.deinit() == .leak) {
            try result.increase(.leaked);
            std.debug.print("\nLEAKED: {s}", .{t.name});
        }
    }

    std.debug.print("\n\nSUMMARY:\n", .{});
    std.debug.print("\nPASSED: {d}", .{result.passed});
    std.debug.print("\nFAILED: {d}", .{result.failed});
    std.debug.print("\nLEAKED: {d}\n\n", .{result.leaked});

}
