//! Reconstructs the gcloud reauth (RAPT) session clock from gcloud's own logs.
//!
//! The clock anchors to the FIRST successful login after the last reauth
//! challenge; later logins within the same session do not reset it.
//!
//! gcloud log files are immutable once closed, so `Scanner` parses each file
//! at most once and keeps the extracted events across rescans.

const std = @import("std");
const Io = std.Io;
const sys = @import("sys.zig");

const scan_days = 3;
const session_seconds: i64 = 8 * 60 * 60;
const login_marker = "You are now logged in as";
const reauth_markers = [_][]const u8{ "Reauthentication failed", "reauth is required" };

/// How many of the newest day buckets may still be written to. Two, so a login
/// that straddles midnight is not sealed in yesterday's bucket.
const live_days = 2;

pub const Session = struct {
    deadline: i64,
    /// Set while a forced re-auth has claimed a later deadline that the logs
    /// have not yet corroborated; `deadline` stays on the pessimistic value.
    unverified: ?Unverified = null,
};

pub const Unverified = struct {
    forced_at: i64,
    until: i64,
};

/// What one log file contributes: `login`/`reauth` are the stamps the Python
/// reference picked (last stamp for a login, first for a reauth challenge).
const Record = struct {
    last: i64,
    login: ?i64,
    reauth: ?i64,
};

/// gcloud holds a log open across the verification-code prompt and only writes
/// "You are now logged in as" at the very end, so elapsed time says nothing
/// about whether a file is complete. A file is final once it has yielded a
/// marker; until then, one in a live bucket is re-stat'ed and re-read whenever
/// (mtime, size) moves.
const FileState = struct {
    final: bool,
    mtime_ns: i128,
    size: u64,
};

const Day = struct {
    files: std.StringHashMapUnmanaged(FileState) = .empty,
    records: std.ArrayList(Record) = .empty,

    fn deinit(d: *Day, gpa: std.mem.Allocator) void {
        var it = d.files.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        d.files.deinit(gpa);
        d.records.deinit(gpa);
    }
};

