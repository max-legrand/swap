// MIT License
// Copyright (c) 2025 Max Legrand
// See LICENSE for full terms.

const std = @import("std");
const objc = @import("zig_objc");
const types = @import("types.zig");
const c = types.c;
const application = @import("application.zig");
const App = application.App;
const APP_NAME_LEN = application.APP_NAME_LEN;
const APP_PATH_LEN = application.APP_PATH_LEN;

pub const kProcessDictionaryIncludeAllInformationMask: c.UInt32 = 0xFFFFFFFF;
const clearTags: c_long = 0x4000000000;

pub fn isAppHidden(pid: c_int) bool {
    const NSRunningApplication = objc.getClass("NSRunningApplication") orelse return false;
    const app = NSRunningApplication.msgSend(objc.Object, "runningApplicationWithProcessIdentifier:", .{pid});
    if (app.value == 0) return false;
    return app.msgSend(bool, "isHidden", .{});
}

pub fn isRegularApp(pid: c_int) bool {
    const NSRunningApplication = objc.getClass("NSRunningApplication") orelse return false;
    const app = NSRunningApplication.msgSend(objc.Object, "runningApplicationWithProcessIdentifier:", .{pid});
    if (app.value == 0) return false;
    // activationPolicy: 0 = regular, 1 = accessory, 2 = prohibited (background agent)
    const policy = app.msgSend(i64, "activationPolicy", .{});
    return policy == 0;
}

pub fn isWindowMinimized(pid: c_int, window_name: []const u8) bool {
    const app_ref = c.AXUIElementCreateApplication(pid);
    if (app_ref == null) return false;
    defer c.CFRelease(app_ref);

    var windows_ref: c.CFTypeRef = null;
    const windows_attr = c.CFStringCreateWithCString(c.kCFAllocatorDefault, "AXWindows", c.kCFStringEncodingUTF8);
    defer c.CFRelease(windows_attr);

    if (c.AXUIElementCopyAttributeValue(app_ref, windows_attr, &windows_ref) != 0) return false;
    if (windows_ref == null) return false;
    defer c.CFRelease(windows_ref);

    const windows: c.CFArrayRef = @ptrCast(windows_ref);
    const count = c.CFArrayGetCount(windows);

    const title_attr = c.CFStringCreateWithCString(c.kCFAllocatorDefault, "AXTitle", c.kCFStringEncodingUTF8);
    defer c.CFRelease(title_attr);
    const minimized_attr = c.CFStringCreateWithCString(c.kCFAllocatorDefault, "AXMinimized", c.kCFStringEncodingUTF8);
    defer c.CFRelease(minimized_attr);

    for (0..@intCast(count)) |i| {
        const win: c.AXUIElementRef = @ptrCast(c.CFArrayGetValueAtIndex(windows, @intCast(i)));

        var title_ref: c.CFTypeRef = null;
        if (c.AXUIElementCopyAttributeValue(win, title_attr, &title_ref) != 0) continue;
        if (title_ref == null) continue;
        defer c.CFRelease(title_ref);

        var title_buf: [256]u8 = undefined;
        if (c.CFStringGetCString(@ptrCast(title_ref), &title_buf, 256, c.kCFStringEncodingUTF8) == 0) continue;
        const title = std.mem.sliceTo(&title_buf, 0);

        var minimized_ref: c.CFTypeRef = null;
        if (c.AXUIElementCopyAttributeValue(win, minimized_attr, &minimized_ref) != 0) continue;
        if (minimized_ref == null) continue;
        defer c.CFRelease(minimized_ref);

        const is_min = c.CFBooleanGetValue(@ptrCast(minimized_ref)) != 0;

        // Match if titles are equal OR one starts with the other (CG vs AX may differ)
        const matches = std.mem.eql(u8, title, window_name) or
            (window_name.len > 0 and std.mem.startsWith(u8, title, window_name)) or
            (title.len > 0 and std.mem.startsWith(u8, window_name, title));
        if (matches) {
            return is_min;
        }
    }

    return false;
}

