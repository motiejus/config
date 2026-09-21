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

/// Index from which bytes must be withheld: the start of a complete or partial
/// `url_prefix` occurrence, else `buf.len`. Everything before it is safe to
/// relay immediately, so gcloud's own prompts are never held back.
fn holdFrom(buf: []const u8) usize {
    if (std.mem.indexOf(u8, buf, url_prefix)) |i| return i;
    var n = @min(buf.len, url_prefix.len - 1);
    while (n > 0) : (n -= 1) {
        if (std.mem.eql(u8, buf[buf.len - n ..], url_prefix[0..n])) return buf.len - n;
    }
    return buf.len;
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

fn openUrl(gpa: std.mem.Allocator, io: std.Io, opener: []const u8, url: []const u8) void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    var words = std.mem.tokenizeScalar(u8, opener, ' ');
    while (words.next()) |w| argv.append(gpa, w) catch return;
    argv.append(gpa, url) catch return;
    var child = std.process.spawn(io, .{ .argv = argv.items }) catch return;
    _ = child.wait(io) catch {};
}

fn recordAnchor(io: std.Io, out: *std.Io.Writer, started: i64) !void {
    var cfg_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cfg = sys.configDir(&cfg_buf) orelse return error.NoConfigDir;
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = sys.anchorPath(&path_buf, cfg) orelse return error.NoConfigDir;

    var stamp_buf: [32]u8 = undefined;
    const stamp = try sys.formatStamp(&stamp_buf, started);
    var line_buf: [40]u8 = undefined;
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = try std.fmt.bufPrint(&line_buf, "{s}\n", .{stamp}),
    });

    var when: [32]u8 = undefined;
    try out.print("\nSession anchor recorded: {s}\n", .{try sys.formatDayTime(&when, started)});
}

pub fn main(init: std.process.Init) u8 {
    const gpa = init.gpa;
    const io = init.io;

    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    // Streaming, not positional: stdio writers must append, or a shell's
    // `>file 2>&1` has both of them pwrite from offset 0 over each other.
    var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
    var err = std.Io.File.stderr().writerStreaming(io, &err_buf);
    defer out.interface.flush() catch {};
    defer err.interface.flush() catch {};

    return run(gpa, io, init, &out.interface, &err.interface) catch |e| {
        err.interface.print("gcloud-force-reauth: {t}\n", .{e}) catch {};
        return 1;
    };
}

fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    init: std.process.Init,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) !u8 {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const opts = parseArgs(argv) orelse {
        try err.writeAll(usage);
        return 2;
    };

    var cmd: std.ArrayList([]const u8) = .empty;
    defer cmd.deinit(gpa);
    try cmd.appendSlice(gpa, &.{ build_options.gcloud_path, "auth", "login", "--force", "--no-launch-browser" });
    if (opts.account) |a| try cmd.append(gpa, a);
    if (opts.update_adc) try cmd.append(gpa, "--update-adc");

    const started = sys.now();

    // gcloud prints the authorize URL on stderr and reads the verification code
    // from stdin with a plain prompt, so piping stderr alone is enough; stdin
    // and stdout stay attached to the terminal and gcloud does its own reading.
    var child = std.process.spawn(io, .{
        .argv = cmd.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .pipe,
    }) catch |e| {
        try err.print("cannot run {s}: {t}\n", .{ build_options.gcloud_path, e });
        return 1;
    };

    // gcloud's own URL still carries prompt=consent, which the SSO cookie would
    // satisfy without any real re-authentication, so it must never reach the
    // terminal. Only the URL itself is withheld; everything around it streams
    // through, or gcloud's prompts would be invisible while it waits on stdin.
    var held: std.ArrayList(u8) = .empty;
    defer held.deinit(gpa);
    var rewritten: ?[]u8 = null;
    defer if (rewritten) |u| gpa.free(u);
    // A relay failure must not leave gcloud running on the user's terminal.
    errdefer child.kill(io);

    var chunk: [4096]u8 = undefined;
    var bufs = [_][]u8{&chunk};
    while (true) {
        const n = child.stderr.?.readStreaming(io, &bufs) catch break;
        try held.appendSlice(gpa, chunk[0..n]);

        if (rewritten != null) {
            try err.writeAll(held.items);
            held.clearRetainingCapacity();
            try err.flush();
            continue;
        }

        const raw = findUrl(held.items) orelse {
            const keep = holdFrom(held.items);
            try err.writeAll(held.items[0..keep]);
            std.mem.copyForwards(u8, held.items[0 .. held.items.len - keep], held.items[keep..]);
            held.shrinkRetainingCapacity(held.items.len - keep);
            try err.flush();
            continue;
        };

        const at = @intFromPtr(raw.ptr) - @intFromPtr(held.items.ptr);
        const url = try rewriteUrl(gpa, raw);
        rewritten = url;
        try err.writeAll(held.items[0..at]);
        try err.writeAll("[forced re-auth URL substituted]\n");
        try err.writeAll(held.items[at + raw.len ..]);
        held.clearRetainingCapacity();
        try err.flush();

        if (opts.dry_run) {
            try out.print("\n--- rewritten authorize URL (dry run) ---\n{s}\n", .{url});
            try out.flush();
            child.kill(io);
            return 0;
        }
        try out.print("\nOpening a full re-authentication prompt in your browser.\n", .{});
        try out.print("If it did not open, use this URL (and no other):\n{s}\n", .{url});
        try out.print("\nSign in completely, then paste the verification code below.\n\n", .{});
        try out.flush();
        openUrl(gpa, io, opts.opener, url);
    }

    // Whatever is still held cannot contain a URL we are going to substitute.
    try err.writeAll(held.items);
    try err.flush();

    const term = child.wait(io) catch return 1;
    if (rewritten == null) {
        try err.writeAll("\nNo authorize URL seen -- gcloud may already hold valid credentials.\n");
        try err.flush();
        return 1;
    }

    const code: u8 = switch (term) {
        .exited => |c| c,
        else => 1,
    };
    if (code == 0) try recordAnchor(io, out, started);
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

test "F2: only the URL span is withheld from the relay" {
    // Text before a potential prefix must stream out; a partial prefix at the
    // tail is held until the rest arrives.
    try std.testing.expectEqual(@as(usize, 11), holdFrom("Go to this:\n"[0..11]));
    try std.testing.expectEqual(@as(usize, 7), holdFrom("Go to: " ++ url_prefix[0..12]));
    try std.testing.expectEqual(@as(usize, 7), holdFrom("Go to: " ++ sample_url));
    // A lone "h" at the very end is a one-byte partial prefix.
    try std.testing.expectEqual(@as(usize, 6), holdFrom("Code: h"));
    // Nothing prefix-like: everything is releasable.
    try std.testing.expectEqual(@as(usize, 21), holdFrom("Enter the code below:"[0..21]));
}
