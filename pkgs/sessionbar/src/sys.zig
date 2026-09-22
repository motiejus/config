//! Local-time and gcloud-config-path helpers.

const std = @import("std");

/// Set once from --debug; read by every module that traces.
pub var debug = false;

/// Darwin `struct tm`; callers get `Time` with the offsets already applied.
const CTm = extern struct {
    sec: c_int = 0,
    min: c_int = 0,
    hour: c_int = 0,
    mday: c_int = 0,
    mon: c_int = 0,
    year: c_int = 0,
    wday: c_int = 0,
    yday: c_int = 0,
    isdst: c_int = 0,
    gmtoff: c_long = 0,
    zone: ?[*:0]const u8 = null,
};

extern "c" fn mktime(tm: *CTm) c_long;
extern "c" fn localtime_r(clock: *const c_long, result: *CTm) ?*CTm;
extern "c" fn time(tloc: ?*c_long) c_long;

const weekdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };

pub const Time = struct {
    year: u16,
    mon: u8,
    mday: u8,
    hour: u8,
    min: u8,
    sec: u8,
    wday: u8,

    fn dayName(t: Time) []const u8 {
        return weekdays[t.wday];
    }
};

fn env(comptime name: [:0]const u8) ?[]const u8 {
    return std.mem.span(std.c.getenv(name.ptr) orelse return null);
}

pub fn now() i64 {
    return time(null);
}

/// Local wall-clock time as epoch seconds; `isdst = -1` lets libc resolve DST.
pub fn localToEpoch(year: u16, mon: u8, mday: u8, hour: u8, min: u8, sec: u8) ?i64 {
    var tm: CTm = .{
        .sec = sec,
        .min = min,
        .hour = hour,
        .mday = mday,
        .mon = @as(c_int, mon) - 1,
        .year = @as(c_int, year) - 1900,
        .isdst = -1,
    };
    const t = mktime(&tm);
    return if (t == -1) null else t;
}

pub fn localParts(epoch: i64) Time {
    const clock: c_long = epoch;
    var tm: CTm = .{};
    _ = localtime_r(&clock, &tm);
    return .{
        .year = @intCast(tm.year + 1900),
        .mon = @intCast(tm.mon + 1),
        .mday = @intCast(tm.mday),
        .hour = @intCast(tm.hour),
        .min = @intCast(tm.min),
        .sec = @intCast(tm.sec),
        .wday = @intCast(tm.wday),
    };
}

fn num(s: []const u8) ?u32 {
    return std.fmt.parseUnsigned(u32, s, 10) catch null;
}

/// Parses a leading `YYYY-MM-DD[ T]HH:MM:SS` in local time.
pub fn parseStamp(s: []const u8) ?i64 {
    if (s.len < 19) return null;
    if (s[4] != '-' or s[7] != '-' or s[13] != ':' or s[16] != ':') return null;
    if (s[10] != ' ' and s[10] != 'T') return null;
    return localToEpoch(
        @intCast(num(s[0..4]) orelse return null),
        @intCast(num(s[5..7]) orelse return null),
        @intCast(num(s[8..10]) orelse return null),
        @intCast(num(s[11..13]) orelse return null),
        @intCast(num(s[14..16]) orelse return null),
        @intCast(num(s[17..19]) orelse return null),
    );
}

/// `EEE HH:MM`, the human-facing form used in menus and CLI output.
pub fn formatDayTime(buf: []u8, epoch: i64) ![]const u8 {
    const t = localParts(epoch);
    return std.fmt.bufPrint(buf, "{s} {d:0>2}:{d:0>2}", .{ t.dayName(), t.hour, t.min });
}

pub fn configDir(buf: []u8) ?[]const u8 {
    if (env("CLOUDSDK_CONFIG")) |v| if (v.len > 0) return v;
    const home = env("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/gcloud", .{home}) catch null;
}

test "parseStamp round-trips through local time" {
    const t = localParts(parseStamp("2026-09-21 12:13:27,725 DEBUG    root").?);
    try std.testing.expectEqual(@as(u16, 2026), t.year);
    try std.testing.expectEqual(@as(u8, 9), t.mon);
    try std.testing.expectEqual(@as(u8, 21), t.mday);
    try std.testing.expectEqual(@as(u8, 12), t.hour);
    try std.testing.expectEqual(@as(u8, 13), t.min);
    try std.testing.expectEqual(@as(u8, 27), t.sec);
}

test "parseStamp accepts the ISO separator and rejects junk" {
    try std.testing.expect(parseStamp("2026-09-21T12:13:27") != null);
    try std.testing.expect(parseStamp("Traceback (most recent call last)") == null);
    try std.testing.expect(parseStamp("2026-09-21") == null);
    try std.testing.expect(parseStamp("20x6-09-21 12:13:27") == null);
}

test "formatDayTime renders the weekday" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Mon 20:14", try formatDayTime(&buf, parseStamp("2026-09-21T20:14:01").?));
}
