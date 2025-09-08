const std = @import("std");
const Allocator = std.mem.Allocator;

const Options = struct {
    Len: type = u32,
    Header: type = void,
    T: type = u8,
};

/// A dynamically sized type containing a slice of data and prefixed with a
/// header.
/// 
/// DSTs are always heap allocated.
pub fn Dst(comptime options: Options) type {
    return opaque {
        pub const Header = options.Header;
        pub const Len = options.Len;
        pub const T = options.T;

        const Frontmatter = struct {
            len: Len,
            header: Header,
        };
        const alignment: std.mem.Alignment = .max(.of(Frontmatter), .of(options.T));

        const Self = @This();

        /// Allocate a new DST. Its header and data slice will not be initialized.
        pub fn createUninitialized(allocator: Allocator, len: Len) Allocator.Error!*Self {
            const frontmatter = Frontmatter{ .len = len, .header = undefined };
            const alloc_size = @sizeOf(Frontmatter) + (len * @sizeOf(options.T));
            // const nbytes = @
            const bytes = try allocator.alignedAlloc(u8, alignment, alloc_size);
            @memcpy(bytes[0..@sizeOf(Frontmatter)], &frontmatter);
            return @ptrCast(bytes);
        }

        pub fn init(allocator: Allocator, header_: Header, data: []const T) Allocator.Error!*Self {
            const frontmatter = Frontmatter{
                .len = @intCast(data.len),
                .header = header_,
            };
            const alloc_size = @sizeOf(Frontmatter) + (data.len * @sizeOf(options.T));
            // const nbytes = @
            const bytes = try allocator.alignedAlloc(u8, alignment, alloc_size);
            const frontmatter_bytes: [*]const u8 = @alignCast(@ptrCast(&frontmatter));
            @memcpy(bytes[0..@sizeOf(Frontmatter)], frontmatter_bytes);
            @memcpy(bytes[@sizeOf(Frontmatter)..], data);
            return @ptrCast(bytes);
        }

        /// The number of elements stored in the DST. This is equivalent to,
        /// but faster than, calling `dst.slice().len`.
        pub fn size(self: *const Self) Len {
            const frontmatter: *const Frontmatter = @alignCast(@ptrCast(self));
            return frontmatter.len;
        }

        pub fn header(self: *Self) *Header {
            const frontmatter: *Frontmatter = @alignCast(@ptrCast(self));
            return &frontmatter.header;
        }

        /// Get the data stored in this DST as a slice.
        pub fn slice(self: *Self) []T {
            // const frontmatter: *Frontmatter = @alignCast(@ptrCast(self));
            const len = self.size();
            const bytes: [*]u8 = @ptrCast(self);
            const data_start: [*]u8 = @ptrCast(bytes[@sizeOf(Frontmatter)..]);
            return @as([*]T, @ptrCast(@alignCast(data_start)))[0..len];
            // const data_slice
            // const data =
            // return frontmatter[1..frontmatter.len];
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            const raw_bytes: [*]align(alignment.toByteUnits()) u8 = @alignCast(@ptrCast(self));
            const slice_ = raw_bytes[0..bytelen(self.size())];
            allocator.free(slice_);
        }

        fn bytelen(len: Len) usize {
            return @sizeOf(Frontmatter) + (len * @sizeOf(options.T));
        }
    };
}

const t = std.testing;
test Dst {
    const Header = struct { hash: u64 };
    const data = "boopity";
    const header: Header = .{
        .hash = std.hash.Fnv1a_64.hash(data),
    };

    var dst = try Dst(.{ .Header = Header }).init(t.allocator, header, data);
    defer dst.deinit(t.allocator);

    try t.expectEqual(data.len, dst.size());
    try t.expectEqual(header.hash, dst.header().hash);
    try t.expectEqualStrings(data, dst.slice());
}

test "DST with ZST header" {
    const data = "boopity";

    var dst = try Dst(.{}).init(t.allocator, undefined, data);
    defer dst.deinit(t.allocator);

    try t.expectEqual(data.len, dst.size());
    try t.expectEqualStrings(data, dst.slice());
}
