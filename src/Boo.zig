const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub fn Boo(comptime T: type) type {
    return struct {
        __repr: Repr,
        alloc: Allocator,

        const Self = @This();
        const is_optional = @typeInfo(T) == .Optional;

        pub fn init(alloc: Allocator, value: T) !Self {
            const ptr = try alloc.create(T);
            ptr.* = value;
            return Boo{ .__repr = Repr.new(ptr), .alloc = alloc };
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

    fn ptr(self: *Repr) *anyopaque {
        const p = self.__ptr & POINTER_BITMASK;
        assert(p != 0);
        return @ptrFromInt(p);
    }

    fn maybePtr(self: *Repr) ?*anyopaque {
        const p = self.__ptr & POINTER_BITMASK;
        return if (p == 0) null else @ptrFromInt(p);
    }

    fn isOwned(self: *Repr) bool {
        if (self.__ptr == 0) return false;
        const ownership_tag = self.__ptr & OWNERSHIP_BITMASK;
        assert(ownership_tag == 0 or ownership_tag == 1);
        return @as(bool, ownership_tag);
    }
};
