//! Reconstructs the gcloud reauth session clock from gcloud's own logs: the
//! 8h window lives server-side at Google and nothing client-side carries it.
//!
//! The anchor is the earliest login after the last challenge whose deadline
//! has not lapsed, which is pessimistic by construction.

const std = @import("std");
const Io = std.Io;
const sys = @import("sys.zig");

const window = 8 * std.time.s_per_hour;

/// The login marker lands whenever the human finishes, and a DST fall-back
/// makes one hour of names ambiguous; the slack covers both.
const name_slack = std.time.s_per_hour;

const max_log_bytes = 4 << 20;
const login_marker = "You are now logged in as";
const reauth_markers = [_][]const u8{ "Reauthentication failed", "reauth is required" };

pub const Session = struct { deadline: i64 };

/// `at` is the name-time, used only to prune.
const Record = struct { at: i64, login: ?i64 = null, reauth: ?i64 = null };

/// Sealed means the login marker has been seen; nothing more can change.
const Seen = struct { mtime_ns: i128, size: u64, sealed: bool };

pub const Scanner = struct {
    gpa: std.mem.Allocator,
    files: std.StringHashMapUnmanaged(Seen) = .empty,
    records: std.ArrayList(Record) = .empty,
    /// Files parsed by the most recent scan; the steady state is zero.
    last_parsed: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Scanner {
        return .{ .gpa = gpa };
    }

    pub fn deinit(s: *Scanner) void {
        var it = s.files.keyIterator();
        while (it.next()) |k| s.gpa.free(k.*);
        s.files.deinit(s.gpa);
        s.records.deinit(s.gpa);
    }

    pub fn scan(s: *Scanner, io: Io) ?Session {
        var cfg_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const cfg = sys.configDir(&cfg_buf) orelse return null;
        return s.scanAt(io, cfg, sys.now());
    }

    /// `now` is a parameter so tests can drive the window.
    fn scanAt(s: *Scanner, io: Io, cfg: []const u8, now: i64) ?Session {
        s.last_parsed = 0;
        const cutoff = now - (window + name_slack);

        // Names are fixed-width and zero-padded, so a string compare against
        // the cutoff orders them by time without parsing any of them.
        var cutoff_buf: [19]u8 = undefined;
        const cutoff_key = keyTime(&cutoff_buf, cutoff) catch return null;

        var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const logs_path = std.fmt.bufPrint(&path_buf, "{s}/logs", .{cfg}) catch return null;
        if (Io.Dir.cwd().openDir(io, logs_path, .{ .iterate = true })) |opened| {
            var logs = opened;
            defer logs.close(io);
            var today_buf: [10]u8 = undefined;
            var oldest_buf: [10]u8 = undefined;
            const today = dayName(&today_buf, now) catch return null;
            const oldest = dayName(&oldest_buf, cutoff) catch return null;
            s.collect(io, logs, today, cutoff_key) catch {};
            // Only while the window still reaches back across midnight.
            if (!std.mem.eql(u8, oldest, today)) s.collect(io, logs, oldest, cutoff_key) catch {};
        } else |_| {}

        s.prune(cutoff, cutoff_key);
        return decide(s.records.items, now);
    }

    fn collect(s: *Scanner, io: Io, logs: Io.Dir, day: []const u8, cutoff_key: []const u8) !void {
        var dir = logs.openDir(io, day, .{ .iterate = true }) catch return;
        defer dir.close(io);

        // NAME_MAX is 255, so the assert below cannot fire; sizing it any
        // tighter would turn a skipped file into an overflow in release.
        var key_buf: [10 + 1 + 255]u8 = undefined;
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".log")) continue;
            // Hand-assembled: the format engine costs more than everything
            // else this loop does per entry.
            std.debug.assert(day.len + 1 + entry.name.len <= key_buf.len);
            @memcpy(key_buf[0..day.len], day);
            key_buf[day.len] = '/';
            @memcpy(key_buf[day.len + 1 ..][0..entry.name.len], entry.name);
            const key = key_buf[0 .. day.len + 1 + entry.name.len];
            // gcloud names a log for its birth time: relevance, no I/O.
            if (std.mem.order(u8, key, cutoff_key) == .lt) continue;
            if (s.files.get(key)) |seen| if (seen.sealed) continue;
            s.ingest(io, dir, entry.name, key) catch continue;
        }
    }

    fn ingest(s: *Scanner, io: Io, dir: Io.Dir, name: []const u8, key: []const u8) !void {
        const stat = dir.statFile(io, name, .{}) catch return;
        // A `gcloud storage` log runs to hundreds of MB and holds nothing.
        if (stat.size > max_log_bytes) return;

        const prev = s.files.getPtr(key);
        if (prev) |e| if (e.mtime_ns == stat.mtime.nanoseconds and e.size == stat.size) return;

        // (mtime, size) is from before the read on purpose: a write landing
        // mid-read leaves them stale, so the next scan reads it again.

        const text = try dir.readFileAlloc(io, name, s.gpa, .limited(max_log_bytes));
        defer s.gpa.free(text);
        s.last_parsed += 1;

        const marks = scanText(text);
        // Duplicates from a re-read cannot change max(reauth) or min(login).
        if (marks) |m| {
            if (m.login != null or m.reauth != null) {
                // The one place a name is worth parsing: once per file read.
                // An undatable name cannot be pruned, so it is not recorded.
                if (nameTime(key)) |at| {
                    try s.records.append(s.gpa, .{ .at = at, .login = m.login, .reauth = m.reauth });
                }
            }
        }

        const seen: Seen = .{
            .mtime_ns = stat.mtime.nanoseconds,
            .size = stat.size,
            .sealed = if (marks) |m| m.login != null else false,
        };
        if (prev) |e| {
            e.* = seen;
            return;
        }
        const owned = try s.gpa.dupe(u8, key);
        errdefer s.gpa.free(owned);
        try s.files.put(s.gpa, owned, seen);
    }

    fn prune(s: *Scanner, cutoff: i64, cutoff_key: []const u8) void {
        var kept: std.StringHashMapUnmanaged(Seen) = .empty;
        var it = s.files.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            if (std.mem.order(u8, key, cutoff_key) != .lt) {
                kept.put(s.gpa, key, e.value_ptr.*) catch s.gpa.free(key);
            } else s.gpa.free(key);
        }
        s.files.deinit(s.gpa);
        s.files = kept;

        var i: usize = 0;
        while (i < s.records.items.len) {
            if (s.records.items[i].at < cutoff) _ = s.records.swapRemove(i) else i += 1;
        }
    }
};

