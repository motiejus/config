const std = @import("std");
const objc = @import("objc.zig");
const expiry = @import("expiry.zig");
const flow = @import("flow.zig");
const sys = @import("sys.zig");

const tick_seconds: f64 = 1.0;
/// Log rescans are far more expensive than a tick, so they run every Nth one.
const ticks_per_rescan = 30;
const warn_minutes = 120;
const urgent_minutes = 60;

var io: std.Io = undefined;
var scanner: expiry.Scanner = undefined;
var session: ?expiry.Session = null;
var ticks: u32 = 0;

var status_item: objc.Id = null;
var due_item: objc.Id = null;
var reauth_item: objc.Id = null;
var app: objc.Id = null;
/// Until the first scan lands there is nothing honest to show.
var scanned = false;

extern const NSForegroundColorAttributeName: objc.Id;
extern const NSFontAttributeName: objc.Id;
extern const NSFontWeightRegular: f64;
extern const NSFontWeightBold: f64;

// Foundation's .tbd lacks NSRunLoopCommonModes; the CF constant is it.
extern const kCFRunLoopCommonModes: objc.Id;

const Look = struct {
    text: [:0]const u8,
    color: objc.Id,
    bold: bool,
};

fn systemColor(comptime name: [:0]const u8) objc.Id {
    return objc.msg(objc.Id, objc.class("NSColor"), objc.sel(name), .{});
}

fn expired() Look {
    return .{ .text = "reauth", .color = systemColor("systemRedColor"), .bold = true };
}

fn look(buf: []u8, remaining: ?i64) Look {
    const left = remaining orelse return expired();
    if (left < 0) return expired();
    // Unsigned: zig prints an explicit '+' for zero-padded signed integers.
    const text = std.fmt.bufPrintZ(buf, "{d}:{d:0>2}:{d:0>2}", .{
        @as(u32, @intCast(@divFloor(left, 3600))),
        @as(u32, @intCast(@divFloor(@mod(left, 3600), 60))),
        @as(u32, @intCast(@mod(left, 60))),
    }) catch unreachable;

    const minutes = @divFloor(left, 60);
    if (minutes < urgent_minutes) return .{ .text = text, .color = systemColor("systemRedColor"), .bold = true };
    if (minutes < warn_minutes) return .{ .text = text, .color = systemColor("systemYellowColor"), .bold = false };
    return .{ .text = text, .color = null, .bold = false };
}

fn attributedTitle(l: Look) objc.Id {
    const font_class = objc.class("NSFont");
    const size = objc.msg(f64, font_class, objc.sel("systemFontSize"), .{});
    const font = objc.msg(objc.Id, font_class, objc.sel("monospacedDigitSystemFontOfSize:weight:"), .{
        size,
        if (l.bold) NSFontWeightBold else NSFontWeightRegular,
    });

    const attrs = objc.autorelease(objc.new("NSMutableDictionary"));
    objc.msg(void, attrs, objc.sel("setObject:forKey:"), .{ font, NSFontAttributeName });
    // A null colour leaves the menu bar default, which tracks light/dark mode.
    if (l.color != null) {
        objc.msg(void, attrs, objc.sel("setObject:forKey:"), .{ l.color, NSForegroundColorAttributeName });
    }

    return objc.autorelease(objc.msg(objc.Id, objc.alloc("NSAttributedString"), objc.sel("initWithString:attributes:"), .{
        objc.nsString(l.text.ptr),
        attrs,
    }));
}

fn setTitle(item: objc.Id, text: []const u8) void {
    var buf: [128]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{text}) catch unreachable;
    objc.msg(void, item, objc.sel("setTitle:"), .{objc.nsString(z.ptr)});
}

fn refreshMenu() void {
    // While a flow is live the same item is the only way to call it off.
    setTitle(reauth_item, if (flow.active()) "Cancel re-auth" else "Force re-auth now");
    const s = session orelse return setTitle(due_item, "Reauth due: unknown");
    var when: [32]u8 = undefined;
    var buf: [96]u8 = undefined;
    const due = sys.formatDayTime(&when, s.deadline) catch unreachable;
    setTitle(due_item, std.fmt.bufPrint(&buf, "Reauth due {s}", .{due}) catch unreachable);
}

fn paint() void {
    var buf: [32]u8 = undefined;
    const l: Look = if (scanned)
        look(&buf, if (session) |s| s.deadline - sys.now() else null)
    else
        .{ .text = "\u{2026}", .color = null, .bold = false };
    const button = objc.msg(objc.Id, status_item, objc.sel("button"), .{});
    objc.msg(void, button, objc.sel("setAttributedTitle:"), .{attributedTitle(l)});
    refreshMenu();
}

fn tick() void {
    // A finished login writes its marker at once, so rescan immediately.
    const done = flow.poll();
    if (done or ticks % ticks_per_rescan == 0) {
        const began = std.Io.Timestamp.now(io, .awake);
        session = scanner.scan(io);
        scanned = true;
        if (sys.debug) {
            const took = std.Io.Timestamp.now(io, .awake).nanoseconds - began.nanoseconds;
            std.debug.print("[scan] {d} files in {d}us\n", .{ scanner.last_parsed, @divFloor(took, std.time.ns_per_us) });
        }
    }
    ticks +%= 1;
    paint();
}

fn onTick(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    tick();
}

fn onReauth(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    if (flow.active()) flow.cancel() else flow.start();
    paint();
}

/// Not terminate: directly, or a live flow outlives the app holding 8085.
fn onQuit(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    flow.cancel();
    flow.waitGone();
    objc.msg(void, app, objc.sel("terminate:"), .{@as(objc.Id, null)});
}

