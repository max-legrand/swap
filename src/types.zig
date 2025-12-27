// MIT License
// Copyright (c) 2025 Max Legrand
// See LICENSE for full terms.

pub const c = @cImport({
    @cInclude("CoreFoundation/CoreFoundation.h");
    @cInclude("CoreGraphics/CoreGraphics.h");
    @cInclude("ApplicationServices/ApplicationServices.h");
    @cInclude("dlfcn.h");
    @cInclude("unistd.h");
});

pub extern "ApplicationServices" fn CGSMainConnectionID() callconv(.c) c_uint;
pub extern "ApplicationServices" fn CGSCopyManagedDisplaySpaces(connection: c_uint) callconv(.c) ?*anyopaque;
pub extern "ApplicationServices" fn CGSCopyWindowsWithOptionsAndTags(connection: c_uint, owner: c_int, spaces: ?*anyopaque, options: c_int, set_tags: *c_long, clear_tags: *c_long) callconv(.c) ?*anyopaque;
pub extern "ApplicationServices" fn _CGSDefaultConnection() c_uint;
pub extern "ApplicationServices" fn _AXUIElementGetWindow(element: c.AXUIElementRef, wid: *u32) callconv(.c) c.AXError;

// Private LaunchServices API for command-tab ordering
pub const LSSessionID = i32;
pub const ProcessSerialNumber = extern struct {
    high: u32,
    low: u32,
};

pub extern "CoreServices" fn ProcessInformationCopyDictionary(psn: *const ProcessSerialNumber, mask: c.UInt32) callconv(.c) c.CFDictionaryRef;

// Private LaunchServices functions for command-tab ordering
pub extern "LaunchServices" fn _LSCopyApplicationArrayInFrontToBackOrder(sessionID: i32) callconv(.c) ?*anyopaque;
pub extern "LaunchServices" fn _LSASNExtractHighAndLowParts(asn: ?*const anyopaque, high: *u32, low: *u32) callconv(.c) void;
