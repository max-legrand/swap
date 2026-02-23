const std = @import("std");

pub const HistoryEntry = struct {
    app_name: []const u8,
    timestamp: i64,
};

const max_entries_per_query = 10;

pub const History = struct {
    entries: std.StringHashMap(std.ArrayList(HistoryEntry)),
    allocator: std.mem.Allocator,
    file_path: []const u8,

    pub fn init(allocator: std.mem.Allocator) !History {
        const app_data_dir = try std.fs.getAppDataDir(allocator, "swap");
        defer allocator.free(app_data_dir);
        const file_path = try std.fmt.allocPrint(allocator, "{s}/history", .{app_data_dir});

        var self: History = .{
            .entries = std.StringHashMap(std.ArrayList(HistoryEntry)).init(allocator),
            .allocator = allocator,
            .file_path = file_path,
        };
        self.loadFromDisk() catch {};
        return self;
    }

    pub fn record(self: *History, term: []const u8, app_name: []const u8) !void {
        const now = std.time.milliTimestamp();

        const exists = self.entries.contains(term);
        if (!exists) {
            const key = try self.allocator.dupe(u8, term);
            try self.entries.put(key, std.ArrayList(HistoryEntry).empty);
        }
        const list = self.entries.getPtr(term).?;
        for (list.items) |*entry| {
            if (std.mem.eql(u8, entry.app_name, app_name)) {
                entry.timestamp = now;
                try self.saveToDisk();
                return;
            }
        }

        try list.append(self.allocator, .{
            .app_name = try self.allocator.dupe(u8, app_name),
            .timestamp = now,
        });

        if (list.items.len > max_entries_per_query) {
            // Remove the oldest entry
            var oldest_idx: usize = 0;
            for (list.items, 0..) |entry, i| {
                if (entry.timestamp < list.items[oldest_idx].timestamp) {
                    oldest_idx = i;
                }
            }
            self.allocator.free(list.items[oldest_idx].app_name);
            _ = list.orderedRemove(oldest_idx);
        }
        try self.saveToDisk();
    }

    pub fn getRecencyBonus(self: *History, query: []const u8, app_name: []const u8) i32 {
        const list = self.entries.get(query) orelse return 0;
        const now = std.time.milliTimestamp();

        for (list.items) |entry| {
            if (std.mem.eql(u8, entry.app_name, app_name)) {
                const age_ms = now - entry.timestamp;
                const age_hours = @divTrunc(age_ms, 3_600_000);

                if (age_hours < 1) return -500;
                if (age_hours < 24) return -300;
                if (age_hours < 168) return -100;
                return -50;
            }
        }
        return 0;
    }

    fn loadFromDisk(self: *History) !void {
        const file = try std.fs.openFileAbsolute(self.file_path, .{ .mode = .read_only });
        defer file.close();

        var buf: [1024]u8 = undefined;
        var reader = file.reader(&buf);

        const lines = try reader.interface.allocRemaining(self.allocator, .unlimited);
        defer self.allocator.free(lines);

        var iter = std.mem.splitScalar(u8, lines, '\n');
        while (iter.next()) |line| {
            if (line.len == 0) continue;
            var line_iter = std.mem.splitScalar(u8, line, '\t');
            const term = line_iter.next();
            const app_name = line_iter.next();
            const timestamp = line_iter.next();
            if (term == null or app_name == null or timestamp == null) continue;
            const duped_term = try self.allocator.dupe(u8, term.?);
            const contains_key = self.entries.contains(duped_term);
            if (!contains_key) {
                try self.entries.put(duped_term, std.ArrayList(HistoryEntry).empty);
            } else {
                self.allocator.free(duped_term);
            }
            const entry = self.entries.getPtr(term.?).?;
            try entry.append(self.allocator, .{
                .app_name = try self.allocator.dupe(u8, app_name.?),
                .timestamp = try std.fmt.parseInt(i64, timestamp.?, 10),
            });
        }
    }

    pub fn saveToDisk(self: *History) !void {
        const file = try std.fs.createFileAbsolute(self.file_path, .{});
        defer file.close();

        var buf: [1024]u8 = undefined;
        var writer = file.writer(&buf);

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |value| {
                try writer.interface.print("{s}\t{s}\t{d}\n", .{
                    .term = entry.key_ptr.*,
                    .app_name = value.app_name,
                    .timestamp = value.timestamp,
                });
            }
        }
        try writer.interface.flush();
    }

    pub fn deinit(self: *History) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |value| {
                self.allocator.free(value.app_name);
            }
            entry.value_ptr.deinit(self.allocator);
        }
        self.* = undefined;
    }
};
