const std = @import("std");

pub const Syllable = enum { none, L, LV, LVT, V, T };

s1: []u16,
s2: []u3,

const Hangul = @This();

pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Hangul {
    const in_bytes = @embedFile("hangul");
    var in_fbs = std.io.fixedBufferStream(in_bytes);
    var in_decomp = std.compress.flate.inflate.decompressor(.raw, in_fbs.reader());
    var reader = in_decomp.reader();

    const Header = extern struct {
        s1_len: u16,
        s2_len: u16,
    };

    const header = reader.readStruct(Header) catch unreachable;
    const s1_size = @as(usize, header.s1_len) * 2;
    const total_size = s1_size + header.s2_len;
    const bytes = try allocator.alignedAlloc(u8, .of(u16), total_size);
    errdefer allocator.free(bytes);
    const bytes_read = reader.readAll(bytes) catch unreachable;
    std.debug.assert(bytes_read == total_size);

    return .{
        .s1 = @ptrCast(bytes[0..s1_size]),
        .s2 = @ptrCast(bytes[s1_size..]),
    };
}

pub fn deinit(hangul: *const Hangul, allocator: std.mem.Allocator) void {
    const ptr: [*]align(2) const u8 = @ptrCast(hangul.s1.ptr);
    const total_size = hangul.s1.len * 2 + hangul.s2.len;
    allocator.free(ptr[0..total_size]);
}

/// Returns the Hangul syllable type for `cp`.
pub fn syllable(hangul: *const Hangul, cp: u21) Syllable {
    return @enumFromInt(hangul.s2[hangul.s1[cp >> 8] + (cp & 0xff)]);
}