pub fn getHiddenAppWindows(allocator: std.mem.Allocator) ![]WindowInfo {
    const NSWorkspace = objc.getClass("NSWorkspace") orelse return &[_]WindowInfo{};
    const sharedWorkspace = NSWorkspace.msgSend(objc.Object, "sharedWorkspace", .{});
    const runningApps = sharedWorkspace.msgSend(objc.Object, "runningApplications", .{});
    const count = runningApps.msgSend(usize, "count", .{});

    var hidden_pids = std.ArrayList(c_int).empty;
    defer hidden_pids.deinit(allocator);

    for (0..count) |i| {
        const app = runningApps.msgSend(objc.Object, "objectAtIndex:", .{i});
        const is_hidden = app.msgSend(bool, "isHidden", .{});
        if (is_hidden) {
            const pid = app.msgSend(c_int, "processIdentifier", .{});
            try hidden_pids.append(allocator, pid);
        }
    }

    var result = std.ArrayList(WindowInfo).empty;
    defer result.deinit(allocator);

    // For each hidden app, we need to report it
    for (hidden_pids.items) |pid| {
        const NSRunningApplication = objc.getClass("NSRunningApplication") orelse continue;
        const app = NSRunningApplication.msgSend(objc.Object, "runningApplicationWithProcessIdentifier:", .{pid});
        if (app.value == 0) continue;

        const name_obj = app.msgSend(objc.Object, "localizedName", .{});
        const name_utf8 = name_obj.msgSend([*c]const u8, "UTF8String", .{});

        var info = WindowInfo{
            .window_id = 0,
            .name = [_]u8{0} ** 256,
            .owner = [_]u8{0} ** 256,
            .pid = pid,
            .layer = 0,
            .is_on_screen = false,
            .is_hidden = true,
        };

        if (name_utf8 != null) {
            const name_slice = std.mem.span(name_utf8);
            const end = @min(255, name_slice.len);
            @memcpy(info.owner[0..end], name_slice[0..end]);
        }

        try result.append(allocator, info);
    }

    return result.toOwnedSlice(allocator);
}

pub fn getCommandTabOrder(allocator: std.mem.Allocator) ![]i64 {
    const apps_opaque = types._LSCopyApplicationArrayInFrontToBackOrder(-1) orelse return try allocator.alloc(i64, 0);
    const apps: c.CFArrayRef = @ptrCast(apps_opaque);
    defer c.CFRelease(apps);

    const count = c.CFArrayGetCount(apps);
    var pids = std.ArrayList(i64).empty;
    defer pids.deinit(allocator);

    for (0..@intCast(count)) |i| {
        const asn = c.CFArrayGetValueAtIndex(apps, @intCast(i));
        if (asn == null) continue;

        // Extract PSN from ASN
        var psn = types.ProcessSerialNumber{ .high = 0, .low = 0 };
        types._LSASNExtractHighAndLowParts(asn, &psn.high, &psn.low);

        // Get process info dictionary
        const processInfo = types.ProcessInformationCopyDictionary(&psn, kProcessDictionaryIncludeAllInformationMask);
        if (processInfo == null) continue;
        defer c.CFRelease(processInfo);

        // Extract PID from dictionary
        const pid_key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, "pid", c.kCFStringEncodingUTF8);
        defer c.CFRelease(pid_key);

        const pid_value = c.CFDictionaryGetValue(processInfo, pid_key);
        if (pid_value != null) {
            var pid: c_long = 0;
            if (c.CFNumberGetValue(@ptrCast(pid_value), c.kCFNumberLongType, &pid) != 0) {
                try pids.append(allocator, @intCast(pid));
            }
        }
    }

    return pids.toOwnedSlice(allocator);
}

