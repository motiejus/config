//! Forces a full Google re-authentication, resetting the Cloud session window.
//!
//! A plain `gcloud auth login` is satisfied by the browser's existing SSO
//! cookie, so it inherits whatever is left of the current session. This drives
//! the same flow but rewrites the authorize URL with `prompt=login consent` and
//! `max_age=0`, which obliges Google to re-challenge. On success the new
//! session start is recorded, since a forced reauth leaves no trace in the logs.

const std = @import("std");
const build_options = @import("build_options");
const sys = @import("sys.zig");

const url_prefix = "https://accounts.google.com/o/oauth2/auth?";

// Prisma Access Browser strips command-line switches, so the forced challenge
// has to ride on the URL itself rather than an --incognito flag.
const default_opener = "/usr/bin/open -b com.talon-sec.Work";

const usage =
    \\usage: gcloud-force-reauth [account] [--dry-run] [--update-adc] [--opener CMD]
    \\
    \\  account       account to authenticate
    \\  --dry-run     print the rewritten URL and exit without authenticating
    \\  --update-adc  also refresh application default credentials
    \\  --opener CMD  command used to open the URL
    \\
;

const Options = struct {
    account: ?[]const u8 = null,
    dry_run: bool = false,
    update_adc: bool = false,
    opener: []const u8 = default_opener,
};

fn parseArgs(argv: []const [:0]const u8) ?Options {
    var o: Options = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--dry-run")) {
            o.dry_run = true;
        } else if (std.mem.eql(u8, a, "--update-adc")) {
            o.update_adc = true;
        } else if (std.mem.eql(u8, a, "--opener")) {
            i += 1;
            if (i >= argv.len) return null;
            o.opener = argv[i];
        } else if (std.mem.startsWith(u8, a, "--opener=")) {
            o.opener = a["--opener=".len..];
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            return null;
        } else if (std.mem.startsWith(u8, a, "-")) {
            return null;
        } else if (o.account == null) {
            o.account = a;
        } else return null;
    }
    return o;
}

/// Returns the URL only once its terminating whitespace has arrived, so a
/// partial read cannot yield a truncated URL.
fn findUrl(buf: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, buf, url_prefix) orelse return null;
    var end = start;
    while (end < buf.len and !std.ascii.isWhitespace(buf[end])) end += 1;
    return if (end < buf.len) buf[start..end] else null;
}

/// Overrides prompt/max_age, leaving every other parameter byte-identical:
/// re-encoding would break the PKCE code_challenge and state round-trip.
fn rewriteUrl(gpa: std.mem.Allocator, url: []const u8) ![]u8 {
    const q = std.mem.indexOfScalar(u8, url, '?') orelse return error.NoQuery;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, url[0 .. q + 1]);

    var have_prompt = false;
    var have_max_age = false;
    var first = true;
    var it = std.mem.splitScalar(u8, url[q + 1 ..], '&');
    while (it.next()) |param| {
        if (param.len == 0) continue;
        if (!first) try out.append(gpa, '&');
        first = false;
        const key = param[0 .. std.mem.indexOfScalar(u8, param, '=') orelse param.len];
        if (std.mem.eql(u8, key, "prompt")) {
            try out.appendSlice(gpa, "prompt=login%20consent");
            have_prompt = true;
        } else if (std.mem.eql(u8, key, "max_age")) {
            try out.appendSlice(gpa, "max_age=0");
            have_max_age = true;
        } else {
            try out.appendSlice(gpa, param);
        }
    }
    if (!have_prompt) {
        if (!first) try out.append(gpa, '&');
        first = false;
        try out.appendSlice(gpa, "prompt=login%20consent");
    }
    if (!have_max_age) {
        if (!first) try out.append(gpa, '&');
        try out.appendSlice(gpa, "max_age=0");
    }
    return out.toOwnedSlice(gpa);
}

fn say(io: std.Io, file: std.Io.File, comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    file.writeStreamingAll(io, s) catch {};
}

fn openUrl(gpa: std.mem.Allocator, io: std.Io, opener: []const u8, url: []const u8) void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    var words = std.mem.tokenizeScalar(u8, opener, ' ');
    while (words.next()) |w| argv.append(gpa, w) catch return;
    argv.append(gpa, url) catch return;
    var child = std.process.spawn(io, .{ .argv = argv.items }) catch return;
    _ = child.wait(io) catch {};
}

fn recordAnchor(io: std.Io, started: i64) void {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = sys.anchorPath(&path_buf) orelse return;
    var stamp_buf: [32]u8 = undefined;
    const stamp = sys.formatStamp(&stamp_buf, started) catch return;
    var line_buf: [40]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "{s}\n", .{stamp}) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = line }) catch return;

    const tm = sys.localParts(started);
    say(io, std.Io.File.stdout(), "\nSession anchor recorded: {s} {d:0>2}:{d:0>2}\n", .{
        sys.weekdays[@intCast(@mod(tm.wday, 7))],
        @as(u32, @intCast(tm.hour)),
        @as(u32, @intCast(tm.min)),
    });
}