fn dayName(buf: *[10]u8, epoch: i64) ![]const u8 {
    const d = sys.localParts(epoch);
    return std.fmt.bufPrint(buf, "{d:0>4}.{d:0>2}.{d:0>2}", .{ d.year, d.mon, d.mday });
}

/// The "YYYY.MM.DD/HH.MM.SS" prefix a log born at `epoch` would be named.
fn keyTime(buf: *[19]u8, epoch: i64) ![]const u8 {
    const t = sys.localParts(epoch);
    return std.fmt.bufPrint(buf, "{d:0>4}.{d:0>2}.{d:0>2}/{d:0>2}.{d:0>2}.{d:0>2}", .{
        t.year, t.mon, t.mday, t.hour, t.min, t.sec,
    });
}

/// "YYYY.MM.DD/HH.MM.SS.micros.log" as epoch seconds.
fn nameTime(key: []const u8) ?i64 {
    if (key.len < 19 or key[10] != '/' or key[13] != '.' or key[16] != '.') return null;
    const p = std.fmt.parseUnsigned;
    return sys.localToEpoch(
        p(u16, key[0..4], 10) catch return null,
        p(u8, key[5..7], 10) catch return null,
        p(u8, key[8..10], 10) catch return null,
        p(u8, key[11..13], 10) catch return null,
        p(u8, key[14..16], 10) catch return null,
        p(u8, key[17..19], 10) catch return null,
    );
}