pub fn getRunningApplications(allocator: std.mem.Allocator) ![]*App {
    const NSWorkspace = objc.getClass("NSWorkspace").?;
    const sharedWorkspace = NSWorkspace.msgSend(objc.Object, "sharedWorkspace", .{});

    const runningApps = sharedWorkspace.msgSend(objc.Object, "runningApplications", .{});
    const count = runningApps.msgSend(usize, "count", .{});

    // Get the actual frontmost application's PID
    const frontmostApp = sharedWorkspace.msgSend(objc.Object, "frontmostApplication", .{});
    const frontmostPid = frontmostApp.msgSend(i64, "processIdentifier", .{});

    // Get command-tab ordering
    const cmdTabPids = try getCommandTabOrder(allocator);
    defer allocator.free(cmdTabPids);

    var pidToIndex = std.AutoHashMap(i64, i32).init(allocator);
    defer pidToIndex.deinit();
    for (cmdTabPids, 0..) |pid, idx| {
        try pidToIndex.put(pid, @intCast(idx));
    }

    var i: usize = 0;

    var apps = std.ArrayList(*App).empty;
    defer apps.deinit(allocator);

    while (i < count) : (i += 1) {
        const app = runningApps.msgSend(objc.Object, "objectAtIndex:", .{i});

        const policy = app.msgSend(i64, "activationPolicy", .{});
        if (policy != 0) continue;

        const pid = app.msgSend(i64, "processIdentifier", .{});

        const name = app.msgSend(objc.Object, "localizedName", .{});
        const name_utf8 = name.msgSend([*c]const u8, "UTF8String", .{});
        if (name_utf8 == null) continue;

        const bundleUrl = app.msgSend(objc.Object, "bundleURL", .{});
        if (bundleUrl.value == 0) continue;

        const path_obj = bundleUrl.msgSend(objc.Object, "path", .{});
        const path_utf8 = path_obj.msgSend([*c]const u8, "UTF8String", .{});
        if (path_utf8 == null) continue;

        const name_slice = std.mem.span(name_utf8);
        const path_slice = std.mem.span(path_utf8);

        const a = try allocator.create(App);

        const name_end = @min(APP_NAME_LEN - 1, name_slice.len);
        @memcpy(a.name[0..name_end], name_slice[0..name_end]);
        a.name[name_end] = 0;

        const path_end = @min(APP_PATH_LEN - 1, path_slice.len);
        @memcpy(a.path[0..path_end], path_slice[0..path_end]);
        a.path[path_end] = 0;

        a.pid = pid;
        // Use command-tab ordering, fall back to current index if not found
        a.zindex = pidToIndex.get(pid) orelse @intCast(i);
        // Penalize Finder only if it's not actually the frontmost app
        if (std.mem.eql(u8, name_slice, "Finder") and pid != frontmostPid) {
            a.zindex += 1000;
        }
        a.is_running = true;
        try apps.append(allocator, a);
    }

    // Sort by zindex (MRU order)
    const sortFn = struct {
        fn cmp(_: void, lhs: *App, rhs: *App) bool {
            return lhs.zindex < rhs.zindex;
        }
    }.cmp;
    std.mem.sort(*App, apps.items, {}, sortFn);

    return apps.toOwnedSlice(allocator);
}

fn scanAppsInDirectory(allocator: std.mem.Allocator, dir_path: []const u8, apps_map: *std.StringHashMap(void), all_apps: *std.ArrayList(*App)) !void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.endsWith(u8, entry.name, ".app")) continue;

        const app_name = entry.name[0 .. entry.name.len - 4];
        if (app_name.len == 0) continue;

        if (apps_map.contains(app_name)) continue;

        const owned_name = try allocator.dupe(u8, app_name);
        try apps_map.put(owned_name, {});

        const a = try allocator.create(App);

        const end = @min(APP_NAME_LEN - 1, app_name.len);
        @memcpy(a.name[0..end], app_name[0..end]);
        a.name[end] = 0;

        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
        defer allocator.free(full_path);
        const path_end = @min(APP_PATH_LEN - 1, full_path.len);
        @memcpy(a.path[0..path_end], full_path[0..path_end]);
        a.path[path_end] = 0;

        a.pid = -1;
        a.zindex = std.math.maxInt(i32);
        a.is_running = false;

        try all_apps.append(allocator, a);
    }
}

