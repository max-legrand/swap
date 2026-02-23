// MIT License
// Copyright (c) 2025 Max Legrand
// See LICENSE for full terms.

const std = @import("std");

const sort = @import("sort");

const application = @import("application.zig");
const darwin = @import("darwin.zig");
const keybind = @import("keybind.zig");
const types = @import("types.zig");
const c = types.c;
const utils = @import("utils.zig");
const ALLOCATOR = utils.allocator;
const config = @import("config.zig");
const keys = @import("keys.zig");
const history = @import("history.zig");

const KeybindMode = enum(u8) {
    toggle = 0,
    hold = 1,
};

const DisplayMode = enum { apps, windows };

pub const AppState = struct {
    log_file: std.fs.File,
    apps: []*application.App,
    windows: []*darwin.WindowInfo,
    index: usize,
    window_visible: bool,
    config: config.Config,
    mode: DisplayMode,
    has_screen_recording_perms: bool,
    search_history: history.History,

    const Self = AppState;

    pub fn init() !AppState {
        const cfg = try config.parseConfig(ALLOCATOR);
        var state: Self = .{
            .log_file = try std.fs.createFileAbsolute(cfg.log_file_path, .{ .truncate = false }),
            .apps = &[_]*application.App{},
            .index = 0,
            .window_visible = false,
            .windows = &[_]*darwin.WindowInfo{},
            .config = cfg,
            .mode = .apps,
            .has_screen_recording_perms = false,
            .search_history = try history.History.init(ALLOCATOR),
        };
        try state.logCallback("swap_init");
        return state;
    }

    pub fn deinit(self: *Self) void {
        self.search_history.deinit();
        self.logCallback("swap_deinit") catch {
            std.debug.print("Failed to log swap_deinit\n", .{});
        };
        self.config.deinit(ALLOCATOR);
        self.log_file.close();
        self.* = undefined;
    }

    pub fn logCallback(self: *Self, msg: []const u8) !void {
        const now = std.time.milliTimestamp();
        const formatted = try std.fmt.allocPrint(ALLOCATOR, "[{d}] {s}\n", .{ now, msg });
        defer ALLOCATOR.free(formatted);
        try self.log_file.seekFromEnd(0);
        var log_buffer: [4096]u8 = undefined;
        var file_writer = self.log_file.writerStreaming(&log_buffer);
        try file_writer.interface.writeAll(formatted);
        try file_writer.interface.flush();
    }
};

var Global_State: AppState = undefined;
var CURRENT_QUERY: []const u8 = "";

export fn swap_init() c_int {
    Global_State = AppState.init() catch {
        return -1;
    };
    return 0;
}

export fn swap_deinit() void {
    Global_State.deinit();
    utils.deinitAllocator();
}

export fn get_timestamp() c_long {
    Global_State.logCallback("get_timestamp") catch {};
    return @intCast(std.time.milliTimestamp());
}

pub const SwapAppInfo = extern struct {
    name: [*:0]u8,
    pid: c_long,
    zindex: c_long,
    is_running: bool,
    path: [*:0]u8,
};

pub const ColorRGB = extern struct {
    red: u8,
    green: u8,
    blue: u8,
};

pub const AppReturn = extern struct {
    length: c_int,
    apps: [*]SwapAppInfo,
    idx: usize,
    pub fn deinit(self: *AppReturn, allocator: std.mem.Allocator) void {
        const end: usize = @intCast(self.length);
        const slice = self.apps[0..end];
        for (slice) |app| {
            allocator.free(std.mem.sliceTo(app.name, 0));
            allocator.free(std.mem.sliceTo(app.path, 0));
        }
        allocator.free(slice);
    }
};

pub const SwapWindowInfo = extern struct {
    window_id: u32,
    name: [*:0]u8,
    owner: [*:0]u8,
    pid: c_int,
    is_minimized: bool,
    is_hidden: bool,
};

pub const WindowReturn = extern struct {
    length: c_int,
    windows: [*]SwapWindowInfo,
    idx: usize,
    pub fn deinit(self: *WindowReturn, allocator: std.mem.Allocator) void {
        const end: usize = @intCast(self.length);
        const slice = self.windows[0..end];
        for (slice) |win| {
            allocator.free(std.mem.sliceTo(win.name, 0));
            allocator.free(std.mem.sliceTo(win.owner, 0));
        }
        allocator.free(slice);
    }
};

