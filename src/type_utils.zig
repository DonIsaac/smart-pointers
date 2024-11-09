const std = @import("std");
const Type = std.builtin.Type;

pub fn innerType(comptime ty: Type) Type {
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
