const std = @import("std");
const builtin = @import("builtin");
const Timestamp = std.Io.Timestamp;
const Writer = std.Io.Writer;
const mem = std.mem;

const ResultName = enum {
    passed,
    failed,
    leaked,
};
const Result = struct {
    passed: usize,
    failed: usize,
    leaked: usize,

    pub fn init() Result {
        return .{
            .passed = 0,
            .failed = 0,
            .leaked = 0,
        };
    }

    pub fn increase(self: *Result, name: ResultName) anyerror!void {
        switch (name) {
            .passed => self.passed += 1,
            .failed => self.failed += 1,
            .leaked => self.leaked += 1,
        }
    }
};

fn calculate_total_time(io: std.Io, writer: *Writer, start_date: Timestamp) !void {
    const end_date = Timestamp.now(io, .awake);
    const duration = Timestamp.durationTo(start_date, end_date);
    const time_mili = duration.toMilliseconds();
    _ = writer.consumeAll();

    if (time_mili > 60000) {
        return try writer.print("{d}min", .{@divTrunc(time_mili, 60000)});
    } else if (time_mili > 1000) {
        return try writer.print("{d}s", .{@divTrunc(time_mili, 1000)});
    } else if (time_mili >= 1) {
        try writer.print("{d}ms", .{time_mili});
    } else {
        try writer.print("{d}us", .{duration.toMicroseconds()});
    }

    try writer.flush();
}

fn get_module_name(writer: *Writer, fn_name: []const u8) !void {
    const end_index = mem.indexOf(u8, fn_name, ".") orelse fn_name.len;
    _ = writer.consumeAll();
    try writer.print("{s}", .{fn_name[0..end_index]});
    try writer.flush();
}

fn get_test_name(writer: *Writer, fn_name: []const u8) !void {
    var position: usize = fn_name.len - 1;

    while (position > 0) {
        if (fn_name[position] == '.') break;
        position -= 1;
    }

    _ = writer.consumeAll();
    try writer.print("{s}", .{fn_name[position + 1 .. fn_name.len]});
    try writer.flush();
}

pub fn main(init: std.process.Init) !void {
    if (builtin.test_functions.len == 0) {
        std.debug.print("\n{u} Module Skipped\n", .{'📦'});
        return;
    }

    var func_buffer: [100]u8 = undefined;
    var func_writer: Writer = .fixed(&func_buffer);

    try get_module_name(&func_writer, builtin.test_functions[0].name);

    const gpa = init.gpa;
    const io = init.io;

    var result = Result.init();
    var time_buffer: [20]u8 = undefined;
    var time_writer: Writer = .fixed(&time_buffer);

    std.debug.print("\n{u} Module: {s}\n ", .{ '📦', func_writer.buffered() });

    for (builtin.test_functions) |t| {
        std.testing.allocator_instance = .{};
        std.testing.io_instance = .init(gpa, .{});
        try get_test_name(&func_writer, t.name);
        const test_name = func_writer.buffered();

        const start = Timestamp.now(io, .awake);
        t.func() catch |err| {
            try result.increase(.failed);
            try calculate_total_time(io, &time_writer, start);
            std.debug.print(
                "\n{u} {s} ({s}) - Error: {s}",
                .{ '🔴', test_name, time_writer.buffered(), @errorName(err) },
            );

            continue;
        };

        try result.increase(.passed);
        try calculate_total_time(io, &time_writer, start);
        std.debug.print("\n{u} {s} ({s})", .{ '🟢', test_name, time_writer.buffered() });

        std.testing.io_instance.deinit();
        if (std.testing.allocator_instance.deinit() == .leak) {
            try result.increase(.leaked);
            std.debug.print("\n{u} {s}", .{ '🟡', test_name });
        }
    }

    std.debug.print("\n\n{u} SUMMARY:\n", .{'📑'});
    std.debug.print("\n{u} PASSED: {d}", .{ '🟢', result.passed });
    std.debug.print("\n{u} FAILED: {d}", .{ '🔴', result.failed });
    std.debug.print("\n{u} LEAKED: {d}\n", .{ '🟡', result.leaked });
}
