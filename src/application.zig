// MIT License
// Copyright (c) 2025 Max Legrand
// See LICENSE for full terms.

const std = @import("std");
const sort = @import("sort");
const utils = @import("utils.zig");
const darwin = @import("darwin.zig");
const types = @import("types.zig");
const c = types.c;

pub const get_all_apps = darwin.getAllApps;
pub const get_running_apps = darwin.getRunningApplications;

pub const APP_NAME_LEN = 256;
pub const APP_PATH_LEN = 1024;
pub const App = struct {
    name: [APP_NAME_LEN]u8,
    pid: i64,
    zindex: c_long,
    is_running: bool,
    path: [APP_PATH_LEN]u8,

    pub fn deinit(self: *App, allocator: std.mem.Allocator) void {
        defer allocator.destroy(self);
    }
};

pub const Application = struct {
    apps: []*App,

    pub fn deinit(self: *Application, allocator: std.mem.Allocator) void {
        for (self.apps) |app| {
            app.deinit(allocator);
            allocator.destroy(app);
        }
    }
};