const Marks = struct { login: ?i64 = null, reauth: ?i64 = null };

fn scanText(text: []const u8) ?Marks {
    var first: ?i64 = null;
    var last: ?i64 = null;
    var login_seen = false;
    var reauth_seen = false;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!login_seen and std.mem.indexOf(u8, line, login_marker) != null) login_seen = true;
        if (!reauth_seen) {
            for (reauth_markers) |m| {
                if (std.mem.indexOf(u8, line, m) != null) reauth_seen = true;
            }
        }
        const stamp = sys.parseStamp(line) orelse continue;
        if (first == null) first = stamp;
        last = stamp;
    }

    if (last == null) return null;
    return .{ .login = if (login_seen) last else null, .reauth = if (reauth_seen) first else null };
}

fn decide(records: []const Record, now: i64) ?Session {
    var last_reauth: i64 = std.math.minInt(i64);
    for (records) |r| if (r.reauth) |t| {
        if (t > last_reauth) last_reauth = t;
    };

    var best: ?i64 = null;
    for (records) |r| {
        const t = r.login orelse continue;
        if (t <= last_reauth or t + window <= now) continue;
        if (best == null or t < best.?) best = t;
    }
    return if (best) |t| .{ .deadline = t + window } else null;
}

/// Test-only: the app never formats a stamp.
fn formatStamp(buf: []u8, epoch: i64) ![]const u8 {
    const t = sys.localParts(epoch);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        t.year, t.mon, t.mday, t.hour, t.min, t.sec,
    });
}

fn loginAt(at: i64) Record {
    return .{ .at = at, .login = at };
}

fn reauthAt(at: i64) Record {
    return .{ .at = at, .reauth = at };
}

test "scanText takes first and last stamps and spots markers" {
    const marks = scanText(
        \\2026-09-21 10:00:00,001 DEBUG    root    reauth is required
        \\not a timestamped line
        \\2026-09-21 10:00:05,002 INFO     root    You are now logged in as [a@b.c]
        \\2026-09-21 10:00:09,003 DEBUG    root    done
    ).?;
    try std.testing.expectEqual(sys.parseStamp("2026-09-21 10:00:09").?, marks.login.?);
    try std.testing.expectEqual(sys.parseStamp("2026-09-21 10:00:00").?, marks.reauth.?);
    try std.testing.expect(scanText("You are now logged in as [a@b.c]\n") == null);
}

test "the anchor falls forward as deadlines lapse (2026-09-21 incident)" {
    // The 14:49 re-auth was cosmetic; the challenge landed at 20:16:35.
    const a = sys.parseStamp("2026-09-21 12:14:01").?;
    const b = sys.parseStamp("2026-09-21 14:49:21").?;
    const c = sys.parseStamp("2026-09-22 04:11:40").?;
    const earlier = sys.parseStamp("2026-09-21 12:13:29").?;
    const challenge = sys.parseStamp("2026-09-21 20:16:35").?;

    const before = [_]Record{ loginAt(a), loginAt(b), reauthAt(earlier) };
    try std.testing.expectEqual(a + window, decide(&before, sys.parseStamp("2026-09-21 19:00:00").?).?.deadline);
    try std.testing.expectEqual(b + window, decide(&before, sys.parseStamp("2026-09-21 20:15:00").?).?.deadline);

    // Once the challenge lands, nothing after it has logged in yet.
    const after = before ++ [_]Record{reauthAt(challenge)};
    try std.testing.expect(decide(&after, sys.parseStamp("2026-09-21 21:00:00").?) == null);

    // The next morning's login re-anchors the window.
    const next = after ++ [_]Record{loginAt(c)};
    try std.testing.expectEqual(c + window, decide(&next, sys.parseStamp("2026-09-22 04:19:00").?).?.deadline);
}

