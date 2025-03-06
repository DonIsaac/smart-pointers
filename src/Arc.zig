const std = @import("std");
const typeUtils = @import("type_utils.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Type = std.builtin.Type;

const AtomicU32 = std.atomic.Value(u32);

/// A thread-safe reference-counted pointer. "Arc" stands for "Atomically Reference Counted".
///
/// This type is based on [`Arc`](https://doc.rust-lang.org/std/sync/struct.Arc.html) in Rust's standard library.
///
/// `Arc(T)` provides a shared, read-only access to a value of type `T`. It is
/// possible to get a mutable reference when only a single reference exists, to
/// `T`. Mutating `T` while it is referenced in more than one place may cause
/// logical errors in the best case or undefined behavior in the worst case.
///
/// `Arc(T)` uses atomic operations when reading and writing reference counts,
/// making `T` safe to read across threads (i.e. it is `Sync`). It is also safe
/// to move an `Arc` between threads (i.e. it is `Send`).
///
/// ## Creating References
/// Create the first reference to a value using `Arc(T).init(allocator, value)`.
/// Ownership of `value` gets moved into the `Arc`.
///
/// ```zig
/// const gpa = std.heap.GeneralPurposeAllocator(.{}){};
/// const num = Arc(u32).init(gpa.allocator(), 10);
/// ```
///
/// Use `Arc(T).clone()` to create additional references to the same `value`.
/// The recorded count of strong references will be incremented and no memory
/// allocations will occur;
///
/// ```zig
/// const num2 = num.clone();
/// try std.testing.expectEqual(10, num2.deref().*);
/// try std.testing.expectEqual(2, num.strongCount());
/// ```
///
/// ## Weak references
/// Weak references are not yet supported. They may be added in a future
/// release.
///
/// ## Deinitialization
/// Calling `Arc(T).deinit()` will drop the reference. If this is the last
/// reference, the stored value will also be dropped. `Arc` makes a best-effort
/// guess on how to deinitialize stored values. If you find a case where `Arc`
/// is mishandling your particular type, please open an issue on GitHub.
///
/// ### Specifics
/// In all cases, the memory pointed to by the `Arc` will have
/// `allocator.destroy` called on it. Additional deinitialization steps depend
/// on the stored type.
///
/// Let `P` be a primitive type, `S` be a slice or sentinel-terminated array,
/// and `T` be any other kind of type.
///
/// - `Arc(P)`: no extra steps
/// - `Arc(*P)`: `allocator.destroy` is called on the pointer
/// - `Arc(S)`: `allocator.destroy` is called on the slice
/// - `Arc(T)`: if `T` has a deinit method, it will be called with the
///   signature (*T)
/// - `Arc(?T)`, `Arc(?*T)`, `Arc(?S)`: if the value is not null, the same
///   steps as `Arc(whatever)` are taken
///
/// ## Example
/// ```zig
/// const std = @import("std");
/// const Allocator = std.mem.Allocator;
/// const Arc = @import("smart-pointers").Arc;
///
/// var a = Arc(u32).init(std.testing.allocator, 10);
/// {
///     // Increases the reference count. The stored value is not copied or
///     // cloned.
///     var b = a.clone();
///     // When dropped, the reference count is decreased.
///     defer b.deinit();
/// }
/// // Since `a` is the last reference, the allocation and all of its resources
/// // are freed.
/// a.deinit();
/// ```
pub fn Arc(comptime T: type) type {
    const Inner = ArcInner(T);
    const info = @typeInfo(T);

    switch (info) {
        inline .@"fn", .@"void", .@"noreturn", .@"null", .@"enum", .@"undefined" => {
            @compileError("Arc(T) does not support " ++ @typeName(T) ++ " as a valid type for T.\n");
        },
        else => {},
    }

    return struct {
        /// **DO NOT ACCESS THIS DIRECTLY**
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

        pub inline fn strongCount(self: Self) u32 {
            return self.__inner.strong.load(.acquire);
        }

        /// Borrow the value stored in this Arc.
        ///
        /// ## Example
        /// ```zig
        /// const ptr = Arc(u32).init(allocator, 10);
        /// try std.testing.expectEqual(10, ptr.deref().*);
        /// ```
        pub inline fn deref(self: Self) *const T {
            return &self.__inner.value;
        }

        /// Mutably borrow the value stored in this Arc if no other references
        /// exist to it.
        ///
        /// ## Example
        /// ```zig
        /// const std = @import("std");
        /// const Arc = @import("smart-pointers").Arc;
        ///
        /// const ptr = Arc(u32).init(std.heap.page_allocator, 10);
        /// try std.testing.expectEqual(10, ptr.derefMut().?.*);
        /// const ptr2 = ptr.clone();
        /// try std.testing.expectEqual(null, ptr.derefMut());
        /// ```
        pub inline fn derefMut(self: Self) ?*T {
            return if (self.__inner.strong.load(.acquire) == 1)
                &self.__inner.value
            else
                null;
        }

        /// Mutably borrow the value stored in this Arc.
        ///
        /// Mutating this when multiple references exist could cause undefined
        /// behavior if consumers are expecting the contained value to remain
        /// unchanged. Looking for a safe alternative? Try `derefMut()`.
        ///
        /// ## Example
        /// ```zig
        /// const std = @import("std");
        /// const Arc = @import("smart-pointers").Arc;
        ///
        /// const ptr = Arc(u32).init(std.heap.page_allocator, 10);
        /// const pt2 = ptr.clone();
        /// // Mutating shared data is a bad idea but feasible with derefMutUnsafe.
        /// std.testing.expectEqual(10, ptr.derefMutUnsafe().*);
        /// std.testing.expectEqual(10, ptr2.derefMutUnsafe().*);
        /// ```
        pub inline fn derefMutUnsafe(self: Self) *T {
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
                typeUtils.deinitInner(T, &self.__inner.value, a);
                self.__inner.value = undefined;
                a.destroy(self.__inner);
            }

            // destroy the pointer. This Arc cannot be used to access the stored value after deinitilization.
            self.__inner = undefined;
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

const t = std.testing;
const expectEqual = std.testing.expectEqual;
// NOTE: the `test Arc` block is used by zig docs as an example, so we make it look pretty.

test Arc {
    var a: Arc(u32) = try Arc(u32).init(std.testing.allocator, 10);
    try expectEqual(10, a.deref().*);
    try expectEqual(1, a.strongCount());

    // Increase the number of strong references. No memory allocations occur.
    var b = a.clone();
    try expectEqual(10, b.deref().*);

    // `b` is now the last reference. The allocation remains until its dropped too.
    a.deinit();
    try expectEqual(10, b.deref().*);
    try expectEqual(1, b.strongCount());

    b.deinit();
}

// same test as above, but with further checks on implementation details
test "Art strong ref counts" {
    var a: Arc(u32) = try Arc(u32).init(std.testing.allocator, 10);
    try expectEqual(10, a.deref().*);
    try expectEqual(1, a.strongCount());

    var b = a.clone();
    try expectEqual(2, a.strongCount());
    try expectEqual(a.strongCount(), b.strongCount());
    try expectEqual(a.__inner, b.__inner);
    try expectEqual(@intFromPtr(a.__inner), @intFromPtr(b.__inner)); // same pointer

    a.deinit();
    try expectEqual(1, b.strongCount());
    try expectEqual(10, b.deref().*);
    b.deinit();
}

test "Arc.borrowMut" {
    var ptr = try Arc(u32).init(t.allocator, 10);
    defer ptr.deinit();
    try expectEqual(10, ptr.derefMut().?.*);

    {
        var ptr2 = ptr.clone();
        defer ptr2.deinit();
        try expectEqual(null, ptr.derefMut());
    }

    try expectEqual(10, ptr.derefMut().?.*);
}

test "Arc.deinit on primitives" {
    const Primitives = std.meta.Tuple(&.{ u32, ?u32, f32, bool });
    const values: Primitives = .{ 1, 0, 0.01, true };

    inline for (values) |value| {
        var x = try Arc(@TypeOf(value)).init(t.allocator, value);
        x.deinit();
    }
}

test "Arc.deinit on primitive slices" {
    const allocator = t.allocator;
    const Slices = std.meta.Tuple(&.{
        []const u8,
        ?[]const u8,
        ?[]const u8,
        []u8,
        ?[]u8,
        ?[]u8,
        [:0]u8,
    });
    const values: Slices = .{
        "I'm a static string",
        "I'm an optional static string",
        null,
        try allocator.dupe(u8, "I'm a heap-allocated string"),
        try allocator.dupe(u8, "I'm an optional heap-allocated string"),
        null,
        try allocator.dupeZ(u8, "I'm a heap-allocated 0-terminated string"),
    };

    inline for (values) |value| {
        const T = @TypeOf(value);
        var ptr = try Arc(T).init(allocator, value);
        ptr.deinit();
    }
}
test "Arc.deinit on allocated constant slice" {
    const foo = try t.allocator.dupe(u8, "foo");
    defer t.allocator.free(foo);

    var ptr = try Arc([]const u8).init(t.allocator, foo);
    defer ptr.deinit(); // does not free the slice
}

const Foo = struct {
    a: Allocator,
    x: u32,
    y: *u32,

    pub fn init(a: Allocator, x: u32, y: u32) Allocator.Error!Foo {
        const y_ptr = try a.create(u32);
        y_ptr.* = y;
        return .{ .a = a, .x = x, .y = y_ptr };
    }

    pub fn deinit(self: *Foo) void {
        self.a.destroy(self.y);
    }
};

test "Arc.deinit on struct with deinit()" {
    const foo = try Foo.init(std.testing.allocator, 1, 2);
    var arc = try Arc(Foo).init(std.testing.allocator, foo);
    arc.deinit();
}
