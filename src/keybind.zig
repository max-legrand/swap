// MIT License
// Copyright (c) 2025 Max Legrand
// See LICENSE for full terms.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("types.zig").c;
const application = @import("application.zig");

var run_loop_source: c.CFRunLoopSourceRef = undefined;
var main_run_loop: c.CFRunLoopRef = undefined;

pub fn registerKeybind(cb: fn (c.CGEventTapProxy, c.CGEventType, c.CGEventRef, ?*anyopaque) callconv(.c) c.CGEventRef) !void {
    // Store the main run loop for later use
    main_run_loop = c.CFRunLoopGetMain();
    // Check if we have accessibility permissions
    const trusted = c.AXIsProcessTrusted();
    if (trusted == 0) {
        std.debug.print("Error: This application needs accessibility permissions.\n", .{});
        std.debug.print("Go to System Preferences > Security & Privacy > Privacy > Accessibility\n", .{});
        std.debug.print("and add this application to the list.\n", .{});
        return error.AccessibilityPermissionDenied;
    }

    // Combine event masks with OR
    var mask = c.CGEventMaskBit(c.kCGEventKeyDown);
    mask |= c.CGEventMaskBit(c.kCGEventKeyUp);
    mask |= c.CGEventMaskBit(c.kCGEventFlagsChanged);
    // Needed for key repeat (holding backspace, etc.)
    // Note: autorepeat events come through as kCGEventKeyDown with autorepeat flag

    const event_tap = c.CGEventTapCreate(
        c.kCGSessionEventTap,
        c.kCGHeadInsertEventTap,
        c.kCGEventTapOptionDefault,
        mask,
        cb,
        null,
    );
    if (event_tap == null) {
        return error.EventTapCreate;
    }
    if (c.CGEventTapIsEnabled(event_tap) == false) {
        return error.EventTapDisabled;
    }

    // Create a run loop source from the event tap
    run_loop_source = c.CFMachPortCreateRunLoopSource(c.kCFAllocatorDefault, event_tap, 0);
    if (run_loop_source == null) {
        return error.RunLoopSourceCreate;
    }

    // Add the source to the current run loop
    c.CFRunLoopAddSource(c.CFRunLoopGetCurrent(), run_loop_source, c.kCFRunLoopCommonModes);

    // Enable the event tap
    c.CGEventTapEnable(event_tap, true);
}

pub fn runEventLoop() void {
    c.CFRunLoopRun();
    c.CFRelease(run_loop_source);
}
