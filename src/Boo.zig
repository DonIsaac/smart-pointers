const std = @import("std");
const typeUtils = @import("type_utils.zig");

const Allocator = std.mem.Allocator;
const Type = std.builtin.Type;
const assert = std.debug.assert;

/// A smart pointer to borrow or owned data. This is akin to Rust's
/// [`Cow`](https://doc.rust-lang.org/std/borrow/enum.Cow.html) type.
///
/// ## Strings
/// `Boo` has a specialized implementation for string slice types. Function
/// signatures are almost the same, but `borrow` and its variants provide
/// direct access to the slice pointer itself, instead of, for example, a
/// `*const []const u8`.
///
/// There are also several specialized constructors.
/// ```zig
/// const Boo = @import("smart-pointers").Boo;
/// const foo = Boo([]const u8).static("foo bar");
/// const bar = Foo([]const u8).fmt("foo {s} baz", .{"bar"});
/// ```
pub fn Boo(comptime T: type) type {
    return if (T == []const u8 or T == []u8) BooStr else BooGeneric(T);
}

const BooStr = struct {
    __repr: Repr,
    len: usize,
    alloc: Allocator,

    const Self = BooStr;

    pub fn fmt(alloc: Allocator, comptime fmt_str: []const u8, comptime args: anytype) Allocator.Error!Self {
        const string = try std.fmt.allocPrint(alloc, fmt_str, args);
        return Self{
            .__repr = Repr.new(string.ptr, true),
            .len = string.len,
            .alloc = alloc,
        };
    }

    pub fn init(alloc: Allocator, value: []u8) Allocator.Error!Self {
        return Self{
            .__repr = Repr.new(value.ptr, true),
            .len = value.len,
            .alloc = alloc,
        };
    }

    pub fn static(alloc: Allocator, comptime string: anytype) Self {
        const slice = asSlice(string);
        return Self{
            .__repr = Repr.new(slice.ptr, false),
            .len = slice.len,
            .alloc = alloc,
        };
    }

    fn asSlice(comptime arr: [:0]const u8) []const u8 {
        return arr[0..arr.len];
    }

    pub fn isBorrowed(self: *Self) bool {
        return self.__repr.isBorrowed();
    }

    pub fn isOwned(self: *Self) bool {
        return self.__repr.isOwned();
    }

    pub inline fn borrow(self: *Self) []const u8 {
        return @as([*]const u8, @ptrCast(self.__repr.ptr(u8)))[0..self.len];
    }

    pub inline fn borrowMutAssumeOwned(self: *Self) []u8 {
        assert(self.isOwned());
        return @as([*]u8, @ptrCast(self.__repr.ptr(u8)))[0..self.len];
    }

    pub fn borrowMut(self: *Self) Allocator.Error![]u8 {
        if (self.isOwned()) return self.borrowMutAssumeOwned();
        const copy = try self.alloc.dupe(u8, self.borrow);
        self.__repr = Repr.new(copy.ptr, true);
        self.len = copy.len;
        return copy;
    }

    pub fn deinit(self: *Self) void {
        if (self.isBorrowed()) return;
        self.alloc.free(self.borrowMutAssumeOwned());
    }
};