fn fuzzApps(allocator: std.mem.Allocator, apps: []*application.App, query: []const u8) []*application.App {
    // Early return for empty query
    if (query.len == 0) {
        return &[_]*application.App{};
    }

    // Structure to hold app with its match score
    const ScoredApp = struct {
        app: *application.App,
        score: i32,
    };

    var scored_apps = std.ArrayList(ScoredApp).empty;
    defer scored_apps.deinit(allocator);

    // Convert query to lowercase for case-insensitive matching
    var query_lower = allocator.alloc(u8, query.len) catch return &[_]*application.App{};
    defer allocator.free(query_lower);
    for (query, 0..) |char, i| {
        query_lower[i] = std.ascii.toLower(char);
    }

    // Score each app
    for (apps) |app| {
        const app_name = std.mem.sliceTo(&app.name, 0);

        // Convert app name to lowercase for matching
        var name_lower = allocator.alloc(u8, app_name.len) catch continue;
        defer allocator.free(name_lower);
        for (app_name, 0..) |char, i| {
            name_lower[i] = std.ascii.toLower(char);
        }

        // Check if query matches
        const match_pos = std.mem.indexOf(u8, name_lower, query_lower);
        if (match_pos == null) continue;

        // Calculate score (lower is better)
        // - Prefix match: 0 points (best)
        // - Early match: fewer points
        // - Late match: more points
        var score: i32 = @intCast(match_pos.?);

        // Bonus for exact prefix match
        if (match_pos.? == 0) {
            score -= 1000; // Large bonus for prefix matches
        }

        const recency_bonus = Global_State.search_history.getRecencyBonus(query, app_name);
        score += recency_bonus;

        // Add app to scored list
        const copy_app = allocator.create(application.App) catch continue;
        copy_app.* = .{
            .is_running = app.is_running,
            .pid = app.pid,
            .name = undefined,
            .zindex = app.zindex,
            .path = undefined,
        };
        @memcpy(&copy_app.name, &app.name);
        @memcpy(&copy_app.path, &app.path);

        scored_apps.append(
            allocator,
            .{
                .app = copy_app,
                .score = score,
            },
        ) catch continue;
    }
    const sortFn = struct {
        fn sort(a: ScoredApp, b: ScoredApp) i8 {
            // First priority: running apps come first
            if (a.app.is_running != b.app.is_running) {
                return if (a.app.is_running) -1 else 1;
            }

            // Second priority: better match score
            if (a.score != b.score) {
                if (a.score > b.score) {
                    return 1;
                } else if (a.score < b.score) {
                    return -1;
                }
            }

            // Third priority: lower zindex (more recently used)
            if (a.app.zindex != b.app.zindex) {
                if (a.app.zindex > b.app.zindex) {
                    return 1;
                } else if (a.app.zindex < b.app.zindex) {
                    return -1;
                }
            }
            return 0;
        }
    }.sort;

    sort.powersort(ScoredApp, scored_apps.items, sortFn) catch {
        return &[_]*application.App{};
    };

    var result = std.ArrayList(*application.App).empty;
    defer result.deinit(allocator);

    for (scored_apps.items, 0..) |scored, i| {
        if (!scored.app.is_running and result.items.len >= 5) {
            const remaining = scored_apps.items[i..];
            for (remaining) |s| {
                s.app.deinit(allocator);
            }
            break;
        }
        result.append(allocator, scored.app) catch {
            continue;
        };
    }

    return result.toOwnedSlice(allocator) catch {
        return &[_]*application.App{};
    };
}

