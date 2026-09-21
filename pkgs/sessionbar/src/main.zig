const std = @import("std");
const build_options = @import("build_options");
const objc = @import("objc.zig");
const expiry = @import("expiry.zig");
const sys = @import("sys.zig");

const refresh_seconds: f64 = 30.0;
const warn_minutes = 120;
const urgent_minutes = 60;

var status_item: objc.Id = null;
var due_item: objc.Id = null;
var threaded: std.Io.Threaded = undefined;
var io: std.Io = undefined;

extern const NSForegroundColorAttributeName: objc.Id;
extern const NSFontAttributeName: objc.Id;
extern const NSFontWeightRegular: f64;
extern const NSFontWeightBold: f64;

const Look = struct {
    text: [:0]const u8,
    color: objc.Id,
    bold: bool,
};

fn systemColor(comptime name: [:0]const u8) objc.Id {
    return objc.clsMsg0(objc.Id, "NSColor", objc.sel(name));
}

fn look(buf: []u8, session: ?expiry.Session) Look {
    const s = session orelse return .{ .text = "reauth", .color = systemColor("systemRedColor"), .bold = true };
    if (s.minutes_left < 0) return .{ .text = "reauth", .color = systemColor("systemRedColor"), .bold = true };
    // Unsigned: zig prints an explicit '+' for zero-padded signed integers.
    const text = std.fmt.bufPrintZ(buf, "{d}:{d:0>2}", .{
        @as(u32, @intCast(@divFloor(s.minutes_left, 60))),
        @as(u32, @intCast(@mod(s.minutes_left, 60))),
    }) catch "?";
    if (s.minutes_left < urgent_minutes) return .{ .text = text, .color = systemColor("systemRedColor"), .bold = true };
    if (s.minutes_left < warn_minutes) return .{ .text = text, .color = systemColor("systemYellowColor"), .bold = false };
    return .{ .text = text, .color = null, .bold = false };
}

fn attributedTitle(l: Look) objc.Id {
    const font_class: objc.Id = @ptrCast(objc.class("NSFont"));
    const size = objc.msg0(f64, font_class, objc.sel("systemFontSize"));
    const font = objc.msg2(
        objc.Id,
        f64,
        f64,
        font_class,
        objc.sel("monospacedDigitSystemFontOfSize:weight:"),
        size,
        if (l.bold) NSFontWeightBold else NSFontWeightRegular,
    );

    const attrs = objc.autorelease(objc.msg0(objc.Id, objc.alloc("NSMutableDictionary"), objc.sel("init")));
    objc.msg2(void, objc.Id, objc.Id, attrs, objc.sel("setObject:forKey:"), font, NSFontAttributeName);
    // A null colour leaves the menu bar default, which tracks light/dark mode.
    if (l.color != null) {
        objc.msg2(void, objc.Id, objc.Id, attrs, objc.sel("setObject:forKey:"), l.color, NSForegroundColorAttributeName);
    }

    return objc.autorelease(objc.msg2(
        objc.Id,
        objc.Id,
        objc.Id,
        objc.alloc("NSAttributedString"),
        objc.sel("initWithString:attributes:"),
        objc.nsString(l.text.ptr),
        attrs,
    ));
}

fn dueText(buf: []u8, session: ?expiry.Session) [:0]const u8 {
    const s = session orelse return "Reauth due: unknown";
    const tm = sys.localParts(s.deadline);
    const wday = sys.weekdays[@intCast(@mod(tm.wday, 7))];
    return std.fmt.bufPrintZ(buf, "Reauth due {s} {d:0>2}:{d:0>2}", .{
        wday,
        @as(u32, @intCast(tm.hour)),
        @as(u32, @intCast(tm.min)),
    }) catch "Reauth due: unknown";
}

fn refresh() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const session = expiry.compute(arena.allocator(), io);

    var title_buf: [32]u8 = undefined;
    const button = objc.msg0(objc.Id, status_item, objc.sel("button"));
    objc.msg1(void, objc.Id, button, objc.sel("setAttributedTitle:"), attributedTitle(look(&title_buf, session)));

    var due_buf: [64]u8 = undefined;
    objc.msg1(void, objc.Id, due_item, objc.sel("setTitle:"), objc.nsString(dueText(&due_buf, session).ptr));
}

fn onTick(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    refresh();
}

fn onReauth(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    var child = std.process.spawn(io, .{
        .argv = &.{ "/usr/bin/open", "-na", "Ghostty", "--args", "-e", build_options.reauth_path },
    }) catch return;
    _ = child.wait(io) catch {};
}

fn makeHandler() objc.Id {
    const cls = objc.objc_allocateClassPair(objc.class("NSObject"), "SessionBarHandler", 0);
    _ = objc.class_addMethod(cls, objc.sel("reauth:"), @ptrCast(&onReauth), "v@:@");
    _ = objc.class_addMethod(cls, objc.sel("tick:"), @ptrCast(&onTick), "v@:@");
    objc.objc_registerClassPair(cls);
    return objc.msg0(objc.Id, objc.msg0(objc.Id, @ptrCast(cls), objc.sel("alloc")), objc.sel("init"));
}

fn menuItem(title: [*:0]const u8, action: objc.Sel, target: objc.Id) objc.Id {
    const item = objc.msg3(
        objc.Id,
        objc.Id,
        objc.Sel,
        objc.Id,
        objc.alloc("NSMenuItem"),
        objc.sel("initWithTitle:action:keyEquivalent:"),
        objc.nsString(title),
        action,
        objc.nsString(""),
    );
    if (target != null) objc.msg1(void, objc.Id, item, objc.sel("setTarget:"), target);
    return item;
}

pub fn main() void {
    threaded = .init(std.heap.page_allocator, .{});
    io = threaded.io();

    _ = objc.msg0(objc.Id, objc.alloc("NSAutoreleasePool"), objc.sel("init"));

    const app = objc.clsMsg0(objc.Id, "NSApplication", objc.sel("sharedApplication"));
    _ = objc.msg1(objc.Bool, isize, app, objc.sel("setActivationPolicy:"), 1); // NSApplicationActivationPolicyAccessory

    const bar = objc.clsMsg0(objc.Id, "NSStatusBar", objc.sel("systemStatusBar"));
    status_item = objc.msg1(objc.Id, f64, bar, objc.sel("statusItemWithLength:"), -1.0); // NSVariableStatusItemLength

    const handler = makeHandler();
    due_item = menuItem("Reauth due: unknown", null, null);

    const menu = objc.msg0(objc.Id, objc.alloc("NSMenu"), objc.sel("init"));
    objc.msg1(void, objc.Id, menu, objc.sel("addItem:"), due_item);
    objc.msg1(void, objc.Id, menu, objc.sel("addItem:"), objc.clsMsg0(objc.Id, "NSMenuItem", objc.sel("separatorItem")));
    objc.msg1(void, objc.Id, menu, objc.sel("addItem:"), menuItem("Force re-auth now", objc.sel("reauth:"), handler));
    objc.msg1(void, objc.Id, menu, objc.sel("addItem:"), menuItem("Quit", objc.sel("terminate:"), app));
    objc.msg1(void, objc.Id, status_item, objc.sel("setMenu:"), menu);

    refresh();

    _ = objc.msg5(
        objc.Id,
        f64,
        objc.Id,
        objc.Sel,
        objc.Id,
        objc.Bool,
        @ptrCast(objc.class("NSTimer")),
        objc.sel("scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:"),
        refresh_seconds,
        handler,
        objc.sel("tick:"),
        null,
        objc.YES,
    );

    objc.msg0(void, app, objc.sel("run"));
}