pub fn getAllApps(allocator: std.mem.Allocator) ![]*App {
    const runningApps = try getRunningApplications(allocator);
    defer {
        for (runningApps) |app| {
            allocator.destroy(app);
        }
        allocator.free(runningApps);
    }

    var apps_map = std.StringHashMap(void).init(allocator);
    defer {
        var iter = apps_map.keyIterator();
        while (iter.next()) |key| {
            allocator.free(key.*);
        }
        apps_map.deinit();
    }

    var allApps = std.ArrayList(*App).empty;
    defer allApps.deinit(allocator);

    const app_dirs = [_][]const u8{
        "/Applications",
        "/System/Applications",
        "/System/Applications/Utilities",
    };

    for (app_dirs) |dir_path| {
        try scanAppsInDirectory(allocator, dir_path, &apps_map, &allApps);
    }

    if (std.posix.getenv("HOME")) |home| {
        const user_apps = try std.fmt.allocPrint(allocator, "{s}/Applications", .{home});
        defer allocator.free(user_apps);
        try scanAppsInDirectory(allocator, user_apps, &apps_map, &allApps);
    }

    for (runningApps) |app| {
        const appNameSlice = std.mem.sliceTo(&app.name, 0);

        var found = false;
        for (allApps.items) |existing| {
            const existingSlice = std.mem.sliceTo(&existing.name, 0);
            if (std.mem.eql(u8, existingSlice, appNameSlice)) {
                existing.is_running = true;
                existing.pid = app.pid;
                @memcpy(&existing.path, &app.path);
                found = true;
                break;
            }
        }

        if (!found) {
            const newApp = try allocator.create(App);
            newApp.* = app.*;
            newApp.is_running = true;
            try allApps.append(allocator, newApp);
        }
    }

    return allApps.toOwnedSlice(allocator);
}

fn createCFString(key: [*:0]const u8) c.CFStringRef {
    return c.CFStringCreateWithCString(c.kCFAllocatorDefault, key, c.kCFStringEncodingUTF8);
}

pub const WindowInfo = struct {
    window_id: c.CGWindowID,
    name: [256]u8,
    owner: [256]u8,
    pid: c_int,
    layer: c_int,
    is_on_screen: bool,
    is_hidden: bool,
};

var g_window_info_cache: ?c.CFArrayRef = null;

fn initWindowInfoCache() void {
    if (g_window_info_cache) |cache| {
        c.CFRelease(cache);
    }
    g_window_info_cache = c.CGWindowListCopyWindowInfo(c.kCGWindowListOptionAll, c.kCGNullWindowID);
}

