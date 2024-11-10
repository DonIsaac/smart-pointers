const std = @import("std");
const Type = std.builtin.Type;
const Allocator = std.mem.Allocator;

pub fn innerType(comptime T: type) Type {
    const ty = @typeInfo(T);
    return switch (ty) {
        .Pointer => innerType(ty.Pointer.child),
        .Optional => innerType(ty.Optional.child),
        else => ty,
    };
}

pub fn isPrimitive(comptime ty: Type) bool {
    return switch (ty) {
        // TODO: include null, undefined?
        .Bool,
        .ComptimeFloat,
        .ComptimeInt,
        .Float,
        .Int,
        => true,
        else => false,
    };
}

/// Makes a best-effort attempt to find and call the correct function to deinitialize `target` with.
pub fn deinitInner(comptime T: type, target: *T, alloc: Allocator) void {
    const info = @typeInfo(T);

    switch (info) {
        .Fn, .Void, .NoReturn, .Null, .EnumLiteral, .Undefined => @panic("values of type " ++ @typeName(T) ++ " can never be deinitialized."),
        .Pointer => return deinitPtr(info.Pointer, target.*, alloc),
        .Bool, .Float, .Int => {}, // stored inline, nothing to free
        .Optional => {
            const childInfo = @typeInfo(info.Optional.child);
            if (isPrimitive(childInfo)) return;
            if (childInfo == .Pointer) {
                if (target.* != null) {
                    deinitPtr(childInfo.Pointer, target.*.?, alloc);
                }
                return;
            }
        },
        .Struct, .Union, .Enum => {
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