pub const Scanner = struct {
    gpa: std.mem.Allocator,
    days: std.StringArrayHashMapUnmanaged(Day) = .empty,
    /// Files parsed by the most recent `scan`; the steady state is zero.
    last_parsed: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Scanner {
        return .{ .gpa = gpa };
    }

    pub fn deinit(s: *Scanner) void {
        for (s.days.values()) |*d| d.deinit(s.gpa);
        for (s.days.keys()) |k| s.gpa.free(k);
        s.days.deinit(s.gpa);
    }

    fn dropExpired(s: *Scanner, oldest: []const u8) void {
        var i: usize = 0;
        while (i < s.days.count()) {
            if (std.mem.order(u8, s.days.keys()[i], oldest) == .lt) {
                const key = s.days.keys()[i];
                s.days.values()[i].deinit(s.gpa);
                s.days.orderedRemoveAt(i);
                s.gpa.free(key);
            } else i += 1;
        }
    }

    fn ingest(s: *Scanner, io: Io, day: *Day, dir: Io.Dir, name: []const u8, live: bool) !void {
        const prev = day.files.getPtr(name);
        if (prev) |e| {
            if (e.final) return;
            // Liveness first: a bucket that has aged out of the live window can
            // no longer be appended to, so seal it without another stat.
            if (!live) {
                e.final = true;
                return;
            }
        }

        const stat = dir.statFile(io, name, .{}) catch return;
        if (prev) |e| if (e.mtime_ns == stat.mtime.nanoseconds and e.size == stat.size) return;

        const text = try dir.readFileAlloc(io, name, s.gpa, .unlimited);
        defer s.gpa.free(text);
        s.last_parsed += 1;

        // Recording before the bookkeeping means a failure below duplicates an
        // event rather than losing it; duplicates are harmless, as the anchor
        // is the earliest login after max(reauth).
        const rec = scanText(text);
        if (rec) |r| if (r.login != null or r.reauth != null) try day.records.append(s.gpa, r);

        // Only a LOGIN seals a live file. A reauth challenge is written while
        // the log is still open, and the login marker lands after it.
        const state: FileState = .{
            .final = (if (rec) |r| r.login != null else false) or !live,
            .mtime_ns = stat.mtime.nanoseconds,
            .size = stat.size,
        };
        if (prev) |e| {
            e.* = state;
            return;
        }
        const key = try s.gpa.dupe(u8, name);
        errdefer s.gpa.free(key);
        try day.files.put(s.gpa, key, state);
    }

    pub fn scan(s: *Scanner, io: Io) ?Session {
        var cfg_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const cfg = sys.configDir(&cfg_buf) orelse return null;
        return s.scanAt(io, cfg, sys.now());
    }

    /// Lists the in-window day directories and parses only files not yet seen.
    /// `now` is a parameter so tests can drive the scan window and live buckets.
    pub fn scanAt(s: *Scanner, io: Io, cfg: []const u8, now: i64) ?Session {
        const cutoff = now - scan_days * std.time.s_per_day;
        s.last_parsed = 0;

        var oldest_buf: [10]u8 = undefined;
        const oldest = dayName(&oldest_buf, cutoff) catch return null;
        s.dropExpired(oldest);

        // Only the newest `live_days` buckets can still be appended to.
        var live_buf: [live_days][10]u8 = undefined;
        var live: [live_days][]const u8 = undefined;
        for (0..live_days) |i| {
            live[i] = dayName(&live_buf[i], now - @as(i64, @intCast(i)) * std.time.s_per_day) catch return null;
        }

        s.collect(io, cfg, oldest, &live) catch {};
        return s.resolve(io, cfg, now, cutoff);
    }

    fn collect(s: *Scanner, io: Io, cfg: []const u8, oldest: []const u8, live: []const []const u8) !void {
        var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const logs_path = try std.fmt.bufPrint(&path_buf, "{s}/logs", .{cfg});
        var logs = Io.Dir.cwd().openDir(io, logs_path, .{ .iterate = true }) catch return;
        defer logs.close(io);

        var day_it = logs.iterate();
        while (try day_it.next(io)) |entry| {
            if (entry.kind != .directory or entry.name.len != 10) continue;
            // Date-named dirs sort lexicographically, so a string compare is
            // the cheap way to skip the hundreds of older directories.
            if (std.mem.order(u8, entry.name, oldest) == .lt) continue;

            const gop = try s.days.getOrPut(s.gpa, entry.name);
            if (!gop.found_existing) {
                gop.key_ptr.* = try s.gpa.dupe(u8, entry.name);
                gop.value_ptr.* = .{};
            }
            const day = gop.value_ptr;

            var is_live = false;
            for (live) |l| {
                if (std.mem.eql(u8, l, entry.name)) is_live = true;
            }

            var day_dir = logs.openDir(io, entry.name, .{ .iterate = true }) catch continue;
            defer day_dir.close(io);

            var file_it = day_dir.iterate();
            while (try file_it.next(io)) |file| {
                if (!std.mem.endsWith(u8, file.name, ".log")) continue;
                s.ingest(io, day, day_dir, file.name, is_live) catch continue;
            }
        }
    }

    fn resolve(s: *Scanner, io: Io, cfg: []const u8, now: i64, cutoff: i64) ?Session {
        var logins: std.ArrayList(i64) = .empty;
        defer logins.deinit(s.gpa);
        var reauths: std.ArrayList(i64) = .empty;
        defer reauths.deinit(s.gpa);

        for (s.days.values()) |day| {
            for (day.records.items) |r| {
                if (r.last < cutoff) continue;
                if (r.login) |t| logins.append(s.gpa, t) catch {};
                if (r.reauth) |t| reauths.append(s.gpa, t) catch {};
            }
        }
        std.mem.sort(i64, logins.items, {}, std.sort.asc(i64));
        std.mem.sort(i64, reauths.items, {}, std.sort.asc(i64));

        return decide(logins.items, reauths.items, recordedAnchor(s.gpa, io, cfg), now, cutoff);
    }
};

fn dayName(buf: *[10]u8, epoch: i64) ![]const u8 {
    const d = sys.localParts(epoch);
    return std.fmt.bufPrint(buf, "{d:0>4}.{d:0>2}.{d:0>2}", .{ d.year, d.mon, d.mday });
}