fn BooGeneric(comptime T: type) type {
    return struct {
        /// **DO NOT ACCESS THIS DIRECTLY**
        ///
        /// Reading this value is an abstraction leak, and writing to it is a
        /// cardinal sin. Be wary, seeker of undefined behavior.
        __repr: Repr,
        alloc: Allocator,

        const Self = @This();
        const info = @typeInfo(T);
        const is_optional = info == .Optional;
        const slice_ty: ?type = brk: {
            var ty = info;
            while (true) {
                switch (ty) {
                    .Optional => {
                        ty = @typeInfo(ty.Optional.child);
                        continue;
                    },
                    .Pointer => {
                        if (ty.Pointer.size == .Slice) {
                            break :brk ty.Pointer.child;
                        } else {
                            break :brk null;
                        }
                    },
                    else => break :brk null,
                }
            }
        };
        const hasClone = switch (typeUtils.innerType(T)) {
            .Struct, .Union, .Enum => @hasDecl(T, "clone"),
            else => false,
        };

        /// Create a new borrowed `Boo` from a pointer.
        ///
        /// `alloc` will only ever be used if you try to mutate the borrowed
        /// data. When using a static value that will never be mutated, it's
        /// totally fine to hard-code `std.heap.page_allocator`.
        ///
        /// ## Example
        /// ```zig
        /// const Boo = @import("smart-pointers").Boo;
        /// var s = Boo([]const u8).newBorrowed(&"I'm a static string");
        /// // Since `s` contains borrowed data, the string is not deallocated.
        /// s.deinit();
        /// ```
        pub fn newBorrowed(alloc: Allocator, ptr: *const T) Self {
            return Self{ .__repr = Repr.new(@constCast(ptr), false), .alloc = alloc };
        }

        pub fn init(alloc: Allocator, value: T) !Self {
            // If T is optional and `value` is null, skip allocation until it gets updated into a non-null value.
            if (comptime is_optional) {
                if (value == null) {
                    return Self{ .__repr = Repr.newNullBorrow(), .alloc = alloc };
                }
            }

            const ptr = try alloc.create(T);
            ptr.* = value;
            return Self{ .__repr = Repr.new(ptr, true), .alloc = alloc };
        }

        pub fn isBorrowed(self: *Self) bool {
            return self.__repr.isBorrowed();
        }

        pub fn isOwned(self: *Self) bool {
            return self.__repr.isOwned();
        }

        /// Immutably borrow the value stored in this `Boo`.
        pub fn borrow(self: *const Self) *const T {
            return self.__repr.ptr(T);
        }

        /// Mutably borrow the value stored in this `Boo`.
        ///
        /// Mutable borrowing on borrowed data forces that data to be cloned.
        /// This `Boo` will now own its own allocation (i.e. the `Boo` is
        /// "owned").
        pub fn borrowMut(self: *Self) Allocator.Error!*T {
            if (self.__repr.isOwned()) return self.__repr.ptr(T);

            if (comptime hasClone) {
                // FIXME: handle fn clone(*self, alloc) signatures
                var clone: T = @call(.auto, T.clone, .{self.__repr.ptr(T)});
                // FIXME: ensure clone used self.alloc when allocating new memory
                errdefer typeUtils.deinitInner(T, &clone, self.alloc);
                const ptr: *T = try self.alloc.create(T);
                ptr.* = clone;
                self.__repr = Repr.new(ptr, true);
            } else if (comptime slice_ty != null) {
                const is_sentinel = info == .Pointer and info.Pointer.sentinel != null;
                @compileLog(is_sentinel);
                if (is_sentinel) {
                    const ptr = try self.alloc.dupeZ(slice_ty.?, self.__repr.ptr(T));
                    self.__repr = Repr.new(ptr, true);
                } else {
                    const ptr = try self.alloc.dupe(slice_ty.?, self.__repr.ptr(T));
                    self.__repr = Repr.new(ptr, true);
                    @compileError("other branch should be getting hit");
                }
            } else {
                const ptr = try self.alloc.create(T);
                ptr.* = self.__repr.ptr(T).*;
                self.__repr = Repr.new(ptr, true);
            }

            return self.__repr.ptr(T);
        }

        pub fn deinit(self: *Self) void {
            if (self.__repr.isBorrowed()) return;
            // var ptr: *T = @ptrCast(self.__repr.ptr());
            const ptr: *T = brk: {
                if (comptime is_optional) {
                    if (self.__repr.isNull()) return;
                }
                break :brk self.__repr.ptr(T);
            };

            if (comptime is_optional) {
                if (ptr.* == null) return;
            }

            typeUtils.deinitInner(T, ptr, self.alloc);
            self.alloc.destroy(ptr);
        }
    };
}

const Repr = struct {
    __ptr: usize,

    const OWNERSHIP_BITMASK: usize = 0x01;
    const POINTER_BITMASK: usize = ~OWNERSHIP_BITMASK;

    fn newNullBorrow() Repr {
        return .{ .__ptr = 0 };
    }

    fn new(pointer: anytype, comptime owned: bool) Repr {
        var p: usize = @intFromPtr(pointer);
        if (owned) p |= OWNERSHIP_BITMASK;
        return Repr{ .__ptr = p };
    }

    fn ptr(self: Repr, comptime T: type) *T {
        const p = self.__ptr & POINTER_BITMASK;
        assert(p != 0);
        return @ptrFromInt(p);
    }

    fn maybePtr(self: Repr, comptime T: type) ?*T {
        const p = self.__ptr & POINTER_BITMASK;
        return if (p == 0) null else @ptrFromInt(p);
    }

    inline fn isNull(self: Repr) bool {
        return self.__ptr == 0;
    }

    fn isOwned(self: Repr) bool {
        if (self.__ptr == 0) return false;
        const ownership_tag = self.__ptr & OWNERSHIP_BITMASK;
        assert(ownership_tag == 0 or ownership_tag == 1);
        return ownership_tag == 1;
    }

    fn isBorrowed(self: Repr) bool {
        return !self.isOwned();
    }
};

const a = std.testing.allocator;
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

test "null initialization" {
    var boo = try Boo(?u32).init(a, null);
    defer boo.deinit();
    try expectEqual(0, boo.__repr.__ptr);
    try expect(boo.__repr.isBorrowed());
}

test "new borrowed from static string" {
    const alloc = std.testing.allocator;
    var boo = Boo([]const u8).static(alloc, "I'm a static string");
    boo.deinit();
    const b = boo.borrow();
    try std.testing.expectEqualStrings(std.mem.sliceTo("I'm a static string", 0), b);
}

// test "mutating a statically-initialized string Boo" {
//     const alloc = std.testing.allocator;
//     const owned: [:0]u8 = try alloc.dupeZ(u8, "I'm an owned string");
//     var boo = Boo([:0]const u8).newBorrowed(std.testing.allocator, &std.mem.sliceTo("I'm a static string", 0));
//     defer boo.deinit();
//     // mutably borrowing the string forces an allocation
//     const str = try boo.borrowMut();
//     str.* = owned;
//     try expect(boo.isOwned());
//     try expectEqual(boo.borrow(), &std.mem.sliceTo("I'm an owned string", 0));
// }

// test "primitives" {}