pub export fn get_apps(query_opt: ?[*:0]u8) ?*AppReturn {
    const query: []const u8 = std.mem.span(query_opt) orelse "";
    var query_apps: []*application.App = undefined;
    var should_free_query_apps = false;

    if (std.mem.eql(u8, query, "")) {
        if (CURRENT_QUERY.len > 0) ALLOCATOR.free(CURRENT_QUERY);
        CURRENT_QUERY = "";
        Global_State.logCallback("get_apps : NULL") catch {};
        query_apps = application.get_running_apps(ALLOCATOR) catch {
            return null;
        };
    } else {
        if (CURRENT_QUERY.len > 0) ALLOCATOR.free(CURRENT_QUERY);
        CURRENT_QUERY = ALLOCATOR.dupe(u8, query) catch "";
        const msg = std.fmt.allocPrint(ALLOCATOR, "get_apps => {s}", .{query}) catch {
            return null;
        };
        Global_State.logCallback(msg) catch {};
        ALLOCATOR.free(msg);

        const base_apps = application.get_all_apps(ALLOCATOR) catch {
            return null;
        };
        query_apps = fuzzApps(ALLOCATOR, base_apps, query);
        should_free_query_apps = true;
        for (base_apps) |a| {
            ALLOCATOR.destroy(a);
        }
        ALLOCATOR.free(base_apps);
    }

    var apps = std.ArrayList(SwapAppInfo).initCapacity(ALLOCATOR, query_apps.len) catch {
        return null;
    };
    for (query_apps) |a| {
        apps.appendAssumeCapacity(.{
            .name = ALLOCATOR.dupeZ(u8, std.mem.sliceTo(&a.name, 0)) catch {
                return null;
            },
            .pid = @intCast(a.pid),
            .zindex = @intCast(a.zindex),
            .is_running = a.is_running,
            .path = ALLOCATOR.dupeZ(u8, std.mem.sliceTo(&a.path, 0)) catch {
                return null;
            },
        });
    }

    // Free the old global apps before storing new ones
    for (Global_State.apps) |a| {
        ALLOCATOR.destroy(a);
    }
    if (Global_State.apps.len > 0) {
        ALLOCATOR.free(Global_State.apps);
    }

    const result = ALLOCATOR.create(AppReturn) catch {
        return null;
    };

    var msg = std.ArrayList(u8).empty;
    defer msg.deinit(ALLOCATOR);

    msg.appendSlice(ALLOCATOR, "get_apps ; result => \n") catch {};

    for (apps.items) |a| {
        const name: []u8 = std.mem.sliceTo(a.name, 0);
        msg.appendSlice(ALLOCATOR, name) catch {};
        msg.append(ALLOCATOR, '\n') catch {};
    }

    const msg_string: []u8 = msg.toOwnedSlice(ALLOCATOR) catch "";
    Global_State.logCallback(msg_string) catch {};
    ALLOCATOR.free(msg_string);

    result.* = .{
        .length = @intCast(apps.items.len),
        .apps = apps.items.ptr,
        .idx = 0,
    };

    // Store apps in global state for navigation
    Global_State.apps = query_apps;
    Global_State.index = 0;

    var pid_list = std.ArrayList(i64).initCapacity(ALLOCATOR, query_apps.len) catch {
        return null;
    };
    defer pid_list.deinit(ALLOCATOR);

    for (query_apps) |app| {
        pid_list.append(ALLOCATOR, app.pid) catch {
            return null;
        };
    }

    return result;
}

pub export fn deinitAppReturn(app_return: *AppReturn) void {
    app_return.deinit(ALLOCATOR);
    ALLOCATOR.destroy(app_return);
}

