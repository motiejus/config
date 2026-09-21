const std = @import("std");
const build_options = @import("build_options");
const objc = @import("objc.zig");
const expiry = @import("expiry.zig");
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
var unverified_item: objc.Id = null;

extern const NSForegroundColorAttributeName: objc.Id;
extern const NSFontAttributeName: objc.Id;
extern const NSFontWeightRegular: f64;
extern const NSFontWeightBold: f64;

// Foundation's .tbd does not export NSRunLoopCommonModes; the toll-free
// bridged CoreFoundation constant is the same object.
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

fn look(buf: []u8, remaining: ?i64, unverified: bool) Look {
    const left = remaining orelse return expired();
    if (left < 0) return expired();
    // Unsigned: zig prints an explicit '+' for zero-padded signed integers.
    const text = std.fmt.bufPrintZ(buf, "{d}:{d:0>2}:{d:0>2}{s}", .{
        @as(u32, @intCast(@divFloor(left, 3600))),
        @as(u32, @intCast(@divFloor(@mod(left, 3600), 60))),
        @as(u32, @intCast(@mod(left, 60))),
        if (unverified) "?" else "",
    }) catch return expired();

    // While unverified the deadline shown is the pessimistic one the user has
    // probably already cleared, so escalating would nag for a re-auth they did.
    if (unverified) return .{ .text = text, .color = null, .bold = false };

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

    const attrs = objc.autorelease(objc.msg(objc.Id, objc.alloc("NSMutableDictionary"), objc.sel("init"), .{}));
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
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{text}) catch return;
    objc.msg(void, item, objc.sel("setTitle:"), .{objc.nsString(z.ptr)});
}

fn refreshMenu() void {
    var buf: [96]u8 = undefined;
    const s = session orelse {
        setTitle(due_item, "Reauth due: unknown");
        objc.msg(void, unverified_item, objc.sel("setHidden:"), .{objc.YES});
        return;
    };

    var when: [32]u8 = undefined;
    const due = sys.formatDayTime(&when, s.deadline) catch "unknown";
    setTitle(due_item, std.fmt.bufPrint(&buf, "Reauth due {s}", .{due}) catch "Reauth due: unknown");

    const u = s.unverified orelse {
        objc.msg(void, unverified_item, objc.sel("setHidden:"), .{objc.YES});
        return;
    };
    var at: [32]u8 = undefined;
    var until: [32]u8 = undefined;
    const at_s = sys.formatDayTime(&at, u.forced_at) catch "?";
    const until_s = sys.formatDayTime(&until, u.until) catch "?";
    setTitle(unverified_item, std.fmt.bufPrint(&buf, "Forced re-auth at {s} (unverified until {s})", .{
        at_s, until_s,
    }) catch "Forced re-auth pending");
    objc.msg(void, unverified_item, objc.sel("setHidden:"), .{@as(objc.Bool, 0)});
}

fn tick() void {
    if (ticks % ticks_per_rescan == 0) session = scanner.scan(io);
    ticks +%= 1;

    const remaining: ?i64 = if (session) |s| s.deadline - sys.now() else null;
    const unverified = if (session) |s| s.unverified != null else false;
    var buf: [32]u8 = undefined;
    const button = objc.msg(objc.Id, status_item, objc.sel("button"), .{});
    objc.msg(void, button, objc.sel("setAttributedTitle:"), .{attributedTitle(look(&buf, remaining, unverified))});
    refreshMenu();
}

fn onTick(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    tick();
}

fn alert(message: [*:0]const u8, detail: [*:0]const u8) void {
    const a = objc.msg(objc.Id, objc.alloc("NSAlert"), objc.sel("init"), .{});
    objc.msg(void, a, objc.sel("setMessageText:"), .{objc.nsString(message)});
    objc.msg(void, a, objc.sel("setInformativeText:"), .{objc.nsString(detail)});
    _ = objc.msg(isize, a, objc.sel("runModal"), .{});
    objc.msg(void, a, objc.sel("release"), .{});
}

fn onReauth(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    var detail: [512]u8 = undefined;
    const manual = std.fmt.bufPrintZ(&detail, "Run this in a terminal instead:\n\n{s}", .{
        build_options.reauth_path,
    }) catch "Could not build the command line.";

    var child = std.process.spawn(io, .{
        .argv = &.{ "/usr/bin/open", "-na", "-b", "com.mitchellh.ghostty", "--args", "-e", build_options.reauth_path },
    }) catch {
        alert("Could not launch Ghostty", manual.ptr);
        return;
    };
    const term = child.wait(io) catch {
        alert("Could not launch Ghostty", manual.ptr);
        return;
    };
    const ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) alert("Ghostty did not start", manual.ptr);
}

