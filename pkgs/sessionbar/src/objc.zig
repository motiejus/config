//! Minimal Objective-C runtime bindings: C API only, no SDK headers required.

const std = @import("std");

pub const Id = ?*opaque {};
pub const Class = ?*opaque {};
pub const Sel = ?*opaque {};
pub const Imp = *const anyopaque;
pub const Bool = i8;

pub const YES: Bool = 1;

pub extern "objc" fn objc_getClass(name: [*:0]const u8) Class;
pub extern "objc" fn sel_registerName(name: [*:0]const u8) Sel;
pub extern "objc" fn objc_allocateClassPair(super: Class, name: [*:0]const u8, extra: usize) Class;
pub extern "objc" fn objc_registerClassPair(cls: Class) void;
pub extern "objc" fn class_addMethod(cls: Class, name: Sel, imp: Imp, types: [*:0]const u8) Bool;
extern "objc" fn objc_msgSend() void;

/// Classes are objects, so this returns `Id` and class methods go through `msg`.
pub fn class(comptime name: [:0]const u8) Id {
    return @ptrCast(objc_getClass(name.ptr));
}

pub fn sel(comptime name: [:0]const u8) Sel {
    return sel_registerName(name.ptr);
}

/// Per arity: zig 0.16 removed `@Type`, so fn types cannot be reified.
fn SendFn(comptime R: type, comptime Args: type) type {
    const f = @typeInfo(Args).@"struct".fields;
    return switch (f.len) {
        0 => fn (Id, Sel) callconv(.c) R,
        1 => fn (Id, Sel, f[0].type) callconv(.c) R,
        2 => fn (Id, Sel, f[0].type, f[1].type) callconv(.c) R,
        3 => fn (Id, Sel, f[0].type, f[1].type, f[2].type) callconv(.c) R,
        4 => fn (Id, Sel, f[0].type, f[1].type, f[2].type, f[3].type) callconv(.c) R,
        5 => fn (Id, Sel, f[0].type, f[1].type, f[2].type, f[3].type, f[4].type) callconv(.c) R,
        else => @compileError("objc.msg: unsupported arity"),
    };
}

/// Casts objc_msgSend to the signature `args` implies; arm64 only, and
/// every argument must be concretely typed (`@as(isize, 1)`, never `1`).
pub fn msg(comptime R: type, obj: Id, s: Sel, args: anytype) R {
    const f: *const SendFn(R, @TypeOf(args)) = @ptrCast(&objc_msgSend);
    return @call(.auto, f, .{ obj, s } ++ args);
}

pub fn alloc(comptime name: [:0]const u8) Id {
    return msg(Id, class(name), sel("alloc"), .{});
}

/// Plain `[[C alloc] init]`; an initWith… still goes through `alloc`.
pub fn new(comptime name: [:0]const u8) Id {
    return msg(Id, alloc(name), sel("init"), .{});
}

/// Hands ownership to the run loop's pool; without it every refresh leaks.
pub fn autorelease(obj: Id) Id {
    return msg(Id, obj, sel("autorelease"), .{});
}

pub fn nsString(utf8: [*:0]const u8) Id {
    return msg(Id, class("NSString"), sel("stringWithUTF8String:"), .{utf8});
}