fn keybind_callback(_: c.CGEventTapProxy, event_type: c.CGEventType, event: c.CGEventRef, _: ?*anyopaque) callconv(.c) c.CGEventRef {
    const flags = c.CGEventGetFlags(event);
    const cmd_pressed = (flags & c.kCGEventFlagMaskCommand) != 0;
    const ctrl_pressed = (flags & c.kCGEventFlagMaskControl) != 0;
    const shift_pressed = (flags & c.kCGEventFlagMaskShift) != 0;

    // Handle modifier key releases - close window when Command is released (hold mode only)
    if (event_type == c.kCGEventFlagsChanged) {
        if (Global_State.config.mode == .hold) {
            if (Global_State.window_visible and !cmd_pressed) {
                Global_State.logCallback("command released - closing") catch {};
                openApp();
                Global_State.window_visible = false;
                hideWindow();
            }
        }
        return event;
    }

    if (event_type == c.kCGEventKeyDown) {
        const keycode = c.CGEventGetIntegerValueField(event, c.kCGKeyboardEventKeycode);

        // Cmd+Ctrl+. -> Apps mode
        if (keycode == keys.period_key and cmd_pressed and ctrl_pressed) {
            if (Global_State.window_visible) {
                if (Global_State.mode == .apps) {
                    // Already in apps mode, hide window
                    Global_State.window_visible = false;
                    hideWindow();
                } else {
                    // Switch to apps mode
                    Global_State.mode = .apps;
                    Global_State.index = 0;
                    switchToAppsMode();
                }
            } else {
                // Show window in apps mode
                Global_State.mode = .apps;
                Global_State.window_visible = true;
                Global_State.index = 0;
                showWindow();
            }
            return null;
        }

        // Cmd+Ctrl+\ -> Windows mode
        if (keycode == keys.backslash_key and cmd_pressed and ctrl_pressed) {
            if (!Global_State.has_screen_recording_perms) {
                return event;
            }

            if (Global_State.window_visible) {
                if (Global_State.mode == .windows) {
                    // Already in windows mode, hide window
                    Global_State.window_visible = false;
                    hideWindow();
                } else {
                    // Switch to windows mode
                    Global_State.mode = .windows;
                    Global_State.index = 0;
                    switchToWindowsMode();
                }
            } else {
                // Show window in windows mode
                Global_State.mode = .windows;
                Global_State.window_visible = true;
                Global_State.index = 0;
                showWindow();
            }
            return null;
        }

        // Only intercept other keys when window is visible
        if (!Global_State.window_visible) {
            return event;
        }

        // Handle navigation keys (consume these)
        // Use appropriate list length based on current mode
        const list_len = if (Global_State.mode == .apps) Global_State.apps.len else WINDOW_COUNT;

        if (keycode == keys.up_arrow or (keycode == keys.k_key and cmd_pressed) or (keycode == keys.p_key and ctrl_pressed)) {
            if (list_len > 0 and Global_State.index > 0) {
                Global_State.index -= 1;
                updateApps();
            }
            return null;
        } else if (keycode == keys.down_arrow or (keycode == keys.j_key and cmd_pressed) or (keycode == keys.n_key and ctrl_pressed)) {
            if (list_len > 0 and Global_State.index < list_len - 1) {
                Global_State.index += 1;
                updateApps();
            }
            return null;
        } else if (keycode == keys.tab) {
            if (list_len > 0) {
                if (!shift_pressed) {
                    Global_State.index = (Global_State.index + 1) % list_len;
                } else {
                    Global_State.index = if (Global_State.index == 0) list_len - 1 else Global_State.index - 1;
                }
                updateApps();
            }
            return null;
        } else if (keycode == keys.enter or (keycode == keys.y_key and ctrl_pressed)) {
            if (Global_State.mode == .apps) {
                openApp();
            } else {
                openWindowOrApp();
            }
            Global_State.window_visible = false;
            hideWindow();
            return null;
        } else if (keycode == keys.q_key and ctrl_pressed) {
            if (Global_State.mode == .apps) {
                killApp();
                updateApps();
            } else {
                killWindow();
                updateWindows();
            }
            return null;
        } else if (keycode == keys.escape) {
            Global_State.window_visible = false;
            hideWindow();
            return null;
        }

        // Toggle mode: pass events through as-is (typing works normally)
        if (Global_State.config.mode == .toggle) {
            return event;
        }

        // Hold mode: strip Command/Control so Cmd+A becomes 'a', preserves key repeat
        const mask: u64 = @bitCast(@as(i64, c.kCGEventFlagMaskCommand | c.kCGEventFlagMaskControl));
        c.CGEventSetFlags(event, flags & ~mask);
        return event;
    }
    return event;
}

export fn setup_keybind() c_int {
    keybind.registerKeybind(keybind_callback) catch {
        return 1;
    };
    return 0;
}

export fn check_for_screen_recording_perms() c_int {
    const has_permission = c.CGPreflightScreenCaptureAccess();
    Global_State.has_screen_recording_perms = has_permission;

    if (Global_State.config.skip_screen_recording_perms) {
        return 0;
    }

    return @intFromBool(has_permission);
}

export fn run_keybind_loop() void {
    keybind.runEventLoop();
}