fn makeHandler() objc.Id {
    const cls = objc.objc_allocateClassPair(objc.objc_getClass("NSObject"), "SessionBarHandler", 0);
    _ = objc.class_addMethod(cls, objc.sel("reauth:"), @ptrCast(&onReauth), "v@:@");
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

pub fn main(init: std.process.Init) u8 {
    io = init.io;
    scanner = .init(init.gpa);
    defer scanner.deinit();

    _ = objc.msg(objc.Id, objc.alloc("NSAutoreleasePool"), objc.sel("init"), .{});

    const app = objc.msg(objc.Id, objc.class("NSApplication"), objc.sel("sharedApplication"), .{});
    // NSApplicationActivationPolicyAccessory: menu bar only, no Dock icon.
    _ = objc.msg(objc.Bool, app, objc.sel("setActivationPolicy:"), .{@as(isize, 1)});

    const bar = objc.msg(objc.Id, objc.class("NSStatusBar"), objc.sel("systemStatusBar"), .{});
    // NSVariableStatusItemLength
    status_item = objc.msg(objc.Id, bar, objc.sel("statusItemWithLength:"), .{@as(f64, -1.0)});
    // Owned for the process lifetime rather than left to the top-level pool.
    _ = objc.msg(objc.Id, status_item, objc.sel("retain"), .{});

    const handler = makeHandler();
    due_item = menuItem("Reauth due: unknown", null, null);
    unverified_item = menuItem("", null, null);
    objc.msg(void, unverified_item, objc.sel("setHidden:"), .{objc.YES});

    const menu = objc.msg(objc.Id, objc.alloc("NSMenu"), objc.sel("init"), .{});
    objc.msg(void, menu, objc.sel("addItem:"), .{due_item});
    objc.msg(void, menu, objc.sel("addItem:"), .{unverified_item});
    objc.msg(void, menu, objc.sel("addItem:"), .{objc.msg(objc.Id, objc.class("NSMenuItem"), objc.sel("separatorItem"), .{})});
    objc.msg(void, menu, objc.sel("addItem:"), .{menuItem("Force re-auth now", objc.sel("reauth:"), handler)});
    objc.msg(void, menu, objc.sel("addItem:"), .{menuItem("Quit", objc.sel("terminate:"), app)});
    objc.msg(void, status_item, objc.sel("setMenu:"), .{menu});

    tick();

    // Scheduled timers only run in the default mode, which stalls while a menu
    // is open; adding it to the common modes keeps the countdown live.
    const timer = objc.msg(objc.Id, objc.class("NSTimer"), objc.sel("timerWithTimeInterval:target:selector:userInfo:repeats:"), .{
        tick_seconds,
        handler,
        objc.sel("tick:"),
        @as(objc.Id, null),
        objc.YES,
    });
    const run_loop = objc.msg(objc.Id, objc.class("NSRunLoop"), objc.sel("currentRunLoop"), .{});
    objc.msg(void, run_loop, objc.sel("addTimer:forMode:"), .{ timer, kCFRunLoopCommonModes });

    objc.msg(void, app, objc.sel("run"), .{});
    return 0;
}

test "look renders H:MM:SS and escalates by threshold" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("5:29:41", look(&buf, 5 * 3600 + 29 * 60 + 41, false).text);
    try std.testing.expectEqualStrings("0:00:09", look(&buf, 9, false).text);
    try std.testing.expectEqualStrings("12:00:00", look(&buf, 12 * 3600, false).text);
    try std.testing.expectEqualStrings("reauth", look(&buf, -1, false).text);
    try std.testing.expectEqualStrings("reauth", look(&buf, null, false).text);
    try std.testing.expect(!look(&buf, 3 * 3600, false).bold);
    try std.testing.expect(look(&buf, 30 * 60, false).bold);
}

test "F3: an unverified session neither escalates nor drops the marker" {
    var buf: [32]u8 = undefined;
    // Inside both thresholds, which would otherwise be yellow and red-bold.
    for ([_]i64{ 90 * 60, 30 * 60, 1 }) |left| {
        const l = look(&buf, left, true);
        try std.testing.expect(!l.bold);
        try std.testing.expect(l.color == null);
        try std.testing.expect(std.mem.endsWith(u8, l.text, "?"));
    }
    try std.testing.expectEqualStrings("5:29:41?", look(&buf, 5 * 3600 + 29 * 60 + 41, true).text);
    // Past the pessimistic deadline the unverified marker no longer applies.
    try std.testing.expectEqualStrings("reauth", look(&buf, -1, true).text);
}
