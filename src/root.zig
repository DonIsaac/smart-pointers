const std = @import("std");
const testing = std.testing;

pub const Arc = @import("Arc.zig").Arc;
pub const Boo = @import("Boo.zig").Boo;

test {
    std.testing.refAllDecls(@This());
}