export fn update_apps() ?*AppReturn {
    const result = ALLOCATOR.create(AppReturn) catch {
        return null;
    };

    var items = std.ArrayList(SwapAppInfo).initCapacity(ALLOCATOR, Global_State.apps.len) catch {
        return null;
    };
    defer items.deinit(ALLOCATOR);

    for (Global_State.apps) |a| {
        items.appendAssumeCapacity(.{
            .name = ALLOCATOR.dupeZ(u8, std.mem.sliceTo(&a.name, 0)) catch {
                return null;
            },
            .pid = @intCast(a.pid),
            .zindex = @intCast(a.zindex),
            .is_running = a.is_running,
            .path = ALLOCATOR.dupeZ(u8, std.mem.sliceTo(&a.path, 0)) catch {
                return null;
            },
        });
    }

    const slice = items.toOwnedSlice(ALLOCATOR) catch {
        return null;
    };

    result.* = .{
        .length = @intCast(Global_State.apps.len),
        .apps = slice.ptr,
        .idx = Global_State.index,
    };

    const msg = std.fmt.allocPrint(ALLOCATOR, "update_apps -> {d}\n", .{Global_State.index}) catch return null;
    defer ALLOCATOR.free(msg);
    Global_State.logCallback(msg) catch {};

    return result;
}

fn openApp() void {
    if (Global_State.apps.len == 0) return;
    const app = Global_State.apps[Global_State.index];

    // Record selection for recency scoring
    if (CURRENT_QUERY.len > 0) {
        const app_name = std.mem.sliceTo(&app.name, 0);
        Global_State.search_history.record(CURRENT_QUERY, app_name) catch {};
    }

    const path: []const u8 = std.mem.sliceTo(&app.path, 0);
    var child = std.process.Child.init(
        &[_][]const u8{ "open", path },
        ALLOCATOR,
    );
    child.spawn() catch {};
}

fn killApp() void {
    const pid = Global_State.apps[Global_State.index].pid;
    const name = std.mem.sliceTo(&Global_State.apps[Global_State.index].name, 0);
    const msg = std.fmt.allocPrint(ALLOCATOR, "killApp pid={d} name={s}", .{ pid, name }) catch null;
    if (msg) |m| {
        Global_State.logCallback(m) catch {};
    }

    const pid_str = std.fmt.allocPrint(ALLOCATOR, "{d}", .{pid}) catch return;
    defer ALLOCATOR.free(pid_str);
    var child = std.process.Child.init(
        &[_][]const u8{ "kill", pid_str },
        ALLOCATOR,
    );
    child.spawn() catch {};
    var items = std.ArrayList(*application.App).initCapacity(ALLOCATOR, Global_State.apps.len - 1) catch {
        return;
    };
    const apps = Global_State.apps;
    const index_to_kill = Global_State.index;
    if (Global_State.index == Global_State.apps.len - 1) {
        Global_State.index -= 1;
    }
    for (Global_State.apps, 0..) |a, i| {
        if (i != index_to_kill) {
            items.appendAssumeCapacity(a);
        } else {
            a.deinit(ALLOCATOR);
            continue;
        }
    }
    Global_State.apps = items.toOwnedSlice(ALLOCATOR) catch {
        return;
    };
    ALLOCATOR.free(apps);
}

fn quitApp(pid: c_int) void {
    const pid_str = std.fmt.allocPrint(ALLOCATOR, "{d}", .{pid}) catch return;
    defer ALLOCATOR.free(pid_str);
    var child = std.process.Child.init(
        &[_][]const u8{ "kill", pid_str },
        ALLOCATOR,
    );
    child.spawn() catch {};
}