fn scanText(text: []const u8) ?Record {
    var first: ?i64 = null;
    var last: ?i64 = null;
    var login = false;
    var reauth = false;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!login and std.mem.indexOf(u8, line, login_marker) != null) login = true;
        if (!reauth) {
            for (reauth_markers) |m| {
                if (std.mem.indexOf(u8, line, m) != null) {
                    reauth = true;
                    break;
                }
            }
        }
        const stamp = sys.parseStamp(line) orelse continue;
        if (first == null) first = stamp;
        last = stamp;
    }

    return .{
        .last = last orelse return null,
        .login = if (login) last else null,
        .reauth = if (reauth) first else null,
    };
}

/// Anchor explicitly recorded by gcloud-force-reauth, which leaves no log trace.
fn recordedAnchor(gpa: std.mem.Allocator, io: Io, cfg: []const u8) ?i64 {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path = sys.anchorPath(&buf, cfg) orelse return null;
    const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256)) catch return null;
    defer gpa.free(text);
    return sys.parseStamp(std.mem.trim(u8, text, " \t\r\n"));
}

/// Earliest login later than the most recent reauth challenge.
fn logAnchor(logins: []const i64, last_reauth: ?i64) ?i64 {
    for (logins) |t| {
        if (last_reauth == null or t > last_reauth.?) return t;
    }
    return null;
}

/// A forced re-auth claims a later deadline than the logs can prove. Until the
/// log-derived deadline actually passes we show the pessimistic one, so an
/// SSO-satisfied "forced" login cannot silently buy 8 hours it never got.
fn decide(logins: []const i64, reauths: []const i64, forced: ?i64, now: i64, cutoff: i64) ?Session {
    const last_reauth: ?i64 = if (reauths.len > 0) reauths[reauths.len - 1] else null;

    // Stale or superseded anchor files are ignored outright.
    var file: ?i64 = forced;
    if (file) |f| {
        if (f < cutoff) file = null;
        if (last_reauth) |r| if (f <= r) {
            file = null;
        };
    }

    const log_deadline: ?i64 = if (logAnchor(logins, last_reauth)) |a| a + session_seconds else null;
    const file_deadline: ?i64 = if (file) |f| f + session_seconds else null;

    const l = log_deadline orelse {
        const f = file_deadline orelse return null;
        return .{ .deadline = f };
    };
    const f = file_deadline orelse return .{ .deadline = l };
    if (f <= l) return .{ .deadline = l };

    // Past the pessimistic deadline with no fresh challenge: trust the forced one.
    if (now >= l) return .{ .deadline = f };
    return .{ .deadline = l, .unverified = .{ .forced_at = file.?, .until = l } };
}

const hour = 3600;

test "scanText takes first and last stamps and spots markers" {
    const rec = scanText(
        \\2026-09-21 10:00:00,001 DEBUG    root    reauth is required
        \\not a timestamped line
        \\2026-09-21 10:00:05,002 INFO     root    You are now logged in as [a@b.c]
        \\2026-09-21 10:00:09,003 DEBUG    root    done
    ).?;
    try std.testing.expectEqual(sys.parseStamp("2026-09-21 10:00:09").?, rec.last);
    try std.testing.expectEqual(sys.parseStamp("2026-09-21 10:00:09").?, rec.login.?);
    try std.testing.expectEqual(sys.parseStamp("2026-09-21 10:00:00").?, rec.reauth.?);
}

test "scanText ignores files with no timestamps" {
    try std.testing.expect(scanText("You are now logged in as [a@b.c]\n") == null);
}

test "anchor is the first login after the last reauth" {
    const s = decide(&.{ 100, 300, 400, 500 }, &.{ 200, 350 }, null, 400, 0).?;
    try std.testing.expectEqual(@as(i64, 400 + 8 * hour), s.deadline);
    try std.testing.expect(s.unverified == null);
}

test "anchor falls back to the earliest login when never challenged" {
    try std.testing.expectEqual(@as(i64, 100 + 8 * hour), decide(&.{ 100, 300 }, &.{}, null, 100, 0).?.deadline);
}

test "no login after the last challenge means no session" {
    try std.testing.expect(decide(&.{100}, &.{200}, null, 300, 0) == null);
}

test "a reauth newer than the forced anchor drops it" {
    const s = decide(&.{400}, &.{350}, 340, 400, 0).?;
    try std.testing.expectEqual(@as(i64, 400 + 8 * hour), s.deadline);
    try std.testing.expect(s.unverified == null);
}