test "decide boundaries" {
    // A deadline exactly reached has expired.
    try std.testing.expectEqual(1000 + window, decide(&.{loginAt(1000)}, 1000 + window - 1).?.deadline);
    try std.testing.expect(decide(&.{loginAt(1000)}, 1000 + window) == null);
    // A login at the same instant as the challenge is not a candidate.
    try std.testing.expect(decide(&.{ loginAt(500), reauthAt(500) }, 501) == null);
    try std.testing.expect(decide(&.{}, 300) == null);
}

/// Writes `body` to a log named after `at`, the way gcloud names its own.
fn writeLog(io: Io, root: []const u8, at: i64, body: []const u8) !void {
    const t = sys.localParts(at);
    var dir_buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "{s}/logs/{d:0>4}.{d:0>2}.{d:0>2}", .{ root, t.year, t.mon, t.mday });
    try Io.Dir.cwd().createDirPath(io, dir);

    var path_buf: [192]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{d:0>2}.{d:0>2}.{d:0>2}.000001.log", .{ dir, t.hour, t.min, t.sec });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body });
}

test "a login marker that arrives late is still picked up" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Nothing is ever sealed by elapsed time, so the delay cannot matter.
    for ([_]i64{ 1, 20 * std.time.s_per_min, 2 * std.time.s_per_hour }) |delay| {
        const now = sys.now();
        var root_buf: [64]u8 = undefined;
        const root = try std.fmt.bufPrint(&root_buf, "/tmp/sessionbar-late-{d}-{d}", .{ now, delay });
        defer Io.Dir.cwd().deleteTree(io, root) catch {};

        var stamp: [32]u8 = undefined;
        var opened_buf: [256]u8 = undefined;
        const opened = try std.fmt.bufPrint(&opened_buf, "{s} DEBUG root Go to the following link\n", .{
            try formatStamp(&stamp, now),
        });
        try writeLog(io, root, now, opened);

        var scanner: Scanner = .init(gpa);
        defer scanner.deinit();
        try std.testing.expect(scanner.scanAt(io, root, now) == null);

        var stamp2: [32]u8 = undefined;
        var full_buf: [512]u8 = undefined;
        try writeLog(io, root, now, try std.fmt.bufPrint(&full_buf, "{s}{s} INFO root You are now logged in as [a@b.c]\n", .{
            opened,
            try formatStamp(&stamp2, now + delay),
        }));

        const found = scanner.scanAt(io, root, now + delay);
        try std.testing.expect(found != null);
        try std.testing.expectEqual(now + delay + window, found.?.deadline);
    }
}

test "an unchanged tree parses nothing, a new file parses once" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var root_buf: [64]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "/tmp/sessionbar-steady-{d}", .{sys.now()});
    defer Io.Dir.cwd().deleteTree(io, root) catch {};

    const now = sys.now();
    var stamp: [32]u8 = undefined;
    var body: [256]u8 = undefined;
    const done = try std.fmt.bufPrint(&body, "{s} INFO root You are now logged in as [a@b.c]\n", .{
        try formatStamp(&stamp, now - 3600),
    });
    try writeLog(io, root, now - 3600, done);

    var scanner: Scanner = .init(gpa);
    defer scanner.deinit();
    try std.testing.expect(scanner.scanAt(io, root, now) != null);
    try std.testing.expectEqual(@as(usize, 1), scanner.last_parsed);

    _ = scanner.scanAt(io, root, now + 1);
    try std.testing.expectEqual(@as(usize, 0), scanner.last_parsed);

    try writeLog(io, root, now - 1800, done);
    _ = scanner.scanAt(io, root, now + 2);
    try std.testing.expectEqual(@as(usize, 1), scanner.last_parsed);
}
