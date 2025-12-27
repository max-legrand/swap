// MIT License
// Copyright (c) 2025 Max Legrand
// See LICENSE for full terms.

const std = @import("std");
const objc = @import("zig_objc");
const darwin = @import("darwin.zig");
const application = @import("application.zig");
const lib = @import("lib.zig");
const utils = @import("utils.zig");

// Extern function mocks
export fn toggleWindow() void {}
export fn updateApps() void {}
export fn isWindowFocused() bool {
    return false;
}
export fn isShown() bool {
    return false;
}

test "getAllApps" {
    // Check if NSWorkspace class is available
    const NSWorkspace = objc.getClass("NSWorkspace");
    if (NSWorkspace == null) {
        std.debug.print("NSWorkspace class not available - skipping test\n", .{});
        return error.SkipZigTest;
    }

    const allocator = std.testing.allocator;
    const apps = try darwin.getAllApps(allocator);
    defer {
        for (apps) |app| {
            allocator.destroy(app);
        }
        allocator.free(apps);
    }

    try std.testing.expect(apps.len > 2);
    var found_finder = false;
    var calculator_found = false;
    for (apps) |app| {
        if (std.mem.eql(u8, std.mem.sliceTo(&app.name, 0), "Finder")) {
            found_finder = true;
        }
        if (std.mem.eql(u8, std.mem.sliceTo(&app.name, 0), "Calculator")) {
            calculator_found = true;
        }
        if (found_finder and calculator_found) break;
    }
    try std.testing.expect(found_finder);
    try std.testing.expect(calculator_found);
}

test "getRunningApplications" {
    const allocator = std.testing.allocator;
    const apps = try darwin.getRunningApplications(allocator);
    defer {
        for (apps) |app| {
            allocator.destroy(app);
        }
        allocator.free(apps);
    }

    try std.testing.expect(apps.len > 1);
    // Verify that Finder is in the list of running apps
    var found_finder = false;
    for (apps) |app| {
        if (std.mem.eql(u8, std.mem.sliceTo(&app.name, 0), "Finder")) {
            found_finder = true;
            break;
        }
    }
    try std.testing.expect(found_finder);
}

test "get_all_apps (simulates query path)" {
    // Check if NSWorkspace class is available
    const NSWorkspace = objc.getClass("NSWorkspace");
    if (NSWorkspace == null) {
        std.debug.print("NSWorkspace class not available - skipping test\n", .{});
        return error.SkipZigTest;
    }

    const allocator = std.testing.allocator;

    // This simulates what get_apps does when a query is provided
    const query_apps = try application.get_all_apps(allocator);
    defer {
        for (query_apps) |app| {
            allocator.destroy(app);
        }
        allocator.free(query_apps);
    }

    try std.testing.expect(query_apps.len > 2);
    var found_finder = false;
    var calculator_found = false;
    for (query_apps) |app| {
        if (std.mem.eql(u8, std.mem.sliceTo(&app.name, 0), "Finder")) {
            found_finder = true;
        }
        if (std.mem.eql(u8, std.mem.sliceTo(&app.name, 0), "Calculator")) {
            calculator_found = true;
        }
        if (found_finder and calculator_found) break;
    }
    try std.testing.expect(found_finder);
    try std.testing.expect(calculator_found);
}

test "get_all_apps (fuzzy query)" {
    const allocator = std.testing.allocator;
    utils.setAllocator(allocator);

    // This simulates what get_apps does when a query is provided
    const query = try allocator.dupeZ(u8, "ac");
    defer allocator.free(query);

    const query_apps = lib.get_apps(query);
    if (query_apps == null) return error.SkipZigTest;
    defer {
        if (query_apps) |app_return| {
            lib.deinitAppReturn(app_return);
        }
    }

    std.debug.print("query_apps: {d}\n", .{query_apps.?.length});
    for (0..@intCast(query_apps.?.length)) |idx| {
        const app = query_apps.?.apps[idx];
        const name: []const u8 = std.mem.sliceTo(app.name, 0);
        std.debug.print("app: pid={d} zindex={d} running={} {s}\n", .{ app.pid, app.zindex, app.is_running, name });
    }
}
