const std = @import("std");

const cache_path = ".config/gcloud/config-helper-cache.json";
const cache_threshold_ns: i128 = std.time.ns_per_s;

const CredentialCache = struct {
    credential: struct {
        token_expiry: []const u8,
    },
};

fn getCachePath(allocator: std.mem.Allocator) ![]u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    return std.fs.path.join(allocator, &.{ home, cache_path });
}

fn argsMatch(args: []const []const u8) bool {
    if (args.len != 4) return false;
    if (!std.mem.eql(u8, args[0], "config")) return false;
    if (!std.mem.eql(u8, args[1], "config-helper")) return false;
    if (!std.mem.eql(u8, args[2], "--format")) return false;
    if (!std.mem.eql(u8, args[3], "json")) return false;
    return true;
}

fn parseISO8601(s: []const u8) !i64 {
    var year: u16 = 0;
    var month: u8 = 0;
    var day: u8 = 0;
    var hour: u8 = 0;
    var minute: u8 = 0;
    var second: u8 = 0;
    
    if (s.len < 19) return error.InvalidFormat;
    
    year = try std.fmt.parseInt(u16, s[0..4], 10);
    if (s[4] != '-') return error.InvalidFormat;
    month = try std.fmt.parseInt(u8, s[5..7], 10);
    if (s[7] != '-') return error.InvalidFormat;
    day = try std.fmt.parseInt(u8, s[8..10], 10);
    if (s[10] != 'T') return error.InvalidFormat;
    hour = try std.fmt.parseInt(u8, s[11..13], 10);
    if (s[13] != ':') return error.InvalidFormat;
    minute = try std.fmt.parseInt(u8, s[14..16], 10);
    if (s[16] != ':') return error.InvalidFormat;
    second = try std.fmt.parseInt(u8, s[17..19], 10);
    
    var days_since_epoch: i64 = 0;
    var y: u16 = std.time.epoch.epoch_year;
    while (y < year) : (y += 1) {
        days_since_epoch += std.time.epoch.getDaysInYear(y);
    }
    
    const days_in_months = [12]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var m: u8 = 1;
    while (m < month) : (m += 1) {
        days_since_epoch += days_in_months[m - 1];
        if (m == 2 and std.time.epoch.isLeapYear(year)) {
            days_since_epoch += 1;
        }
    }
    
    days_since_epoch += day - 1;
    
    const seconds_since_epoch = days_since_epoch * std.time.epoch.secs_per_day +
        @as(i64, hour) * 3600 +
        @as(i64, minute) * 60 +
        @as(i64, second);
    
    return seconds_since_epoch;
}

fn execGcloud(allocator: std.mem.Allocator, args: []const []const u8, gcloud_path: []const u8) !noreturn {
    const argv = try allocator.alloc([]const u8, args.len);
    defer allocator.free(argv);
    
    argv[0] = gcloud_path;
    @memcpy(argv[1..], args[1..]);
    
    const result = std.process.execv(allocator, argv);
    std.debug.print("exec failed: {}\n", .{result});
    std.process.exit(1);
}

fn runGcloudAndCache(allocator: std.mem.Allocator, cache_file_path: []const u8, gcloud_path: []const u8, stdout: std.fs.File) !void {
    const argv = [_][]const u8{ gcloud_path, "config", "config-helper", "--format", "json" };
    
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &argv,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    
    if (result.term.Exited != 0) {
        std.fs.deleteFileAbsolute(cache_file_path) catch {};
        try std.fs.File.stderr().writeAll(result.stderr);
        std.process.exit(result.term.Exited);
    }
    
    const dir_path = std.fs.path.dirname(cache_file_path) orelse return error.InvalidPath;
    try std.fs.cwd().makePath(dir_path);
    
    const file = try std.fs.createFileAbsolute(cache_file_path, .{ .mode = 0o600 });
    defer file.close();
    try file.writeAll(result.stdout);
    
    try stdout.writeAll(result.stdout);
}