fn killWindow() void {
    Global_State.logCallback("killWindow: enter") catch {};

    if (Global_State.index >= WINDOW_COUNT) {
        Global_State.logCallback("killWindow: index >= WINDOW_COUNT") catch {};
        return;
    }

    const target_window_id = WINDOW_IDS[Global_State.index];
    if (target_window_id == 0) {
        const pid = WINDOW_PIDS[Global_State.index];
        if (pid == 0) {
            Global_State.logCallback("killWindow: target_window_id == 0, pid == 0") catch {};
            return;
        }

        const msg = std.fmt.allocPrint(ALLOCATOR, "killWindow: no window id, killing pid={d}", .{pid}) catch null;
        if (msg) |m| {
            Global_State.logCallback(m) catch {};
            ALLOCATOR.free(m);
        }

        quitApp(pid);
        return;
    }

    const pid = WINDOW_PIDS[Global_State.index];

    const app_ref = c.AXUIElementCreateApplication(pid);
    if (app_ref == null) {
        Global_State.logCallback("killWindow: app_ref == null") catch {};
        return;
    }
    defer c.CFRelease(app_ref);

    var windows_ref: c.CFTypeRef = null;
    const windows_attr = c.CFStringCreateWithCString(c.kCFAllocatorDefault, "AXWindows", c.kCFStringEncodingUTF8);
    defer c.CFRelease(windows_attr);

    if (c.AXUIElementCopyAttributeValue(app_ref, windows_attr, &windows_ref) != 0) {
        Global_State.logCallback("killWindow: failed to get AXWindows") catch {};
        return;
    }
    if (windows_ref == null) {
        Global_State.logCallback("killWindow: windows_ref == null") catch {};
        return;
    }
    defer c.CFRelease(windows_ref);

    const windows: c.CFArrayRef = @ptrCast(windows_ref);
    const count = c.CFArrayGetCount(windows);

    const log_msg = std.fmt.allocPrint(ALLOCATOR, "killWindow: searching {d} windows for wid {d}", .{ count, target_window_id }) catch "killWindow: alloc failed";
    Global_State.logCallback(log_msg) catch {};
    if (!std.mem.eql(u8, log_msg, "killWindow: alloc failed")) {
        ALLOCATOR.free(log_msg);
    }

    for (0..@intCast(count)) |i| {
        const win: c.AXUIElementRef = @ptrCast(c.CFArrayGetValueAtIndex(windows, @intCast(i)));

        var wid: u32 = 0;
        const ax_result = types._AXUIElementGetWindow(win, &wid);
        const wid_msg = std.fmt.allocPrint(ALLOCATOR, "killWindow: window {d} has wid {d}, ax_result={d}", .{ i, wid, ax_result }) catch "killWindow: alloc failed";
        Global_State.logCallback(wid_msg) catch {};
        if (!std.mem.eql(u8, wid_msg, "killWindow: alloc failed")) {
            ALLOCATOR.free(wid_msg);
        }

        if (ax_result == 0 and wid == target_window_id) {
            Global_State.logCallback("killWindow: found match, closing") catch {};

            // If this is the last window for the app, quit the app instead of
            // just closing the window (many apps stay alive with no windows open).
            if (count <= 1) {
                const quit_msg = std.fmt.allocPrint(ALLOCATOR, "killWindow: last window for pid={d}, quitting app", .{pid}) catch null;
                if (quit_msg) |m| {
                    Global_State.logCallback(m) catch {};
                    ALLOCATOR.free(m);
                }
                quitApp(pid);
                return;
            }

            // Try AXCloseButton -> AXPress first (more reliable)
            const close_button_attr = c.CFStringCreateWithCString(c.kCFAllocatorDefault, "AXCloseButton", c.kCFStringEncodingUTF8);
            if (close_button_attr != null) {
                defer c.CFRelease(close_button_attr);
                var close_button_ref: c.CFTypeRef = null;
                if (c.AXUIElementCopyAttributeValue(win, close_button_attr, &close_button_ref) == 0 and close_button_ref != null) {
                    defer c.CFRelease(close_button_ref);
                    const press_action = c.CFStringCreateWithCString(c.kCFAllocatorDefault, "AXPress", c.kCFStringEncodingUTF8);
                    if (press_action != null) {
                        defer c.CFRelease(press_action);
                        const press_result = c.AXUIElementPerformAction(@ptrCast(close_button_ref), press_action);
                        const result_msg = std.fmt.allocPrint(ALLOCATOR, "killWindow: AXPress on close button result={d}", .{press_result}) catch "killWindow: alloc failed";
                        Global_State.logCallback(result_msg) catch {};
                        if (!std.mem.eql(u8, result_msg, "killWindow: alloc failed")) {
                            ALLOCATOR.free(result_msg);
                        }
                        if (press_result == 0) return;
                    }
                }
            }

            // Fallback to AXClose on window
            const close_action = c.CFStringCreateWithCString(c.kCFAllocatorDefault, "AXClose", c.kCFStringEncodingUTF8);
            if (close_action != null) {
                defer c.CFRelease(close_action);
                const action_result = c.AXUIElementPerformAction(win, close_action);
                const result_msg = std.fmt.allocPrint(ALLOCATOR, "killWindow: AXClose result={d}", .{action_result}) catch "killWindow: alloc failed";
                Global_State.logCallback(result_msg) catch {};
                if (!std.mem.eql(u8, result_msg, "killWindow: alloc failed")) {
                    ALLOCATOR.free(result_msg);
                }
            }
            return;
        }
    }
    Global_State.logCallback("killWindow: no match found") catch {};
}

