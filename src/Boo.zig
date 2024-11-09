const std = @import("std");
const typeUtils = @import("type_utils.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub fn Boo(comptime T: type) type {
    return struct {
        /// **DO NOT ACCESS THIS DIRECTLY**
        ///
        /// Reading this value is an abstraction leak, and writing to it is a
        /// cardinal sin. Be wary, seeker of undefined behavior.
        __repr: Repr,
        alloc: Allocator,

        const Self = @This();
        const is_optional = @typeInfo(T) == .Optional;
        // const innerType = innerType(@typeInfo(T));

        pub fn init(alloc: Allocator, value: T) !Self {
            // If T is optional and `value` is null, skip allocation until it gets updated into a non-null value.
            if (comptime is_optional) {
                if (value == null) {
                    return Self{ .__repr = Repr.newNullBorrow(), .alloc = alloc };
                }
            }

            const ptr = try alloc.create(T);
            ptr.* = value;
            return Self{ .__repr = Repr.new(ptr), .alloc = alloc };
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

    fn new(pointer: *anyopaque) Repr {
        return Repr{ .__ptr = @intFromPtr(pointer) };
    }

    fn ptr(self: *Repr, comptime T: type) *T {
        const p = self.__ptr & POINTER_BITMASK;
        assert(p != 0);
        return @ptrFromInt(p);
    }

    fn maybePtr(self: *Repr, comptime T: type) ?*T {
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

test "primitives" {}
