// MIT License
// Copyright (c) 2025 Max Legrand
// See LICENSE for full terms.

const std = @import("std");
const swap = @import("swap");
const c = @cImport(@cInclude("time.h"));

// Extern function mocks
export fn toggleWindow() void {}
export fn updateApps() void {}
export fn showWindow() void {}
export fn hideWindow() void {}
export fn isWindowFocused() bool {
    return false;
}
export fn isShown() bool {
    return false;
}

pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const stderr = std.fs.File.stderr();
    var buffer: [1024]u8 = undefined;
    var writer = stderr.writer(&buffer);

    var now: c.time_t = c.time(null);
    var local: c.struct_tm = undefined;
    _ = c.localtime_r(&now, &local);

    _ = writer.interface.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} ", .{
        @as(u16, @intCast(local.tm_year + 1900)),
        @as(u8, @intCast(local.tm_mon + 1)),
        @as(u8, @intCast(local.tm_mday)),
        @as(u8, @intCast(local.tm_hour)),
        @as(u8, @intCast(local.tm_min)),
        @as(u8, @intCast(local.tm_sec)),
    }) catch return;

    _ = writer.interface.print("[{s}] ", .{
        @tagName(message_level),
    }) catch return;

    if (!std.mem.eql(u8, @tagName(scope), "default")) {
        _ = writer.interface.print("[{s}] ", .{
            @tagName(scope),
        }) catch return;
    }

    _ = writer.interface.print(format, args) catch return;
    _ = writer.interface.print("\n", .{}) catch return;
    writer.interface.flush() catch return;
}

pub const std_options: std.Options = .{
    .logFn = logFn,
};

pub fn main() !void {
    // Log the start of the program
    std.log.info("Enumerating windows", .{});
}
