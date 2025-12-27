// MIT License
// Copyright (c) 2025 Max Legrand
// See LICENSE for full terms.

const std = @import("std");
const builtin = @import("builtin");

var gpa = if (builtin.mode == .Debug)
    std.heap.GeneralPurposeAllocator(.{}).init
else
    undefined;

pub const allocator = if (builtin.mode == .Debug)
    gpa.allocator()
else
    std.heap.smp_allocator;

pub fn setAllocator(new_allocator: std.mem.Allocator) void {
    // Only run this in test code.
    if (builtin.mode != .Debug) return;
    allocator = new_allocator;
}

pub fn deinitAllocator() void {
    if (builtin.mode == .Debug) {
        _ = gpa.deinit();
    }
}