pub fn main(init: std.process.Init) u8 {
    const gpa = init.gpa;
    const io = init.io;
    const stdout = std.Io.File.stdout();
    const stderr = std.Io.File.stderr();

    const argv = init.minimal.args.toSlice(init.arena.allocator()) catch return 1;
    const opts = parseArgs(argv) orelse {
        say(io, stderr, "{s}", .{usage});
        return 2;
    };

    var cmd: std.ArrayList([]const u8) = .empty;
    defer cmd.deinit(gpa);
    cmd.appendSlice(gpa, &.{ build_options.gcloud_path, "auth", "login", "--force", "--no-launch-browser" }) catch return 1;
    if (opts.account) |a| cmd.append(gpa, a) catch return 1;
    if (opts.update_adc) cmd.append(gpa, "--update-adc") catch return 1;

    const started = sys.now();

    // gcloud prints the authorize URL on stderr and reads the verification code
    // from stdin with a plain prompt, so piping stderr alone is enough; stdin
    // and stdout stay attached to the terminal and gcloud does its own reading.
    var child = std.process.spawn(io, .{
        .argv = cmd.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .pipe,
    }) catch |err| {
        say(io, stderr, "cannot run {s}: {t}\n", .{ build_options.gcloud_path, err });
        return 1;
    };

    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(gpa);
    var rewritten: ?[]u8 = null;
    defer if (rewritten) |u| gpa.free(u);

    var chunk: [4096]u8 = undefined;
    var bufs = [_][]u8{&chunk};
    while (true) {
        const n = child.stderr.?.readStreaming(io, &bufs) catch break;
        stderr.writeStreamingAll(io, chunk[0..n]) catch {};
        if (rewritten != null) continue;

        pending.appendSlice(gpa, chunk[0..n]) catch break;
        const raw = findUrl(pending.items) orelse continue;
        rewritten = rewriteUrl(gpa, raw) catch break;

        if (opts.dry_run) {
            say(io, stdout, "\n--- rewritten authorize URL (dry run) ---\n", .{});
            say(io, stdout, "{s}\n", .{rewritten.?});
            child.kill(io);
            return 0;
        }
        say(io, stdout, "\nOpening a full re-authentication prompt in your browser.\n", .{});
        say(io, stdout, "Sign in completely, then paste the verification code below.\n\n", .{});
        openUrl(gpa, io, opts.opener, rewritten.?);
    }

    const term = child.wait(io) catch return 1;
    if (rewritten == null) {
        say(io, stderr, "\nNo authorize URL seen -- gcloud may already hold valid credentials.\n", .{});
        return 1;
    }

    const code: u8 = switch (term) {
        .exited => |c| c,
        else => 1,
    };
    if (code == 0) recordAnchor(io, started);
    return code;
}

const sample_url = url_prefix ++
    "response_type=code&client_id=32555940559.apps.googleusercontent.com" ++
    "&redirect_uri=https%3A%2F%2Fsdk.cloud.google.com%2Fauthcode.html" ++
    "&scope=openid+https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fuserinfo.email" ++
    "&state=0wz0VJrusaMl0MqO2dQWthlxRFO4nW&prompt=consent&token_usage=remote" ++
    "&access_type=offline&code_challenge=UQj3obG3Qurr&code_challenge_method=S256";

test "findUrl needs the terminating whitespace" {
    try std.testing.expect(findUrl("Go to:\n    " ++ sample_url) == null);
    const got = findUrl("Go to:\n    " ++ sample_url ++ "\n\nEnter code:").?;
    try std.testing.expectEqualStrings(sample_url, got);
}

test "rewriteUrl forces the challenge and preserves PKCE params in order" {
    const got = try rewriteUrl(std.testing.allocator, sample_url);
    defer std.testing.allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "prompt=login%20consent") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "prompt=consent&") == null);
    try std.testing.expect(std.mem.endsWith(u8, got, "&max_age=0"));
    // Everything else must survive byte-identically, encoding included.
    for ([_][]const u8{
        "response_type=code",
        "client_id=32555940559.apps.googleusercontent.com",
        "redirect_uri=https%3A%2F%2Fsdk.cloud.google.com%2Fauthcode.html",
        "scope=openid+https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fuserinfo.email",
        "state=0wz0VJrusaMl0MqO2dQWthlxRFO4nW",
        "token_usage=remote",
        "access_type=offline",
        "code_challenge=UQj3obG3Qurr",
        "code_challenge_method=S256",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, got, needle) != null);
    }
    // prompt keeps its original position rather than moving to the end.
    const p = std.mem.indexOf(u8, got, "prompt=login%20consent").?;
    try std.testing.expect(p < std.mem.indexOf(u8, got, "token_usage=remote").?);
}

test "rewriteUrl appends both params when absent" {
    const got = try rewriteUrl(std.testing.allocator, url_prefix ++ "a=1&b=2");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(url_prefix ++ "a=1&b=2&prompt=login%20consent&max_age=0", got);
}

test "parseArgs handles positional, flags and both opener forms" {
    try std.testing.expect(parseArgs(&.{ "x", "--help" }) == null);
    const a = parseArgs(&.{ "x", "me@example.com", "--dry-run", "--update-adc" }).?;
    try std.testing.expectEqualStrings("me@example.com", a.account.?);
    try std.testing.expect(a.dry_run and a.update_adc);
    try std.testing.expectEqualStrings(default_opener, a.opener);
    try std.testing.expectEqualStrings("echo", parseArgs(&.{ "x", "--opener", "echo" }).?.opener);
    try std.testing.expectEqualStrings("echo", parseArgs(&.{ "x", "--opener=echo" }).?.opener);
}
