//! Reconstructs the gcloud reauth (RAPT) session clock from gcloud's own logs.
//!
//! The clock anchors to the FIRST successful login after the last reauth
//! challenge; later logins within the same session do not reset it. Mirrors
//! ~/bin/gcloud-session-expiry.

const std = @import("std");
const Io = std.Io;
const sys = @import("sys.zig");

const parseStamp = sys.parseStamp;
const localParts = sys.localParts;

const scan_days = 3;
const default_hours = 8.0;
const login_marker = "You are now logged in as [";
const reauth_markers = [_][]const u8{ "Reauthentication failed", "reauth is required" };
const max_log_bytes: Io.Limit = .limited(4 << 20);

pub const Session = struct {
    anchor: i64,
    deadline: i64,
    minutes_left: i64,
};

fn sessionHours() f64 {
    const raw = sys.env("GCLOUD_SESSION_HOURS") orelse return default_hours;
    return std.fmt.parseFloat(f64, raw) catch default_hours;
}

fn containsAny(text: []const u8, needles: []const []const u8) bool {
    for (needles) |n| if (std.mem.indexOf(u8, text, n) != null) return true;
    return false;
}

const FileEvents = struct {
    first: ?i64 = null,
    last: ?i64 = null,
    login: bool = false,
    reauth: bool = false,
};

fn scanText(text: []const u8) FileEvents {
    var ev: FileEvents = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const stamp = parseStamp(line) orelse continue;
        if (ev.first == null) ev.first = stamp;
        ev.last = stamp;
    }
    ev.login = std.mem.indexOf(u8, text, login_marker) != null;
    ev.reauth = containsAny(text, &reauth_markers);
    return ev;
}

/// Anchor explicitly recorded by gcloud-force-reauth, which leaves no log trace.
fn recordedAnchor(gpa: std.mem.Allocator, io: Io) ?i64 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = sys.anchorPath(&buf) orelse return null;
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256)) catch return null;
    defer gpa.free(text);
    return parseStamp(std.mem.trim(u8, text, " \t\r\n"));
}

fn collect(gpa: std.mem.Allocator, io: Io, cfg: []const u8, cutoff: i64, logins: *std.ArrayList(i64), reauths: *std.ArrayList(i64)) !void {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const logs_path = try std.fmt.bufPrint(&path_buf, "{s}/logs", .{cfg});

    var logs = std.Io.Dir.cwd().openDir(io, logs_path, .{ .iterate = true }) catch return;
    defer logs.close(io);

    // Date-named dirs sort lexicographically, so a string compare is the cheap
    // way to skip the hundreds of older directories.
    const oldest = localParts(cutoff);
    var oldest_buf: [10]u8 = undefined;
    const oldest_name = try std.fmt.bufPrint(&oldest_buf, "{d:0>4}.{d:0>2}.{d:0>2}", .{
        @as(u32, @intCast(oldest.year)) + 1900,
        @as(u32, @intCast(oldest.mon)) + 1,
        @as(u32, @intCast(oldest.mday)),
    });

    var day_it = logs.iterate();
    while (try day_it.next(io)) |day| {
        if (day.kind != .directory) continue;
        if (day.name.len != 10) continue;
        if (std.mem.order(u8, day.name, oldest_name) == .lt) continue;

        var day_dir = logs.openDir(io, day.name, .{ .iterate = true }) catch continue;
        defer day_dir.close(io);

        var file_it = day_dir.iterate();
        while (try file_it.next(io)) |file| {
            if (!std.mem.endsWith(u8, file.name, ".log")) continue;
            const text = day_dir.readFileAlloc(io, file.name, gpa, max_log_bytes) catch continue;
            defer gpa.free(text);

            const ev = scanText(text);
            const last = ev.last orelse continue;
            if (last < cutoff) continue;
            if (ev.login) try logins.append(gpa, last);
            if (ev.reauth) try reauths.append(gpa, ev.first.?);
        }
    }
}

/// Earliest login later than the most recent reauth challenge.
fn anchorOf(logins: []const i64, reauths: []const i64, forced: ?i64) ?i64 {
    const last_reauth: ?i64 = if (reauths.len > 0) reauths[reauths.len - 1] else null;
    if (forced) |f| {
        if (last_reauth == null or f > last_reauth.?) return f;
    }
    for (logins) |t| {
        if (last_reauth == null or t > last_reauth.?) return t;
    }
    return null;
}

pub fn compute(gpa: std.mem.Allocator, io: Io) ?Session {
    var cfg_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cfg = sys.configDir(&cfg_buf) orelse return null;
    const now = sys.now();
    const cutoff = now - scan_days * std.time.s_per_day;

    var logins: std.ArrayList(i64) = .empty;
    defer logins.deinit(gpa);
    var reauths: std.ArrayList(i64) = .empty;
    defer reauths.deinit(gpa);

    collect(gpa, io, cfg, cutoff, &logins, &reauths) catch return null;
    std.mem.sort(i64, logins.items, {}, std.sort.asc(i64));
    std.mem.sort(i64, reauths.items, {}, std.sort.asc(i64));

    const anchor = anchorOf(logins.items, reauths.items, recordedAnchor(gpa, io)) orelse return null;
    const deadline = anchor + @as(i64, @intFromFloat(sessionHours() * 3600.0));
    return .{
        .anchor = anchor,
        .deadline = deadline,
        .minutes_left = @divFloor(deadline - now, 60),
    };
}

test "scanText takes first and last stamps and spots markers" {
    const ev = scanText(
        \\2026-09-21 10:00:00,001 DEBUG    root    reauth is required
        \\not a timestamped line
        \\2026-09-21 10:00:05,002 INFO     root    You are now logged in as [a@b.c]
        \\2026-09-21 10:00:09,003 DEBUG    root    done
    );
    try std.testing.expect(ev.login);
    try std.testing.expect(ev.reauth);
    try std.testing.expectEqual(parseStamp("2026-09-21 10:00:00").?, ev.first.?);
    try std.testing.expectEqual(parseStamp("2026-09-21 10:00:09").?, ev.last.?);
}

test "anchor is the first login after the last reauth" {
    const logins = [_]i64{ 100, 300, 400, 500 };
    const reauths = [_]i64{ 200, 350 };
    try std.testing.expectEqual(@as(i64, 400), anchorOf(&logins, &reauths, null).?);
}

test "anchor falls back to the earliest login when never challenged" {
    const logins = [_]i64{ 100, 300 };
    try std.testing.expectEqual(@as(i64, 100), anchorOf(&logins, &.{}, null).?);
}

test "recorded anchor wins only when newer than the last reauth" {
    const logins = [_]i64{400};
    const reauths = [_]i64{350};
    try std.testing.expectEqual(@as(i64, 380), anchorOf(&logins, &reauths, 380).?);
    try std.testing.expectEqual(@as(i64, 400), anchorOf(&logins, &reauths, 340).?);
}

test "no login after the last challenge means no anchor" {
    const logins = [_]i64{100};
    const reauths = [_]i64{200};
    try std.testing.expect(anchorOf(&logins, &reauths, null) == null);
}