test "C4a: a forced anchor older than the scan window is ignored" {
    const cutoff: i64 = 1000;
    const s = decide(&.{2000}, &.{}, 500, 2000, cutoff).?;
    try std.testing.expectEqual(@as(i64, 2000 + 8 * hour), s.deadline);
    try std.testing.expect(s.unverified == null);
}

test "C4a: a stale forced anchor cannot outrank a later plain login" {
    // Regression: with no reauth in the window the file anchor used to win at
    // any age, pinning the display to a long-expired deadline.
    const cutoff: i64 = 1000;
    const s = decide(&.{5000}, &.{}, 100, 5000, cutoff).?;
    try std.testing.expectEqual(@as(i64, 5000 + 8 * hour), s.deadline);
}

test "C4b: a fresh forced anchor stays pessimistic until the log deadline passes" {
    const login: i64 = 1000;
    const forced: i64 = 2000; // later, so it claims a later deadline
    const l = login + 8 * hour;
    const s = decide(&.{login}, &.{}, forced, login + 60, 0).?;
    try std.testing.expectEqual(l, s.deadline);
    try std.testing.expectEqual(forced, s.unverified.?.forced_at);
    try std.testing.expectEqual(l, s.unverified.?.until);
}

test "C4b: the forced anchor takes over once the log deadline is reached" {
    const login: i64 = 1000;
    const forced: i64 = 2000;
    const l = login + 8 * hour;
    const s = decide(&.{login}, &.{}, forced, l, 0).?;
    try std.testing.expectEqual(forced + 8 * hour, s.deadline);
    try std.testing.expect(s.unverified == null);
}

test "a forced anchor no later than the logs changes nothing" {
    const s = decide(&.{2000}, &.{}, 1500, 2000, 0).?;
    try std.testing.expectEqual(@as(i64, 2000 + 8 * hour), s.deadline);
    try std.testing.expect(s.unverified == null);
}

test "a forced anchor with no usable login is used directly" {
    try std.testing.expectEqual(@as(i64, 2000 + 8 * hour), decide(&.{}, &.{}, 2000, 2000, 0).?.deadline);
}

test "C1: a rescan over an unchanged tree parses nothing" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var root_buf: [64]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "/tmp/sessionbar-scan-test-{d}", .{sys.now()});
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};

    // Anchor the fixture to today so it lands inside the 3-day window.
    const now = sys.now();
    const t = sys.localParts(now);
    var day_buf: [128]u8 = undefined;
    const day = try std.fmt.bufPrint(&day_buf, "{s}/logs/{d:0>4}.{d:0>2}.{d:0>2}", .{ root, t.year, t.mon, t.mday });
    try cwd.createDirPath(io, day);

    var stamp_buf: [32]u8 = undefined;
    const stamp = try sys.formatStamp(&stamp_buf, now - 3600);
    var body_buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "{s} INFO root You are now logged in as [a@b.c]\n", .{stamp});

    var path_buf: [192]u8 = undefined;
    for ([_][]const u8{ "a.log", "b.log" }) |name| {
        try cwd.writeFile(io, .{
            .sub_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ day, name }),
            .data = body,
        });
    }

    var scanner: Scanner = .init(gpa);
    defer scanner.deinit();

    const first = scanner.scanAt(io, root, now + 10);
    try std.testing.expectEqual(@as(usize, 2), scanner.last_parsed);
    try std.testing.expect(first != null);

    const second = scanner.scanAt(io, root, now + 11);
    try std.testing.expectEqual(@as(usize, 0), scanner.last_parsed);
    try std.testing.expectEqual(first.?.deadline, second.?.deadline);

    // A newly appeared file is picked up without re-reading the old ones.
    try cwd.writeFile(io, .{
        .sub_path = try std.fmt.bufPrint(&path_buf, "{s}/c.log", .{day}),
        .data = body,
    });
    _ = scanner.scanAt(io, root, now + 12);
    try std.testing.expectEqual(@as(usize, 1), scanner.last_parsed);
}

