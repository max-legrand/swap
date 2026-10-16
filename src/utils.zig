// MIT License
// Copyright (c) 2025 Max Legrand
// See LICENSE for full terms.

const std = @import("std");
const builtin = @import("builtin");

var debug_gpa: std.heap.DebugAllocator(.{}) = .init;

var current_allocator: std.mem.Allocator = if (builtin.mode == .debug)
    debug_gpa.allocator()
else
    std.heap.smp_allocator;

/// Forwards to `current_allocator`, so it can be swapped out in tests.
pub const allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &forward_vtable,
};

const forward_vtable: std.mem.Allocator.VTable = .{
    .alloc = fwdAlloc,
    .resize = fwdResize,
    .remap = fwdRemap,
    .free = fwdFree,
};

fn fwdAlloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    return current_allocator.vtable.alloc(current_allocator.ptr, len, alignment, ret_addr);
}
fn fwdResize(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    return current_allocator.vtable.resize(current_allocator.ptr, memory, alignment, new_len, ret_addr);
}
fn fwdRemap(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    return current_allocator.vtable.remap(current_allocator.ptr, memory, alignment, new_len, ret_addr);
}
fn fwdFree(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    current_allocator.vtable.free(current_allocator.ptr, memory, alignment, ret_addr);
}

pub fn setAllocator(new_allocator: std.mem.Allocator) void {
    // Only run this in test code.
    if (builtin.mode != .debug) return;
    current_allocator = new_allocator;
}

pub fn deinitAllocator() void {
    if (builtin.mode == .debug) {
        _ = debug_gpa.deinit();
    }
}

var threaded: std.Io.Threaded = undefined;
var threaded_state = std.atomic.Value(u8).init(0); // 0 = uninit, 1 = initializing, 2 = ready

fn initThreaded() void {
    // The global single-threaded Io has a failing allocator and an empty
    // environment, so it cannot spawn processes. Build our own, inheriting
    // the real process environment (needed for PATH lookup and the child env).
    threaded = .init(std.heap.smp_allocator, .{
        .environ = .{ .block = .{ .slice = std.mem.span(std.c.environ) } },
    });
}

/// Io implementation used for all file system / process / clock operations.
pub fn io() std.Io {
    if (threaded_state.load(.acquire) != 2) {
        if (threaded_state.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
            initThreaded();
            threaded_state.store(2, .release);
        } else {
            while (threaded_state.load(.acquire) != 2) std.atomic.spinLoopHint();
        }
    }
    return threaded.io();
}

/// Milliseconds since the unix epoch.
pub fn milliTimestamp() i64 {
    return std.Io.Timestamp.now(io(), .real).toMilliseconds();
}

pub fn getenv(name: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.sliceTo(value, 0);
}

/// Returns `$HOME/Library/Application Support/<app_name>`. Caller owns the result.
pub fn getAppDataDir(gpa: std.mem.Allocator, app_name: []const u8) ![]u8 {
    const home = getenv("HOME") orelse return error.AppDataDirUnavailable;
    return std.fmt.allocPrint(gpa, "{s}/Library/Application Support/{s}", .{ home, app_name });
}

/// Spawns a child process without waiting for it. Errors are ignored.
pub fn spawnDetached(argv: []const []const u8) void {
    _ = std.process.spawn(io(), .{ .argv = argv }) catch {};
}
