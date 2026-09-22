//! Forced re-authentication in one browser window: an Okta sign-out that
//! lands on Okta's own Google tile, which then SAMLs into the gcloud
//! authorize URL. BROWSER=/usr/bin/true keeps gcloud's 8085 listener while
//! stopping it opening a browser of its own.

const std = @import("std");
const build_options = @import("build_options");
const objc = @import("objc.zig");
const sys = @import("sys.zig");

/// A sign-in the user walked away from would hold port 8085 for ever.
const deadline_seconds = 10 * std.time.s_per_min;
/// How long a SIGTERM'd gcloud gets before SIGKILL.
const term_grace_seconds = 2;
const term_poll_ms = 100;
const Flow = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,

    pid: std.c.pid_t = 0,
    stderr: ?std.Io.File = null,
    started: i64 = 0,
    captured: std.ArrayList(u8) = .empty,
    opened: bool = false,
    opener_pid: std.c.pid_t = 0,
    /// When SIGTERM was sent; 0 when not cancelling.
    terminating: i64 = 0,
};

var flow: Flow = undefined;

pub fn init(gpa: std.mem.Allocator, io: std.Io, environ: *std.process.Environ.Map) void {
    flow = .{ .gpa = gpa, .io = io, .environ = environ };
}

pub fn active() bool {
    return flow.pid != 0;
}

fn dbg(comptime fmt: []const u8, args: anytype) void {
    if (!sys.debug) return;
    std.debug.print("[flow] " ++ fmt ++ "\n", args);
}

/// Always last: runModal spins a run loop, so the tick re-enters poll.
fn alert(message: [*:0]const u8, detail: [*:0]const u8) void {
    const app = objc.msg(objc.Id, objc.class("NSApplication"), objc.sel("sharedApplication"), .{});
    objc.msg(void, app, objc.sel("activateIgnoringOtherApps:"), .{objc.YES});

    const a = objc.new("NSAlert");
    objc.msg(void, a, objc.sel("setMessageText:"), .{objc.nsString(message)});
    objc.msg(void, a, objc.sel("setInformativeText:"), .{objc.nsString(detail)});
    _ = objc.msg(isize, a, objc.sel("runModal"), .{});
    objc.msg(void, a, objc.sel("release"), .{});
}

fn alertErr(comptime what: [:0]const u8, e: anyerror) void {
    var buf: [256]u8 = undefined;
    const msg: [*:0]const u8 = if (std.fmt.bufPrintZ(&buf, what ++ ": {t}", .{e})) |m| m.ptr else |_| what.ptr;
    alert("Re-authentication failed", msg);
}

pub fn start() void {
    std.debug.assert(!active());
    // Without this gcloud opens a browser of its own, which is the two-window
    // failure this whole design exists to avoid.
    flow.environ.put("BROWSER", "/usr/bin/true") catch |e|
        return alertErr("Could not prepare the environment", e);

    // --update-adc as well: the ADC file carries its own expiry, and without
    // it everything reading ADC keeps failing on the old schedule.
    const argv: []const []const u8 = &.{ build_options.gcloud_path, "auth", "login", "--force", "--update-adc" };
    const child = std.process.spawn(flow.io, .{
        .argv = argv,
        .environ_map = flow.environ,
        .stdin = .ignore,
        // A pipe nobody drains is an fd leak and, once full, a hang.
        .stdout = .ignore,
        .stderr = .pipe,
    }) catch |e| return alertErr("Could not run gcloud", e);

    flow.pid = child.id.?;
    flow.stderr = child.stderr.?;
    flow.started = sys.now();

    // Polled from the 1s tick, so it must never block the main thread.
    const fd = flow.stderr.?.handle;
    var o: std.c.O = @bitCast(@as(u32, @bitCast(std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0)))));
    o.NONBLOCK = true;
    _ = std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, @bitCast(@as(u32, @bitCast(o)))));

    if (sys.debug) {
        dbg("spawned pid={d} argv:", .{flow.pid});
        for (argv) |a| dbg("  {s}", .{a});
    }
}

/// Asks gcloud to stop and returns at once; poll sees the exit and escalates.
pub fn cancel() void {
    if (flow.pid == 0 or flow.terminating != 0) return;
    dbg("cancelling gcloud pid={d}", .{flow.pid});
    flow.terminating = sys.now();
    std.posix.kill(flow.pid, .TERM) catch {};
}