fn runMain(allocator: std.mem.Allocator, _: []const []const u8, gcloud_path: []const u8, cache_dir: []const u8, stdout: std.fs.File, now_ts: i64) !void {
    const cache_file_path = try std.fs.path.join(allocator, &.{ cache_dir, "config-helper-cache.json" });
    defer allocator.free(cache_file_path);
    
    const cache_file = std.fs.openFileAbsolute(cache_file_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            try runGcloudAndCache(allocator, cache_file_path, gcloud_path, stdout);
            return;
        }
        std.debug.print("failed to open cache: {}\n", .{err});
        std.process.exit(1);
    };
    defer cache_file.close();
    
    const cache_data = cache_file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        std.debug.print("failed to read cache file: {}\n", .{err});
        std.process.exit(1);
    };
    defer allocator.free(cache_data);
    
    const parsed = std.json.parseFromSlice(CredentialCache, allocator, cache_data, .{}) catch {
        try runGcloudAndCache(allocator, cache_file_path, gcloud_path, stdout);
        return;
    };
    defer parsed.deinit();
    
    const expiry_ts = parseISO8601(parsed.value.credential.token_expiry) catch {
        try runGcloudAndCache(allocator, cache_file_path, gcloud_path, stdout);
        return;
    };
    
    const until_expiry_ns = (expiry_ts - now_ts) * std.time.ns_per_s;
    
    if (until_expiry_ns > cache_threshold_ns) {
        try stdout.writeAll(cache_data);
    } else {
        try runGcloudAndCache(allocator, cache_file_path, gcloud_path, stdout);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    
    const user_args = args[1..];
    
    if (!argsMatch(user_args)) {
        try execGcloud(allocator, args, "gcloud-wrapped");
    }
    
    const cache_dir_path = blk: {
        const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
        break :blk try std.fs.path.join(allocator, &.{ home, ".config/gcloud" });
    };
    defer allocator.free(cache_dir_path);
    
    const now_ts: i64 = @intCast(@divFloor(std.time.nanoTimestamp(), std.time.ns_per_s));
    try runMain(allocator, user_args, "gcloud-wrapped", cache_dir_path, std.fs.File.stdout(), now_ts);
}

test "argsMatch with valid args" {
    const args = [_][]const u8{ "config", "config-helper", "--format", "json" };
    try std.testing.expect(argsMatch(&args));
}

test "argsMatch with invalid args - wrong length" {
    const args = [_][]const u8{ "config", "config-helper" };
    try std.testing.expect(!argsMatch(&args));
}

test "argsMatch with invalid args - wrong command" {
    const args = [_][]const u8{ "compute", "config-helper", "--format", "json" };
    try std.testing.expect(!argsMatch(&args));
}

test "parseISO8601 valid timestamp" {
    const ts = try parseISO8601("2025-01-15T10:30:45Z");
    try std.testing.expect(ts > 0);
}

test "parseISO8601 invalid format" {
    const result = parseISO8601("invalid");
    try std.testing.expectError(error.InvalidFormat, result);
}

test "integration: cache valid token" {
    const allocator = std.testing.allocator;
    
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    
    const cache_dir_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cache_dir_path);
    
    const gcloud_script_path = try std.fs.path.join(allocator, &.{ cache_dir_path, "mock-gcloud" });
    defer allocator.free(gcloud_script_path);
    
    const far_future = "2099-12-31T23:59:59Z";
    const mock_response = try std.fmt.allocPrint(allocator, 
        \\{{"credential": {{"token_expiry": "{s}"}}}}
    , .{far_future});
    defer allocator.free(mock_response);
    
    const script_content = try std.fmt.allocPrint(allocator,
        \\#!/bin/sh
        \\echo '{s}'
        \\
    , .{mock_response});
    defer allocator.free(script_content);
    
    {
        const script_file = try tmp_dir.dir.createFile("mock-gcloud", .{ .mode = 0o755 });
        defer script_file.close();
        try script_file.writeAll(script_content);
    }
    
    const stdout_path = try std.fs.path.join(allocator, &.{ cache_dir_path, "stdout.txt" });
    defer allocator.free(stdout_path);
    
    const stdout_file = try tmp_dir.dir.createFile("stdout.txt", .{ .read = true });
    defer stdout_file.close();
    
    const user_args = [_][]const u8{ "config", "config-helper", "--format", "json" };
    const now_ts = try parseISO8601("2025-01-01T00:00:00Z");
    
    try runMain(allocator, &user_args, gcloud_script_path, cache_dir_path, stdout_file, now_ts);
    
    const cache_file_path = try std.fs.path.join(allocator, &.{ cache_dir_path, "config-helper-cache.json" });
    defer allocator.free(cache_file_path);
    
    const cache_file_check = try std.fs.openFileAbsolute(cache_file_path, .{});
    defer cache_file_check.close();
    const cached_data = try cache_file_check.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(cached_data);
    
    try std.testing.expect(std.mem.indexOf(u8, cached_data, far_future) != null);
    
    try stdout_file.seekTo(0);
    const stdout_data = try stdout_file.readToEndAlloc(allocator, 1024);
    defer allocator.free(stdout_data);
    
    try std.testing.expect(std.mem.indexOf(u8, stdout_data, far_future) != null);
    
    const second_stdout_file = try tmp_dir.dir.createFile("stdout2.txt", .{ .read = true });
    defer second_stdout_file.close();
    
    try runMain(allocator, &user_args, gcloud_script_path, cache_dir_path, second_stdout_file, now_ts);
    
    try second_stdout_file.seekTo(0);
    const second_stdout_data = try second_stdout_file.readToEndAlloc(allocator, 1024);
    defer allocator.free(second_stdout_data);
    
    try std.testing.expectEqualStrings(stdout_data, second_stdout_data);
}