fn makeHandler() objc.Id {
    const cls = objc.objc_allocateClassPair(objc.objc_getClass("NSObject"), "SessionBarHandler", 0);
    _ = objc.class_addMethod(cls, objc.sel("reauth:"), @ptrCast(&onReauth), "v@:@");
    _ = objc.class_addMethod(cls, objc.sel("quit:"), @ptrCast(&onQuit), "v@:@");
    _ = objc.class_addMethod(cls, objc.sel("tick:"), @ptrCast(&onTick), "v@:@");
    objc.objc_registerClassPair(cls);
    return objc.msg(objc.Id, objc.msg(objc.Id, @ptrCast(cls), objc.sel("alloc"), .{}), objc.sel("init"), .{});
}

fn menuItem(title: [*:0]const u8, action: objc.Sel, target: objc.Id) objc.Id {
    const item = objc.msg(objc.Id, objc.alloc("NSMenuItem"), objc.sel("initWithTitle:action:keyEquivalent:"), .{
        objc.nsString(title),
        action,
        objc.nsString(""),
    });
    if (target != null) objc.msg(void, item, objc.sel("setTarget:"), .{target});
    return item;
}

fn usage(w_io: std.Io) void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(w_io, &buf);
    w.interface.writeAll(
        \\usage: sessionbar [--reauth-now] [--debug]
        \\
        \\A menu bar countdown to the next gcloud re-authentication.
        \\
        \\  --reauth-now  start the re-authentication flow immediately
        \\  --debug       trace the flow and scan timings to stderr
        \\
    ) catch return;
    w.flush() catch {};
}

pub fn main(init: std.process.Init) u8 {
    io = init.io;
    scanner = .init(init.gpa);
    defer scanner.deinit();

    var debug = false;
    var reauth_now = false;
    if (init.minimal.args.toSlice(init.arena.allocator())) |argv| {
        for (argv[1..]) |a| {
            if (std.mem.eql(u8, a, "--debug")) debug = true;
            if (std.mem.eql(u8, a, "--reauth-now")) reauth_now = true;
            if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
                usage(io);
                return 0;
            }
        }
    } else |_| {}
    sys.debug = debug;
    flow.init(init.gpa, init.io, init.environ_map);

    const pool = objc.new("NSAutoreleasePool");

    app = objc.msg(objc.Id, objc.class("NSApplication"), objc.sel("sharedApplication"), .{});
    // NSApplicationActivationPolicyAccessory: menu bar only, no Dock icon.
    _ = objc.msg(objc.Bool, app, objc.sel("setActivationPolicy:"), .{@as(isize, 1)});

    const bar = objc.msg(objc.Id, objc.class("NSStatusBar"), objc.sel("systemStatusBar"), .{});
    // NSVariableStatusItemLength
    status_item = objc.msg(objc.Id, bar, objc.sel("statusItemWithLength:"), .{@as(f64, -1.0)});
    // Owned for the process lifetime rather than left to the top-level pool.
    _ = objc.msg(objc.Id, status_item, objc.sel("retain"), .{});

    const handler = makeHandler();
    due_item = menuItem("Reauth due: unknown", null, null);

    reauth_item = menuItem("Force re-auth now", objc.sel("reauth:"), handler);

    const menu = objc.new("NSMenu");
    objc.msg(void, menu, objc.sel("addItem:"), .{due_item});
    objc.msg(void, menu, objc.sel("addItem:"), .{objc.msg(objc.Id, objc.class("NSMenuItem"), objc.sel("separatorItem"), .{})});
    objc.msg(void, menu, objc.sel("addItem:"), .{reauth_item});
    objc.msg(void, menu, objc.sel("addItem:"), .{menuItem("Quit", objc.sel("quit:"), handler)});
    objc.msg(void, status_item, objc.sel("setMenu:"), .{menu});

    // Paint first: a cold log tree takes half a second to read.
    paint();
    if (reauth_now) flow.start();
    scheduleTimer(handler, 0, false);

    scheduleTimer(handler, tick_seconds, true);

    // AppKit gives each run-loop iteration its own pool from here on.
    objc.msg(void, pool, objc.sel("drain"), .{});
    objc.msg(void, app, objc.sel("run"), .{});
    return 0;
}

/// The default mode stalls while a menu is open; common modes do not.
fn scheduleTimer(handler: objc.Id, interval: f64, repeats: bool) void {
    const timer = objc.msg(objc.Id, objc.class("NSTimer"), objc.sel("timerWithTimeInterval:target:selector:userInfo:repeats:"), .{
        interval,
        handler,
        objc.sel("tick:"),
        @as(objc.Id, null),
        @as(objc.Bool, if (repeats) 1 else 0),
    });
    const run_loop = objc.msg(objc.Id, objc.class("NSRunLoop"), objc.sel("currentRunLoop"), .{});
    objc.msg(void, run_loop, objc.sel("addTimer:forMode:"), .{ timer, kCFRunLoopCommonModes });
}

test "look renders H:MM:SS and escalates by threshold" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("5:29:41", look(&buf, 5 * 3600 + 29 * 60 + 41).text);
    try std.testing.expectEqualStrings("0:00:09", look(&buf, 9).text);
    try std.testing.expectEqualStrings("12:00:00", look(&buf, 12 * 3600).text);
    try std.testing.expectEqualStrings("reauth", look(&buf, -1).text);
    try std.testing.expectEqualStrings("reauth", look(&buf, null).text);
    try std.testing.expect(!look(&buf, 3 * 3600).bold);
    try std.testing.expect(look(&buf, 30 * 60).bold);
}
