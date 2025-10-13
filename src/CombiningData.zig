const std = @import("std");
const builtin = @import("builtin");
const endian = builtin.cpu.arch.endian();
const flate = std.compress.flate;

s1: []const u16,
s2: []const u8,

const CombiningData = @This();

pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!CombiningData {
    var r: std.Io.Reader = .fixed(@embedFile("ccc"));
    var in_buf: [flate.max_window_len]u8 = undefined;
    var d: flate.Decompress = .init(&r, .gzip, &in_buf);
    const reader = &d.reader;

    const Header = extern struct {
        s1_len: u32,
        s2_len: u32,
    };

    const header = reader.takeStruct(Header, endian) catch unreachable;
    const bytes = try allocator.alignedAlloc(u8, .of(u16), header.s1_len * 2 + header.s2_len);
    const bytes_read = reader.readSliceShort(bytes) catch unreachable;
    std.debug.assert(bytes_read == header.s1_len * 2 + header.s2_len);

    const s1: []const u16 = @ptrCast(bytes[0 .. header.s1_len * 2]);
    const s2 = bytes[header.s1_len * 2 ..][0..header.s2_len];

    return .{
        .s1 = s1,
        .s2 = s2,
    };
}

pub fn deinit(cbdata: *const CombiningData, allocator: std.mem.Allocator) void {
    const ptr: [*]align(2) const u8 = @ptrCast(cbdata.s1.ptr);
    const slice = ptr[0 .. cbdata.s1.len * 2 + cbdata.s2.len];
    allocator.free(slice);
}

/// Returns the canonical combining class for a code point.
pub fn ccc(cbdata: CombiningData, cp: u21) u8 {
    return cbdata.s2[cbdata.s1[cp >> 8] + (cp & 0xff)];
}

/// True if `cp` is a starter code point, not a combining character.
pub fn isStarter(cbdata: CombiningData, cp: u21) bool {
    return cbdata.s2[cbdata.s1[cp >> 8] + (cp & 0xff)] == 0;
}