test "F1: a log that gains its marker after a rescan is re-read" {
    // gcloud holds the log open across the code prompt (the real
    // 14.49.02.071070.log has a 19s gap), so the marker lands long after the
    // first rescan sees the file.
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var root_buf: [64]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "/tmp/sessionbar-f1-test-{d}", .{sys.now()});
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};

    const now = sys.now();
    const t0 = sys.localParts(now);
    var day_buf: [128]u8 = undefined;
    const day = try std.fmt.bufPrint(&day_buf, "{s}/logs/{d:0>4}.{d:0>2}.{d:0>2}", .{ root, t0.year, t0.mon, t0.mday });
    try cwd.createDirPath(io, day);

    var path_buf: [192]u8 = undefined;
    const log = try std.fmt.bufPrint(&path_buf, "{s}/a.log", .{day});

    var stamp_buf: [32]u8 = undefined;
    var body_buf: [512]u8 = undefined;
    const opened = try std.fmt.bufPrint(&body_buf, "{s} DEBUG root Go to the following link\n", .{
        try sys.formatStamp(&stamp_buf, now - 3600),
    });
    try cwd.writeFile(io, .{ .sub_path = log, .data = opened });

    var scanner: Scanner = .init(gpa);
    defer scanner.deinit();

    // Mid-login: the file exists, has no marker, and yields no session.
    try std.testing.expect(scanner.scanAt(io, root, now) == null);
    try std.testing.expectEqual(@as(usize, 1), scanner.last_parsed);

    // A rescan while nothing changed must not seal it.
    try std.testing.expect(scanner.scanAt(io, root, now + 1) == null);
    try std.testing.expectEqual(@as(usize, 0), scanner.last_parsed);

    // gcloud finally writes the marker; (mtime, size) move.
    var full_buf: [1024]u8 = undefined;
    var stamp2: [32]u8 = undefined;
    const full = try std.fmt.bufPrint(&full_buf, "{s}{s} INFO root You are now logged in as [a@b.c]\n", .{
        opened,
        try sys.formatStamp(&stamp2, now - 3580),
    });
    try cwd.writeFile(io, .{ .sub_path = log, .data = full });

    const found = scanner.scanAt(io, root, now + 2);
    try std.testing.expectEqual(@as(usize, 1), scanner.last_parsed);
    try std.testing.expect(found != null);
    try std.testing.expectEqual((now - 3580) + 8 * hour, found.?.deadline);

    // Now that it has a marker it is final: no further reads.
    _ = scanner.scanAt(io, root, now + 3);
    try std.testing.expectEqual(@as(usize, 0), scanner.last_parsed);
}

test "F1: marker-less files in sealed buckets are not re-stat'ed" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var root_buf: [64]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "/tmp/sessionbar-seal-test-{d}", .{sys.now()});
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};

    // Two days back is outside the live window but inside the 3-day scan window.
    const now = sys.now();
    const old = sys.localParts(now - 2 * std.time.s_per_day);
    var day_buf: [128]u8 = undefined;
    const day = try std.fmt.bufPrint(&day_buf, "{s}/logs/{d:0>4}.{d:0>2}.{d:0>2}", .{ root, old.year, old.mon, old.mday });
    try cwd.createDirPath(io, day);

    var path_buf: [192]u8 = undefined;
    var stamp_buf: [32]u8 = undefined;
    var body_buf: [256]u8 = undefined;
    const log = try std.fmt.bufPrint(&path_buf, "{s}/a.log", .{day});
    try cwd.writeFile(io, .{
        .sub_path = log,
        .data = try std.fmt.bufPrint(&body_buf, "{s} DEBUG root no marker here\n", .{
            try sys.formatStamp(&stamp_buf, now - 2 * std.time.s_per_day),
        }),
    });

    var scanner: Scanner = .init(gpa);
    defer scanner.deinit();
    _ = scanner.scanAt(io, root, now);
    try std.testing.expectEqual(@as(usize, 1), scanner.last_parsed);

    // Sealed: even a change is ignored, because the bucket cannot be live.
    var more: [512]u8 = undefined;
    var stamp2: [32]u8 = undefined;
    try cwd.writeFile(io, .{
        .sub_path = log,
        .data = try std.fmt.bufPrint(&more, "{s} INFO root You are now logged in as [a@b.c]\n", .{
            try sys.formatStamp(&stamp2, now - 2 * std.time.s_per_day),
        }),
    });
    _ = scanner.scanAt(io, root, now + 1);
    try std.testing.expectEqual(@as(usize, 0), scanner.last_parsed);
}