/// Quit cannot come back later to finish the job, so this one blocks.
pub fn waitGone() void {
    if (flow.pid == 0) return;
    var left: usize = term_grace_seconds * std.time.ms_per_s;
    while (left > 0) : (left -|= term_poll_ms) {
        if (reap(flow.pid) != null) break;
        // Not `catch break`: a failed sleep must still reach the SIGKILL.
        std.Io.sleep(flow.io, .fromMilliseconds(term_poll_ms), .awake) catch {};
    } else {
        hardKill();
        _ = reap(flow.pid);
    }
    reset();
}

fn hardKill() void {
    dbg("pid={d} ignored SIGTERM, killing", .{flow.pid});
    std.posix.kill(flow.pid, .KILL) catch {};
}

fn reset() void {
    if (flow.stderr) |f| {
        f.close(flow.io);
        flow.stderr = null;
    }
    flow.pid = 0;
    flow.opened = false;
    flow.started = 0;
    flow.terminating = 0;
    flow.captured.deinit(flow.gpa);
    flow.captured = .empty;
}

/// Exit status, null while running; a vanished child counts as failure.
fn reap(pid: std.c.pid_t) ?u8 {
    // waitpid(0) would reap any child in the group; asserts vanish in release.
    if (pid <= 0) return null;
    var status: c_int = 0;
    const r = std.c.waitpid(pid, &status, std.c.W.NOHANG);
    if (r == 0) return null;
    if (r < 0) return 1;
    const s: u32 = @bitCast(status);
    return if (std.c.W.IFEXITED(s)) std.c.W.EXITSTATUS(s) else 1;
}

fn reapOpener() void {
    if (flow.opener_pid == 0) return;
    const code = reap(flow.opener_pid) orelse return;
    dbg("open exited code={d}", .{code});
    flow.opener_pid = 0;
}

fn drain() void {
    const fd = (flow.stderr orelse return).handle;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &buf) catch return;
        if (n == 0) return;
        flow.captured.appendSlice(flow.gpa, buf[0..n]) catch return;
    }
}

/// One tick of the flow; true means a login just completed, so rescan.
pub fn poll() bool {
    reapOpener();
    if (!active()) return false;

    drain();
    // Nothing is opened once a cancel is in flight: the window would point at
    // a dead 8085, and an alert here would stack one per tick.
    if (!flow.opened and flow.terminating == 0) {
        if (findUrl(flow.captured.items)) |url| {
            if (!openReauth(url)) return false;
        }
    }

    // Reaped first, so a sign-in on the last tick is not a timeout.
    const code = reap(flow.pid) orelse {
        if (flow.terminating != 0) {
            if (sys.now() - flow.terminating > term_grace_seconds) hardKill();
        } else if (sys.now() - flow.started > deadline_seconds) {
            dbg("deadline passed, cancelling", .{});
            cancel();
            alert("Re-authentication timed out", "No sign-in arrived within 10 minutes.");
        }
        return false;
    };

    dbg("gcloud exited code={d}", .{code});
    if (code == 0) {
        reset();
        return true;
    }
    // A cancelled flow exits non-zero by construction; not news.
    if (flow.terminating != 0) {
        reset();
        return false;
    }

    // Drain the last lines, then settle state before the alert re-enters.
    drain();
    const tail = flow.gpa.dupeZ(u8, tailLines(std.mem.trimEnd(u8, flow.captured.items, "\n"), 20)) catch null;
    reset();
    if (tail) |z| {
        defer flow.gpa.free(z);
        alert("Re-authentication failed", z.ptr);
    } else alert("Re-authentication failed", "gcloud exited with an error.");
    return false;
}

const url_prefix = "https://accounts.google.com/o/oauth2/auth?";
const okta_signout = "https://" ++ build_options.okta_host ++ "/login/signout?fromURI=";
/// Relative on purpose: Okta drops a `fromURI` pointing at a foreign origin,
/// but honours one into its own app tile.
const okta_tile = "/app/google/" ++ build_options.okta_app ++ "/sso/saml?RelayState=";

/// Waits for the terminating whitespace: a partial read must not truncate.
fn findUrl(buf: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, buf, url_prefix) orelse return null;
    var end = at;
    while (end < buf.len and !std.ascii.isWhitespace(buf[end])) end += 1;
    return if (end < buf.len) buf[at..end] else null;
}

