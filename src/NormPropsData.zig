const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

s1: []u16,
s2: []u4,

const NormProps = @This();

pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!NormProps {
    var in_fbs = std.io.fixedBufferStream(@embedFile("normp"));
    var in_decomp = std.compress.flate.inflate.decompressor(.raw, in_fbs.reader());
    var reader = in_decomp.reader();

    const Header = extern struct {
        s1_len: u16,
        s2_len: u16,
    };

    const header = reader.readStruct(Header) catch unreachable;
    const total_size = @as(usize, header.s1_len) * 2 + header.s2_len;
    const bytes = try allocator.alignedAlloc(u8, .of(u16), total_size);
    errdefer allocator.free(bytes);
    const bytes_read = reader.readAll(bytes) catch unreachable;
    std.debug.assert(bytes_read == total_size);

    return .{
        .s1 = @ptrCast(bytes[0 .. header.s1_len * 2]),
        .s2 = @ptrCast(bytes[header.s1_len * 2 ..]),
    };
}

pub fn deinit(norms: *const NormProps, allocator: std.mem.Allocator) void {
    const ptr: [*]align(2) const u8 = @ptrCast(norms.s1.ptr);
    const total_size = norms.s1.len * 2 + norms.s2.len;
    allocator.free(ptr[0..total_size]);
}

/// Returns true if `cp` is already in NFD form.
pub fn isNfd(norms: *const NormProps, cp: u21) bool {
    return norms.s2[norms.s1[cp >> 8] + (cp & 0xff)] & 1 == 0;
}

/// Returns true if `cp` is already in NFKD form.
pub fn isNfkd(norms: *const NormProps, cp: u21) bool {
    return norms.s2[norms.s1[cp >> 8] + (cp & 0xff)] & 2 == 0;
}

/// Returns true if `cp` is not allowed in any normalized form.
pub fn isFcx(norms: *const NormProps, cp: u21) bool {
    return norms.s2[norms.s1[cp >> 8] + (cp & 0xff)] & 4 == 4;
}