fn getWindowInfo(window_id: c.CGWindowID) WindowInfo {
    var result: WindowInfo = .{
        .window_id = window_id,
        .name = [_]u8{0} ** 256,
        .owner = [_]u8{0} ** 256,
        .pid = 0,
        .layer = 0,
        .is_on_screen = true,
        .is_hidden = false,
    };

    const window_info_list = g_window_info_cache orelse return result;
    const count = c.CFArrayGetCount(window_info_list);

    const number_key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, "kCGWindowNumber", c.kCFStringEncodingUTF8);
    defer c.CFRelease(number_key);

    for (0..@intCast(count)) |i| {
        const window_info: c.CFDictionaryRef = @ptrCast(c.CFArrayGetValueAtIndex(window_info_list, @intCast(i)));

        const number_value = c.CFDictionaryGetValue(window_info, number_key);
        if (number_value == null) continue;

        var wid: c.CGWindowID = 0;
        if (c.CFNumberGetValue(@ptrCast(number_value), c.kCFNumberIntType, &wid) == 0) continue;
        if (wid != window_id) continue;

        // Found matching window - get name
        const name_key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, "kCGWindowName", c.kCFStringEncodingUTF8);
        defer c.CFRelease(name_key);
        const name_value = c.CFDictionaryGetValue(window_info, name_key);
        if (name_value != null) {
            _ = c.CFStringGetCString(@ptrCast(name_value), &result.name, 256, c.kCFStringEncodingUTF8);
        }

        // Get owner name (app name)
        const owner_key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, "kCGWindowOwnerName", c.kCFStringEncodingUTF8);
        defer c.CFRelease(owner_key);
        const owner_value = c.CFDictionaryGetValue(window_info, owner_key);
        if (owner_value != null) {
            _ = c.CFStringGetCString(@ptrCast(owner_value), &result.owner, 256, c.kCFStringEncodingUTF8);
        }

        // Get owner PID
        const pid_key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, "kCGWindowOwnerPID", c.kCFStringEncodingUTF8);
        defer c.CFRelease(pid_key);
        const pid_value = c.CFDictionaryGetValue(window_info, pid_key);
        if (pid_value != null) {
            _ = c.CFNumberGetValue(@ptrCast(pid_value), c.kCFNumberIntType, &result.pid);
        }

        // Get window layer
        const layer_key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, "kCGWindowLayer", c.kCFStringEncodingUTF8);
        defer c.CFRelease(layer_key);
        const layer_value = c.CFDictionaryGetValue(window_info, layer_key);
        if (layer_value != null) {
            _ = c.CFNumberGetValue(@ptrCast(layer_value), c.kCFNumberIntType, &result.layer);
        }

        // Check if window is on screen (not minimized)
        const on_screen_key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, "kCGWindowIsOnscreen", c.kCFStringEncodingUTF8);
        defer c.CFRelease(on_screen_key);
        const on_screen_value = c.CFDictionaryGetValue(window_info, on_screen_key);
        if (on_screen_value != null) {
            result.is_on_screen = c.CFBooleanGetValue(@ptrCast(on_screen_value)) != 0;
        }

        break;
    }

    return result;
}

