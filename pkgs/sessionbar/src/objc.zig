//! Minimal Objective-C runtime bindings: C API only, no SDK headers required.

pub const Id = ?*opaque {};
pub const Class = ?*opaque {};
pub const Sel = ?*opaque {};
pub const Imp = *const anyopaque;
pub const Bool = i8;

pub const YES: Bool = 1;
pub const NO: Bool = 0;

pub extern "objc" fn objc_getClass(name: [*:0]const u8) Class;
pub extern "objc" fn sel_registerName(name: [*:0]const u8) Sel;
pub extern "objc" fn objc_allocateClassPair(super: Class, name: [*:0]const u8, extra: usize) Class;
pub extern "objc" fn objc_registerClassPair(cls: Class) void;
pub extern "objc" fn class_addMethod(cls: Class, name: Sel, imp: Imp, types: [*:0]const u8) Bool;
extern "objc" fn objc_msgSend() void;

pub fn class(comptime name: [:0]const u8) Class {
    return objc_getClass(name.ptr);
}

pub fn sel(comptime name: [:0]const u8) Sel {
    return sel_registerName(name.ptr);
}

/// Casts objc_msgSend to a concrete signature; valid on arm64 where there is no
/// variadic ABI difference and no _stret/_fpret variants.
fn sendFn(comptime F: type) *const F {
    return @ptrCast(&objc_msgSend);
}

pub fn msg0(comptime R: type, obj: Id, s: Sel) R {
    return sendFn(fn (Id, Sel) callconv(.c) R)(obj, s);
}

pub fn msg1(comptime R: type, comptime A: type, obj: Id, s: Sel, a: A) R {
    return sendFn(fn (Id, Sel, A) callconv(.c) R)(obj, s, a);
}

pub fn msg2(comptime R: type, comptime A: type, comptime B: type, obj: Id, s: Sel, a: A, b: B) R {
    return sendFn(fn (Id, Sel, A, B) callconv(.c) R)(obj, s, a, b);
}

pub fn msg3(comptime R: type, comptime A: type, comptime B: type, comptime C: type, obj: Id, s: Sel, a: A, b: B, c: C) R {
    return sendFn(fn (Id, Sel, A, B, C) callconv(.c) R)(obj, s, a, b, c);
}

pub fn msg5(
    comptime R: type,
    comptime A: type,
    comptime B: type,
    comptime C: type,
    comptime D: type,
    comptime E: type,
    obj: Id,
    s: Sel,
    a: A,
    b: B,
    c: C,
    d: D,
    e: E,
) R {
    return sendFn(fn (Id, Sel, A, B, C, D, E) callconv(.c) R)(obj, s, a, b, c, d, e);
}

pub fn clsMsg0(comptime R: type, comptime name: [:0]const u8, s: Sel) R {
    return msg0(R, @ptrCast(class(name)), s);
}

pub fn alloc(comptime name: [:0]const u8) Id {
    return clsMsg0(Id, name, sel("alloc"));
}

/// Hands ownership to the run loop's pool; without it every refresh leaks.
pub fn autorelease(obj: Id) Id {
    return msg0(Id, obj, sel("autorelease"));
}

pub fn nsString(utf8: [*:0]const u8) Id {
    return msg1(Id, [*:0]const u8, @ptrCast(class("NSString")), sel("stringWithUTF8String:"), utf8);
}
