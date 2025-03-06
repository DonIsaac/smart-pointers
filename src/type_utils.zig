const std = @import("std");
const Type = std.builtin.Type;
const Allocator = std.mem.Allocator;

pub fn innerType(comptime T: type) Type {
    const ty = @typeInfo(T);
    return switch (ty) {
        .pointer => |ptr| innerType(ptr.child),
        .optional => |opt| innerType(opt.child),
        else => ty,
    };
}

pub fn isPrimitive(comptime ty: Type) bool {
    return switch (ty) {
        // TODO: include null, undefined?
        .bool, .comptime_float, .comptime_int, .float, .int => true,
        else => false,
    };
}

/// Makes a best-effort attempt to find and call the correct function to deinitialize `target` with.
pub fn deinitInner(comptime T: type, target: *T, alloc: Allocator) void {
    const info = @typeInfo(T);

    switch (info) {
        .@"fn", .void, .noreturn, .null, .enum_literal, .undefined => @panic("values of type " ++ @typeName(T) ++ " can never be deinitialized."),
        .pointer => return deinitPtr(info.pointer, target.*, alloc),
        .bool, .float, .int => {}, // stored inline, nothing to free
        .optional => {
            const childInfo = @typeInfo(info.optional.child);
            if (isPrimitive(childInfo)) return;
            if (childInfo == .pointer) {
                if (target.* != null) {
                    deinitPtr(childInfo.pointer, target.*.?, alloc);
                }
                return;
            }
        },
        .@"struct", .@"union", .@"enum" => {
            if (@hasDecl(T, "deinit")) {
                target.deinit();
            }
        },
        else => {
            @panic("Type '" ++ @typeName(T) ++ "' is a " ++ @tagName(info) ++ " and is not supported by deinitInner. Do me a solid and please open an issue on GitHub :)");
        },
    }
}

fn deinitPtr(comptime ptr: Type.Pointer, target: anytype, alloc: Allocator) void {
    if (ptr.is_const) return;

    if (ptr.size == .slice) {
        alloc.free(target);
        return;
    }

    switch (@typeInfo(ptr.child)) {
        .@"struct", .@"union", .@"enum" => {
            if (@hasDecl(ptr.child, "deinit")) {
                target.deinit();
            }
        },
        else => {},
    }
}