pub export fn openConfigFile() void {
    const config_path = config.getConfigFilePath(ALLOCATOR) catch return;
    defer ALLOCATOR.free(config_path);

    var child = std.process.Child.init(
        &[_][]const u8{ "open", "-a", "TextEdit", config_path },
        ALLOCATOR,
    );
    child.spawn() catch {};
}

/// Return the current config color as RGB values
pub export fn getColor() ColorRGB {
    return .{
        .red = Global_State.config.color.red,
        .green = Global_State.config.color.green,
        .blue = Global_State.config.color.blue,
    };
}

pub export fn reloadConfig() u8 {
    Global_State.config = config.parseConfig(ALLOCATOR) catch {
        return 1;
    };
    return 0;
}

extern fn updateApps() void;
extern fn updateWindows() void;
extern fn showWindow() void;
extern fn hideWindow() void;
extern fn switchToWindowsMode() void;
extern fn switchToAppsMode() void;
extern fn openSelectedWindow() void;

pub export fn get_windows() ?*WindowReturn {
    const windows = darwin.getWindowList(ALLOCATOR) catch {
        return null;
    };
    defer ALLOCATOR.free(windows);

    var items = std.ArrayList(SwapWindowInfo).initCapacity(ALLOCATOR, windows.len) catch {
        return null;
    };

    for (windows) |w| {
        items.appendAssumeCapacity(.{
            .window_id = w.window_id,
            .name = ALLOCATOR.dupeZ(u8, std.mem.sliceTo(&w.name, 0)) catch {
                return null;
            },
            .owner = ALLOCATOR.dupeZ(u8, std.mem.sliceTo(&w.owner, 0)) catch {
                return null;
            },
            .pid = w.pid,
            .is_minimized = w.is_minimized,
            .is_hidden = w.is_hidden,
        });
    }

    const result = ALLOCATOR.create(WindowReturn) catch {
        return null;
    };

    const slice = items.toOwnedSlice(ALLOCATOR) catch {
        return null;
    };

    result.* = .{
        .length = @intCast(slice.len),
        .windows = slice.ptr,
        .idx = 0,
    };

    return result;
}

pub export fn deinitWindowReturn(window_return: *WindowReturn) void {
    window_return.deinit(ALLOCATOR);
    ALLOCATOR.destroy(window_return);
}

pub export fn get_current_mode() u8 {
    return @intFromEnum(Global_State.mode);
}

pub export fn set_mode(mode: u8) void {
    Global_State.mode = @enumFromInt(mode);
}

var WINDOW_COUNT: usize = 0;
var WINDOW_IDS: [256]u32 = [_]u32{0} ** 256;
var WINDOW_PIDS: [256]i32 = [_]i32{0} ** 256;
var WINDOW_PATHS: [256][512]u8 = [_][512]u8{[_]u8{0} ** 512} ** 256;

pub export fn set_window_count(count: usize) void {
    WINDOW_COUNT = count;
}

pub export fn set_window_info(index: usize, window_id: u32, pid: i32, path: [*:0]const u8) void {
    if (index >= 256) return;
    WINDOW_IDS[index] = window_id;
    WINDOW_PIDS[index] = pid;
    const path_slice = std.mem.span(path);
    const copy_len = @min(path_slice.len, 511);
    @memcpy(WINDOW_PATHS[index][0..copy_len], path_slice[0..copy_len]);
    WINDOW_PATHS[index][copy_len] = 0;
}

pub export fn get_selected_index() usize {
    return Global_State.index;
}

pub export fn set_selected_index(index: usize) void {
    Global_State.index = index;
}

fn openWindowOrApp() void {
    if (Global_State.index >= WINDOW_COUNT) return;

    const window_id = WINDOW_IDS[Global_State.index];
    if (window_id == 0) {
        // No specific window, just open the app by path
        const path = std.mem.sliceTo(&WINDOW_PATHS[Global_State.index], 0);
        if (path.len > 0) {
            var child = std.process.Child.init(
                &[_][]const u8{ "open", path },
                ALLOCATOR,
            );
            child.spawn() catch {};
        }
    } else {
        // Has a specific window, let Swift handle it
        openSelectedWindow();
    }
}