fn unreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

/// Sign out, then IdP-initiated SAML into Google carrying the authorize URL
/// as RelayState. Signing out first is what makes `--force` a real re-auth.
fn reauthUrl(gpa: std.mem.Allocator, authorize_url: []const u8) ![]u8 {
    var tile: std.Io.Writer.Allocating = .init(gpa);
    defer tile.deinit();
    try tile.writer.writeAll(okta_tile);
    try std.Uri.Component.percentEncode(&tile.writer, authorize_url, unreserved);

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.writeAll(okta_signout);
    try std.Uri.Component.percentEncode(&out.writer, tile.written(), unreserved);
    return out.toOwnedSlice();
}

/// False means the flow is over; the caller must not touch it again, as the
/// alert below spins a run loop that re-enters poll.
fn openReauth(authorize_url: []const u8) bool {
    // Set first: every path out of here is one-shot, success or not.
    flow.opened = true;
    dbg("captured authorize URL {s}", .{authorize_url[0..@min(authorize_url.len, 80)]});

    // A previous run's `open` can outlive its flow; never lose its pid.
    reapOpener();
    if (flow.opener_pid != 0) {
        dbg("open pid={d} still running, terminating it", .{flow.opener_pid});
        std.posix.kill(flow.opener_pid, .TERM) catch {};
        flow.opener_pid = 0;
    }

    const url = reauthUrl(flow.gpa, authorize_url) catch |e| {
        cancel();
        alertErr("Could not build the sign-in URL", e);
        return false;
    };
    defer flow.gpa.free(url);
    dbg("opening {s}", .{url});

    const child = std.process.spawn(flow.io, .{
        .argv = &.{ "/usr/bin/open", url },
        .environ_map = flow.environ,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |e| {
        // Nothing will reach 8085 now, so do not wait out the deadline.
        cancel();
        alertErr("Could not open the browser", e);
        return false;
    };
    flow.opener_pid = child.id.?;
    return true;
}

fn tailLines(text: []const u8, n: usize) []const u8 {
    var seen: usize = 0;
    var i: usize = text.len;
    while (i > 0) {
        i -= 1;
        if (text[i] != '\n') continue;
        seen += 1;
        if (seen >= n) return text[i + 1 ..];
    }
    return text;
}

test "findUrl needs the terminating whitespace" {
    const sample = url_prefix ++ "response_type=code&state=abc&redirect_uri=http%3A%2F%2Flocalhost%3A8085%2F";
    try std.testing.expect(findUrl("Your browser has been opened to visit:\n\n    " ++ sample) == null);
    try std.testing.expectEqualStrings(
        sample,
        findUrl("Your browser has been opened to visit:\n\n    " ++ sample ++ "\n\n").?,
    );
}

test "tailLines keeps at most the last n lines" {
    try std.testing.expectEqualStrings("c", tailLines("a\nb\nc", 1));
    try std.testing.expectEqualStrings("b\nc", tailLines("a\nb\nc", 2));
    try std.testing.expectEqualStrings("a\nb\nc", tailLines("a\nb\nc", 9));
    try std.testing.expectEqualStrings("", tailLines("", 3));
}

test "reauthUrl pins both encoding layers" {
    const gpa = std.testing.allocator;
    const authorize = url_prefix ++ "response_type=code&client_id=FAKE&redirect_uri=http%3A%2F%2Flocalhost%3A8085%2F&state=S";
    const url = try reauthUrl(gpa, authorize);
    defer gpa.free(url);

    // Byte-for-byte the URL the working experiment opened. redirect_uri is
    // triple-encoded because gcloud already encoded it once.
    try std.testing.expectEqualStrings(
        okta_signout ++ "%2Fapp%2Fgoogle%2F" ++ build_options.okta_app ++ "%2Fsso%2Fsaml%3FRelayState%3D" ++
            "https%253A%252F%252Faccounts.google.com%252Fo%252Foauth2%252Fauth" ++
            "%253Fresponse_type%253Dcode%2526client_id%253DFAKE" ++
            "%2526redirect_uri%253Dhttp%25253A%25252F%25252Flocalhost%25253A8085%25252F" ++
            "%2526state%253DS",
        url,
    );
}
