const std = @import("std");
const typeUtils = @import("type_utils.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Type = std.builtin.Type;

const AtomicU32 = std.atomic.Value(u32);

/// A reference-counted smart pointer using atomic operations to modify
/// reference counts.
pub fn Arc(comptime T: type) type {
    const Inner = ArcInner(T);
    const info = @typeInfo(T);

    switch (info) {
        inline .Fn, .Void, .NoReturn, .Null, .EnumLiteral, .Undefined => {
            @compileError("Arc(T) does not support " ++ @typeName(T) ++ " as a valid type for T.\n");
        },
        else => {},
    }

    return struct {
        /// **Don't access this directly.**
        ///
        /// Why are you reading these docs? You shouldn't be looking at this
        /// field, much less touching it. If you touch this I'll banish you to
        /// abstraction-leaker purgatory.
        __inner: *Inner,

        const Self = @This();

        pub fn init(alloc: Allocator, value: T) Allocator.Error!Self {
            const inner = try alloc.create(Inner);
            inner.* = Inner{ .value = value, .alloc = alloc };
            return Self{
                .__inner = inner,
            };
        }

        pub inline fn deref(self: Self) *const T {
            return &self.__inner.value;
        }

        pub fn clone(self: Self) Self {
            const strong_count = self.__inner.strong.fetchAdd(1, .acquire);
            assert(strong_count > 0); // inner value cannot already have been dropped

            return Self{ .__inner = self.__inner };
        }

        /// Drop this Arc pointer. If this is the last reference to the stored
        /// value, it also gets dropped. `T`s with a `deinit()` method will have
        /// it called a pointer to the stored value as the only parameter.
        pub fn deinit(self: *Self) void {
            // quota is 1000 by default. Setting it explicitly in case we need to change it later.
            @setEvalBranchQuota(1000);
            assert(self.__inner.strong.load(.acquire) != 0);
            const strong_count = self.__inner.strong.fetchSub(1, .release);
            // was 1, is now 0
            if (strong_count == 1) {
                const a = self.__inner.alloc;
                self.deinitInner();
                a.destroy(self.__inner);
                self.__inner = undefined;
            }
        }

        fn deinitInner(self: *Self) void {
            switch (info) {
                .Fn, .Void, .NoReturn, .Null, .EnumLiteral, .Undefined => unreachable,
                .Pointer => return deinitPtr(info.Pointer, self.__inner.value, self.__inner.alloc),
                .Bool, .Float, .Int => {}, // stored inline, nothing to free
                .Optional => {
                    const childInfo = @typeInfo(info.Optional.child);
                    if (typeUtils.isPrimitive(childInfo)) return;
                    if (childInfo == .Pointer) {
                        if (self.__inner.value != null) {
                            deinitPtr(childInfo.Pointer, self.__inner.value.?, self.__inner.alloc);
                        }
                        return;
                    }
                },
                else => @panic("Please open an issue on Github and tell Don he's a dingus who forgot to handle Arc::deinit() for values of type '" ++ @typeName(T) ++ "'. Thanks!"),
            }
            // _ = inner;
        }

        fn deinitPtr(comptime ptr: Type.Pointer, target: anytype, alloc: Allocator) void {
            if (ptr.is_const) return;

            if (ptr.size == .Slice) {
                alloc.free(target);
                return;
            }

            switch (@typeInfo(ptr.child)) {
                .Struct, .Union, .Enum => {
                    if (@hasDecl(ptr.child, "deinit")) {
                        target.deinit();
                    }
                },
                else => {},
            }
        }
    };
}

fn ArcInner(comptime T: type) type {
    return struct {
        strong: AtomicU32 = AtomicU32.init(1),
        alloc: Allocator,
        value: T,
    };
}

test Arc {
    const alloc = std.testing.allocator;
    const expectEqual = std.testing.expectEqual;

    var a: Arc(u32) = try Arc(u32).init(alloc, 10);
    try expectEqual(10, a.deref().*);
    try expectEqual(1, a.__inner.strong.raw);

    var b = a.clone();
    try expectEqual(2, a.__inner.strong.raw);
    try expectEqual(a.__inner.strong, b.__inner.strong);
    try expectEqual(a.__inner, b.__inner);
    try expectEqual(@intFromPtr(a.__inner), @intFromPtr(b.__inner)); // same pointer

    a.deinit();
    try expectEqual(1, b.__inner.strong.raw);
    try expectEqual(10, b.deref().*);
    b.deinit();
}

test "Arc.deinit on primitives" {
    const a = std.testing.allocator;
    const Primitives = std.meta.Tuple(&.{ u32, ?u32, f32, bool });
    const values: Primitives = .{ 1, 0, 0.01, true };

    inline for (values) |value| {
        var x = try Arc(@TypeOf(value)).init(a, value);
        x.deinit();
    }
}

test "Arc.deinit on primitive slices" {
    const a = std.testing.allocator;
    const Slices = std.meta.Tuple(&.{
        []const u8,
        ?[]const u8,
        ?[]const u8,
        []u8,
        ?[]u8,
        ?[]u8,
    });
    const values: Slices = .{
        "I'm a static string",
        "I'm an optional static string",
        null,
        try a.dupe(u8, "I'm a heap-allocated string"),
        try a.dupe(u8, "I'm an optional heap-allocated string"),
        null,
    };

    inline for (values) |value| {
        const T = @TypeOf(value);
        var ptr = try Arc(T).init(a, value);
        ptr.deinit();
    }
}