test "F1: yesterday's bucket is still live, so a midnight login is not sealed" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var root_buf: [64]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "/tmp/sessionbar-live2-test-{d}", .{sys.now()});
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};

    const now = sys.now();
    const yday = now - std.time.s_per_day;
    const d = sys.localParts(yday);
    var day_buf: [128]u8 = undefined;
    const day = try std.fmt.bufPrint(&day_buf, "{s}/logs/{d:0>4}.{d:0>2}.{d:0>2}", .{ root, d.year, d.mon, d.mday });
    try cwd.createDirPath(io, day);

    var path_buf: [192]u8 = undefined;
    const log = try std.fmt.bufPrint(&path_buf, "{s}/a.log", .{day});
    var stamp_buf: [32]u8 = undefined;
    var body: [512]u8 = undefined;
    try cwd.writeFile(io, .{
        .sub_path = log,
        .data = try std.fmt.bufPrint(&body, "{s} DEBUG root Go to the following link\n", .{
            try sys.formatStamp(&stamp_buf, yday),
        }),
    });

    var scanner: Scanner = .init(gpa);
    defer scanner.deinit();
    try std.testing.expect(scanner.scanAt(io, root, now) == null);
    try std.testing.expectEqual(@as(usize, 1), scanner.last_parsed);

    // The login lands after midnight but gcloud still appends to yesterday's file.
    var full: [1024]u8 = undefined;
    var stamp2: [32]u8 = undefined;
    try cwd.writeFile(io, .{
        .sub_path = log,
        .data = try std.fmt.bufPrint(&full, "{s} INFO root You are now logged in as [a@b.c]\n", .{
            try sys.formatStamp(&stamp2, yday + 60),
        }),
    });
    const found = scanner.scanAt(io, root, now + 1);
    try std.testing.expectEqual(@as(usize, 1), scanner.last_parsed);
    try std.testing.expect(found != null);
}

test "a reauth marker does not seal a live log before its login arrives" {
    // gcloud writes the challenge into the still-open log and the login marker
    // only after the browser round trip; sealing on the reauth loses the login.
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var root_buf: [64]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "/tmp/sessionbar-reauthseal-{d}", .{sys.now()});
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};

    const now = sys.now();
    const d = sys.localParts(now);
    var day_buf: [128]u8 = undefined;
    const day = try std.fmt.bufPrint(&day_buf, "{s}/logs/{d:0>4}.{d:0>2}.{d:0>2}", .{ root, d.year, d.mon, d.mday });
    try cwd.createDirPath(io, day);

    var path_buf: [192]u8 = undefined;
    const log = try std.fmt.bufPrint(&path_buf, "{s}/a.log", .{day});

    var s1: [32]u8 = undefined;
    var challenge_buf: [256]u8 = undefined;
    const challenge = try std.fmt.bufPrint(&challenge_buf, "{s} DEBUG root reauth is required\n", .{
        try sys.formatStamp(&s1, now - 3600),
    });
    try cwd.writeFile(io, .{ .sub_path = log, .data = challenge });

    var scanner: Scanner = .init(gpa);
    defer scanner.deinit();

    // Challenge seen, no login yet: no session, and the file must stay open.
    try std.testing.expect(scanner.scanAt(io, root, now) == null);
    try std.testing.expectEqual(@as(usize, 1), scanner.last_parsed);

    // The login lands in the same file after the browser round trip.
    var s2: [32]u8 = undefined;
    var full_buf: [512]u8 = undefined;
    try cwd.writeFile(io, .{
        .sub_path = log,
        .data = try std.fmt.bufPrint(&full_buf, "{s}{s} INFO root You are now logged in as [a@b.c]\n", .{
            challenge,
            try sys.formatStamp(&s2, now - 3000),
        }),
    });

    const found = scanner.scanAt(io, root, now + 1);
    try std.testing.expectEqual(@as(usize, 1), scanner.last_parsed);
    try std.testing.expect(found != null);
    try std.testing.expectEqual((now - 3000) + 8 * hour, found.?.deadline);

    // The login seals it.
    _ = scanner.scanAt(io, root, now + 2);
    try std.testing.expectEqual(@as(usize, 0), scanner.last_parsed);
}
