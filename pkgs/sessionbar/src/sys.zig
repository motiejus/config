//! Local-time and gcloud-config-path helpers shared by the app and the CLI.

const std = @import("std");

pub const Tm = extern struct {
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

extern "c" fn mktime(tm: *Tm) c_long;
extern "c" fn localtime_r(clock: *const c_long, result: *Tm) ?*Tm;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn time(tloc: ?*c_long) c_long;

pub const weekdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };

pub fn env(comptime name: [:0]const u8) ?[]const u8 {
    return std.mem.span(getenv(name.ptr) orelse return null);
}

pub fn now() i64 {
    return time(null);
}

/// Local wall-clock time as epoch seconds; `isdst = -1` lets libc resolve DST.
pub fn localToEpoch(year: u16, mon: u8, mday: u8, hour: u8, min: u8, sec: u8) ?i64 {
    var tm: Tm = .{
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

pub fn localParts(epoch: i64) Tm {
    const clock: c_long = epoch;
    var tm: Tm = .{};
    _ = localtime_r(&clock, &tm);
    return tm;
}

fn digits(s: []const u8) ?u32 {
    for (s) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseUnsigned(u32, s, 10) catch null;
}

/// Parses a leading `YYYY-MM-DD[ T]HH:MM:SS` in local time.
pub fn parseStamp(s: []const u8) ?i64 {
    if (s.len < 19) return null;
    if (s[4] != '-' or s[7] != '-' or s[13] != ':' or s[16] != ':') return null;
    if (s[10] != ' ' and s[10] != 'T') return null;
    return localToEpoch(
        @intCast(digits(s[0..4]) orelse return null),
        @intCast(digits(s[5..7]) orelse return null),
        @intCast(digits(s[8..10]) orelse return null),
        @intCast(digits(s[11..13]) orelse return null),
        @intCast(digits(s[14..16]) orelse return null),
        @intCast(digits(s[17..19]) orelse return null),
    );
}

/// `YYYY-MM-DDTHH:MM:SS` local, the format the anchor file is exchanged in.
pub fn formatStamp(buf: []u8, epoch: i64) ![]const u8 {
    const tm = localParts(epoch);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u32, @intCast(tm.year)) + 1900,
        @as(u32, @intCast(tm.mon)) + 1,
        @as(u32, @intCast(tm.mday)),
        @as(u32, @intCast(tm.hour)),
        @as(u32, @intCast(tm.min)),
        @as(u32, @intCast(tm.sec)),
    });
}

pub fn configDir(buf: []u8) ?[]const u8 {
    if (env("CLOUDSDK_CONFIG")) |v| if (v.len > 0) return v;
    const home = env("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/gcloud", .{home}) catch null;
}

pub fn anchorPath(buf: []u8) ?[]const u8 {
    var cfg_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cfg = configDir(&cfg_buf) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.reauth_anchor", .{cfg}) catch null;
}

test "parseStamp round-trips through local time" {
    const t = parseStamp("2026-09-21 12:13:27,725 DEBUG    root").?;
    const tm = localParts(t);
    try std.testing.expectEqual(@as(c_int, 126), tm.year);
    try std.testing.expectEqual(@as(c_int, 8), tm.mon);
    try std.testing.expectEqual(@as(c_int, 21), tm.mday);
    try std.testing.expectEqual(@as(c_int, 12), tm.hour);
    try std.testing.expectEqual(@as(c_int, 13), tm.min);
    try std.testing.expectEqual(@as(c_int, 27), tm.sec);
}

test "parseStamp accepts the ISO separator and rejects junk" {
    try std.testing.expect(parseStamp("2026-09-21T12:13:27") != null);
    try std.testing.expect(parseStamp("Traceback (most recent call last)") == null);
    try std.testing.expect(parseStamp("2026-09-21") == null);
    try std.testing.expect(parseStamp("20x6-09-21 12:13:27") == null);
}

test "formatStamp is the inverse of parseStamp" {
    var buf: [32]u8 = undefined;
    const epoch = parseStamp("2026-09-21T20:14:01").?;
    try std.testing.expectEqualStrings("2026-09-21T20:14:01", try formatStamp(&buf, epoch));
}