pub fn getWindows(allocator: std.mem.Allocator, pid_list: []i64) void {
    // Check screen recording permission
    const has_permission = c.CGPreflightScreenCaptureAccess();

    if (!has_permission) {
        _ = c.CGRequestScreenCaptureAccess();
    }

    initWindowInfoCache();
    defer {
        if (g_window_info_cache) |cache| {
            c.CFRelease(cache);
            g_window_info_cache = null;
        }
    }

    const conn = types._CGSDefaultConnection();
    const info_opaque = types.CGSCopyManagedDisplaySpaces(conn) orelse {
        return;
    };
    const info: c.CFArrayRef = @ptrCast(info_opaque);
    defer c.CFRelease(info);

    const spaces_key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, "Spaces", c.kCFStringEncodingUTF8);
    defer c.CFRelease(spaces_key);
    const id64_key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, "id64", c.kCFStringEncodingUTF8);
    defer c.CFRelease(id64_key);

    var set_tags: c_long = 0;
    var total_windows: usize = 0;

    // Track windows seen across all spaces - windows NOT in this set are minimized
    var seen_windows = std.AutoHashMap(c.CGWindowID, void).init(allocator);
    defer seen_windows.deinit();

    const display_count = c.CFArrayGetCount(info);
    for (0..@intCast(display_count)) |display_idx| {
        const display_dict: c.CFDictionaryRef = @ptrCast(c.CFArrayGetValueAtIndex(info, @intCast(display_idx)));

        const spaces_opaque = c.CFDictionaryGetValue(display_dict, spaces_key);
        if (spaces_opaque == null) continue;
        const spaces: c.CFArrayRef = @ptrCast(spaces_opaque);

        const space_count = c.CFArrayGetCount(spaces);
        for (0..@intCast(space_count)) |space_idx| {
            const space_dict: c.CFDictionaryRef = @ptrCast(c.CFArrayGetValueAtIndex(spaces, @intCast(space_idx)));
            const space_id_value = c.CFDictionaryGetValue(space_dict, id64_key);
            if (space_id_value == null) continue;

            var space_id: c_longlong = 0;
            if (c.CFNumberGetValue(@ptrCast(space_id_value), c.kCFNumberLongLongType, &space_id) == 0) continue;

            // Create array with just this space ID
            const space_id_cf = c.CFNumberCreate(c.kCFAllocatorDefault, c.kCFNumberLongLongType, &space_id);
            var space_ids = [_]?*const anyopaque{space_id_cf};
            const space_id_array = c.CFArrayCreate(c.kCFAllocatorDefault, @ptrCast(&space_ids), 1, &c.kCFTypeArrayCallBacks);

            // Get windows for this space
            const windows_opaque = types.CGSCopyWindowsWithOptionsAndTags(conn, 0, @ptrCast(@constCast(space_id_array)), 2, &set_tags, &clearTags);
            c.CFRelease(space_id_array);
            c.CFRelease(space_id_cf);

            if (windows_opaque == null) continue;
            const windows: c.CFArrayRef = @ptrCast(windows_opaque);
            defer c.CFRelease(windows);

            const window_count = c.CFArrayGetCount(windows);
            if (window_count == 0) continue;

            for (0..@intCast(window_count)) |i| {
                const window_id_value = c.CFArrayGetValueAtIndex(windows, @intCast(i));
                var window_id: c.CGWindowID = 0;
                if (c.CFNumberGetValue(@ptrCast(window_id_value), c.kCFNumberIntType, &window_id) != 0) {
                    seen_windows.put(window_id, {}) catch {};
                    const window_info = getWindowInfo(window_id);
                    if (std.mem.indexOfScalar(i64, pid_list, window_info.pid) != null) {
                        total_windows += 1;
                    }
                }
            }
        }
    }

    // Minimized windows: in CGWindowListCopyWindowInfo but NOT in any space
    var minimized_count: usize = 0;

    if (g_window_info_cache) |cache| {
        const cache_count = c.CFArrayGetCount(cache);
        const number_key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, "kCGWindowNumber", c.kCFStringEncodingUTF8);
        defer c.CFRelease(number_key);
        const layer_key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, "kCGWindowLayer", c.kCFStringEncodingUTF8);
        defer c.CFRelease(layer_key);

        for (0..@intCast(cache_count)) |i| {
            const win_dict: c.CFDictionaryRef = @ptrCast(c.CFArrayGetValueAtIndex(cache, @intCast(i)));

            // Check layer - only care about layer 0 (normal windows)
            const layer_value = c.CFDictionaryGetValue(win_dict, layer_key);
            if (layer_value == null) continue;
            var layer: c_int = 0;
            _ = c.CFNumberGetValue(@ptrCast(layer_value), c.kCFNumberIntType, &layer);
            if (layer != 0) continue;

            const number_value = c.CFDictionaryGetValue(win_dict, number_key);
            if (number_value == null) continue;
            var wid: c.CGWindowID = 0;
            if (c.CFNumberGetValue(@ptrCast(number_value), c.kCFNumberIntType, &wid) == 0) continue;

            // If we didn't see this window in any space, check if actually minimized via AX API
            if (!seen_windows.contains(wid)) {
                const window_info = getWindowInfo(wid);
                const name = std.mem.sliceTo(&window_info.name, 0);
                // Must be a regular app and actually minimized (AXMinimized == true)
                const is_regular_app = isRegularApp(window_info.pid);
                const is_minimized = isWindowMinimized(window_info.pid, name);
                if (is_regular_app and name.len > 0 and is_minimized) {
                    minimized_count += 1;
                }
            }
        }
    }
}

pub const WindowListItem = struct {
    window_id: c.CGWindowID,
    name: [256]u8,
    owner: [256]u8,
    pid: c_int,
    is_minimized: bool,
    is_hidden: bool,
};

