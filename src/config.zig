// MIT License
// Copyright (c) 2025 Max Legrand
// See LICENSE for full terms.

const std = @import("std");
const ALLOCATOR = @import("utils.zig").allocator;

const Color = struct {
    red: u8,
    green: u8,
    blue: u8,

    pub fn from_hex(hex_string: []const u8) !Color {
        if (hex_string.len == 0) return error.EmptyHexString;
        const hex = if (hex_string[0] == '#') hex_string[1..] else hex_string;
        if (hex.len != 6 and hex.len != 3) return error.InvalidHexString;
        var r: u8 = 0;
        var g: u8 = 0;
        var b: u8 = 0;
        if (hex.len == 3) {
            r = try std.fmt.parseInt(u8, hex[0..1], 16);
            g = try std.fmt.parseInt(u8, hex[1..2], 16);
            b = try std.fmt.parseInt(u8, hex[2..3], 16);
        } else {
            r = try std.fmt.parseInt(u8, hex[0..2], 16);
            g = try std.fmt.parseInt(u8, hex[2..4], 16);
            b = try std.fmt.parseInt(u8, hex[4..6], 16);
        }
        return .{
            .red = r,
            .green = g,
            .blue = b,
        };
    }

    pub fn to_hex(self: Color, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "#{X:0>2}{X:0>2}{X:0>2}", .{ self.red, self.green, self.blue });
    }
};

const Mode = enum {
    toggle,
    hold,

    pub fn from_str(str: []const u8) !Mode {
        if (std.mem.eql(u8, str, "toggle")) {
            return .toggle;
        } else if (std.mem.eql(u8, str, "hold")) {
            return .hold;
        }
        return error.InvalidMode;
    }
};

pub const Config = struct {
    color: Color = .{
        .red = 0,
        .green = 0,
        .blue = 0,
    },
    mode: Mode = .toggle,
    log_file_path: []const u8,
    skip_screen_recording_perms: bool = false,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.log_file_path);
    }

    pub fn to_file(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        const hex_string = try self.color.to_hex(allocator);
        defer allocator.free(hex_string);

        const str = try std.fmt.allocPrint(allocator,
            \\# Color to use for selection and text box highlighting; must be a valid 3 or 6 digit hex color code
            \\color={s}
            \\
            \\# Mode to use for selection; can be either "toggle" or "hold"
            \\mode={s}
            \\
            \\# Skip screen recording permission check
            \\skip_screen_recording_perms={}
        , .{
            hex_string,
            @tagName(self.mode),
            self.skip_screen_recording_perms,
        });
        return str;
    }
};

fn getDefaultLogPath(allocator: std.mem.Allocator) ![]const u8 {
    const app_data_dir = try std.fs.getAppDataDir(allocator, "swap");
    defer allocator.free(app_data_dir);

    std.fs.makeDirAbsolute(app_data_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            return err;
        }
    };

    return try std.fmt.allocPrint(allocator, "{s}/swap.log", .{app_data_dir});
}

pub fn parseConfig(allocator: std.mem.Allocator) !Config {
    const file = try getOrInitConfigFile(allocator);
    const default_log_path = try getDefaultLogPath(allocator);
    var config = Config{
        .log_file_path = default_log_path,
    };

    var buf: [1024]u8 = undefined;
    var file_reader = file.reader(&buf);
    var reader = &file_reader.interface;

    const file_data = try reader.allocRemaining(allocator, .unlimited);
    defer allocator.free(file_data);

    var line_it = std.mem.splitScalar(u8, file_data, '\n');
    while (line_it.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        // Try and split on the `=`
        var split_it = std.mem.splitScalar(u8, line, '=');
        const key = split_it.next() orelse return error.InvalidConfig;
        const value = split_it.next() orelse return error.InvalidConfig;

        if (std.mem.eql(u8, key, "color")) {
            const color = try Color.from_hex(value);
            config.color = color;
        } else if (std.mem.eql(u8, key, "mode")) {
            const mode = try Mode.from_str(value);
            config.mode = mode;
        } else if (std.mem.eql(u8, key, "skip_screen_recording_perms")) {
            var lowercase_string = allocator.alloc(u8, value.len) catch return error.OOM;
            defer allocator.free(lowercase_string);
            for (0..@intCast(value.len)) |i| {
                lowercase_string[i] = std.ascii.toLower(value[i]);
            }
            if (std.mem.eql(u8, lowercase_string, "true")) {
                config.skip_screen_recording_perms = true;
            } else if (std.mem.eql(u8, lowercase_string, "false")) {
                config.skip_screen_recording_perms = false;
            } else {
                return error.InvalidBoolean;
            }
        }
    }

    return config;
}

pub fn getConfigFilePath(allocator: std.mem.Allocator) ![]const u8 {
    const app_data_dir = try std.fs.getAppDataDir(allocator, "swap");
    defer allocator.free(app_data_dir);

    std.fs.makeDirAbsolute(app_data_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            return err;
        }
    };
    return try std.fmt.allocPrint(allocator, "{s}/swap.config", .{app_data_dir});
}

pub fn getOrInitConfigFile(allocator: std.mem.Allocator) !std.fs.File {
    const config_file = try getConfigFilePath(allocator);
    defer allocator.free(config_file);

    const swap_dir = std.fs.path.dirname(config_file) orelse return error.InvalidPath;

    var dir_exists = true;
    std.fs.accessAbsolute(swap_dir, .{ .mode = .read_only }) catch |err| {
        switch (err) {
            error.FileNotFound => {
                dir_exists = false;
            },
            else => return err,
        }
    };
    if (!dir_exists) {
        try std.fs.makeDirAbsolute(swap_dir);
    }

    var file_exists = true;
    std.fs.accessAbsolute(config_file, .{ .mode = .read_only }) catch |err| {
        switch (err) {
            error.FileNotFound => {
                file_exists = false;
            },
            else => return err,
        }
    };

    var file: std.fs.File = undefined;
    if (!file_exists) {
        file = try std.fs.createFileAbsolute(config_file, .{});
        const default_log_path = try getDefaultLogPath(allocator);
        var config = Config{
            .log_file_path = default_log_path,
        };
        defer config.deinit(allocator);
        // Write default config
        var buf: [1024]u8 = undefined;
        var fw = file.writer(&buf);
        var writer = &fw.interface;

        const config_str = try config.to_file(allocator);
        defer allocator.free(config_str);
        try writer.writeAll(config_str);
        try writer.flush();
    } else {
        file = try std.fs.openFileAbsolute(config_file, .{});
    }

    return file;
}