pub fn getWindowList(allocator: std.mem.Allocator) ![]WindowListItem {
    const has_permission = c.CGPreflightScreenCaptureAccess();
    if (!has_permission) {
        return try allocator.alloc(WindowListItem, 0);
    }

    initWindowInfoCache();
    defer {
        if (g_window_info_cache) |cache| {
            c.CFRelease(cache);
            g_window_info_cache = null;
        }
    }

    var result = std.ArrayList(WindowListItem).empty;
    errdefer result.deinit(allocator);

    const conn = types._CGSDefaultConnection();
    const info_opaque = types.CGSCopyManagedDisplaySpaces(conn) orelse {
        return result.toOwnedSlice(allocator);
    };
    const info: c.CFArrayRef = @ptrCast(info_opaque);
    defer c.CFRelease(info);

    const spaces_key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, "Spaces", c.kCFStringEncodingUTF8);
    defer c.CFRelease(spaces_key);
    const id64_key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, "id64", c.kCFStringEncodingUTF8);
    defer c.CFRelease(id64_key);

    var set_tags: c_long = 0;
    var clear_tags: c_long = clearTags;

    var seen_windows = std.AutoHashMap(c.CGWindowID, void).init(allocator);
    defer seen_windows.deinit();

    const display_count = c.CFArrayGetCount(info);
    var display_idx: c_long = 0;
    while (display_idx < display_count) : (display_idx += 1) {
        const display_dict: c.CFDictionaryRef = @ptrCast(c.CFArrayGetValueAtIndex(info, display_idx));

        const spaces_opaque = c.CFDictionaryGetValue(display_dict, spaces_key);
        if (spaces_opaque == null) continue;
        const spaces: c.CFArrayRef = @ptrCast(spaces_opaque);

        const space_count = c.CFArrayGetCount(spaces);
        var space_idx: c_long = 0;
        while (space_idx < space_count) : (space_idx += 1) {
            const space_dict: c.CFDictionaryRef = @ptrCast(c.CFArrayGetValueAtIndex(spaces, space_idx));
            const space_id_value = c.CFDictionaryGetValue(space_dict, id64_key);
            if (space_id_value == null) continue;

            var space_id: c_longlong = 0;
            if (c.CFNumberGetValue(@ptrCast(space_id_value), c.kCFNumberLongLongType, &space_id) == 0) continue;

            const space_id_cf = c.CFNumberCreate(c.kCFAllocatorDefault, c.kCFNumberLongLongType, &space_id);
            var space_ids = [_]?*const anyopaque{space_id_cf};
            const space_id_array = c.CFArrayCreate(c.kCFAllocatorDefault, @ptrCast(&space_ids), 1, &c.kCFTypeArrayCallBacks);

            const windows_opaque = types.CGSCopyWindowsWithOptionsAndTags(conn, 0, @ptrCast(@constCast(space_id_array)), 2, &set_tags, &clear_tags);
            c.CFRelease(space_id_array);
            c.CFRelease(space_id_cf);

            if (windows_opaque == null) continue;
            const windows: c.CFArrayRef = @ptrCast(windows_opaque);
            defer c.CFRelease(windows);

            const window_count = c.CFArrayGetCount(windows);
            for (0..@intCast(window_count)) |i| {
                const window_id_value = c.CFArrayGetValueAtIndex(windows, @intCast(i));
                var window_id: c.CGWindowID = 0;
                if (c.CFNumberGetValue(@ptrCast(window_id_value), c.kCFNumberIntType, &window_id) != 0) {
                    if (seen_windows.contains(window_id)) continue;
                    try seen_windows.put(window_id, {});

                    const window_info = getWindowInfo(window_id);
                    if (window_info.layer != 0) continue;
                    if (!isRegularApp(window_info.pid)) continue;
                    const name = std.mem.sliceTo(&window_info.name, 0);
                    if (name.len == 0) continue;

                    try result.append(allocator, .{
                        .window_id = window_id,
                        .name = window_info.name,
                        .owner = window_info.owner,
                        .pid = window_info.pid,
                        .is_minimized = false,
                        .is_hidden = isAppHidden(window_info.pid),
                    });
                }
            }
        }
    }

    // Record count of on-screen windows before adding minimized ones
    const on_screen_count = result.items.len;

    if (g_window_info_cache) |cache| {
        const cache_count = c.CFArrayGetCount(cache);
        const number_key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, "kCGWindowNumber", c.kCFStringEncodingUTF8);
        defer c.CFRelease(number_key);
        const layer_key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, "kCGWindowLayer", c.kCFStringEncodingUTF8);
        defer c.CFRelease(layer_key);

        for (0..@intCast(cache_count)) |i| {
            const win_dict: c.CFDictionaryRef = @ptrCast(c.CFArrayGetValueAtIndex(cache, @intCast(i)));

            const layer_value = c.CFDictionaryGetValue(win_dict, layer_key);
            if (layer_value == null) continue;
            var layer: c_int = 0;
            _ = c.CFNumberGetValue(@ptrCast(layer_value), c.kCFNumberIntType, &layer);
            if (layer != 0) continue;

            const number_value = c.CFDictionaryGetValue(win_dict, number_key);
            if (number_value == null) continue;
            var wid: c.CGWindowID = 0;
            if (c.CFNumberGetValue(@ptrCast(number_value), c.kCFNumberIntType, &wid) == 0) continue;

            if (!seen_windows.contains(wid)) {
                const window_info = getWindowInfo(wid);
                const name = std.mem.sliceTo(&window_info.name, 0);
                if (!isRegularApp(window_info.pid)) continue;
                if (name.len == 0) continue;
                const is_minimized = isWindowMinimized(window_info.pid, name);
                if (!is_minimized) continue;

                try result.append(allocator, .{
                    .window_id = wid,
                    .name = window_info.name,
                    .owner = window_info.owner,
                    .pid = window_info.pid,
                    .is_minimized = true,
                    .is_hidden = false,
                });
            }
        }
    }

    // Sort on-screen windows by global z-order (front-to-back).
    // Use kCGWindowListOptionOnScreenOnly which returns windows in true global z-order
    // across all monitors (unlike kCGWindowListOptionAll or per-space CGS iteration).
    // When a window is focused, macOS moves it to the front of the z-stack, so this
    // effectively gives MRU ordering.
    if (on_screen_count > 1) {
        const on_screen_list = c.CGWindowListCopyWindowInfo(
            c.kCGWindowListOptionOnScreenOnly | c.kCGWindowListExcludeDesktopElements,
            c.kCGNullWindowID,
        );
        if (on_screen_list) |list| {
            defer c.CFRelease(list);

            var z_order = std.AutoHashMap(c.CGWindowID, u32).init(allocator);
            defer z_order.deinit();

            const list_count = c.CFArrayGetCount(list);
            const number_key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, "kCGWindowNumber", c.kCFStringEncodingUTF8);
            defer c.CFRelease(number_key);

            var z_idx: u32 = 0;
            for (0..@intCast(list_count)) |i| {
                const win_dict: c.CFDictionaryRef = @ptrCast(c.CFArrayGetValueAtIndex(list, @intCast(i)));
                const number_value = c.CFDictionaryGetValue(win_dict, number_key);
                if (number_value == null) continue;
                var wid: c.CGWindowID = 0;
                if (c.CFNumberGetValue(@ptrCast(number_value), c.kCFNumberIntType, &wid) == 0) continue;
                z_order.put(wid, z_idx) catch {};
                z_idx += 1;
            }

            // Sort only the on-screen portion by global z-order.
            // Minimized windows (appended after on_screen_count) keep their position at the end.
            const on_screen_slice = result.items[0..on_screen_count];
            const z_ctx = z_order;
            std.mem.sort(WindowListItem, on_screen_slice, z_ctx, struct {
                fn lessThan(ctx: std.AutoHashMap(c.CGWindowID, u32), a: WindowListItem, b_item: WindowListItem) bool {
                    const a_z = ctx.get(a.window_id) orelse std.math.maxInt(u32);
                    const b_z = ctx.get(b_item.window_id) orelse std.math.maxInt(u32);
                    return a_z < b_z;
                }
            }.lessThan);
        }
    }

    return result.toOwnedSlice(allocator);
}
