const std = @import("std");
const builtin = @import("builtin");

const magic = @import("magic");
const options = @import("options");

const Slice = packed struct(u16) {
    offset: u14,
    len: u2,
};

nfc: std.AutoHashMapUnmanaged([2]u21, u21),
nfd: []const Slice,
cps: []const u21,

const CanonData = @This();

pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!CanonData {
    const in_bytes = @embedFile("canon");
    var in_fbs = std.io.fixedBufferStream(in_bytes);
    var in_decomp = std.compress.flate.inflate.decompressor(.raw, in_fbs.reader());
    var reader = in_decomp.reader();

    const Header = extern struct {
        nfd_len: u32,
        cps_len: u32,
        map_size: u32,
    };

    const Nfd = packed struct(u32) {
        cp: u24,
        len: u8,
    };

    const header = reader.readStruct(Header) catch unreachable;
    const idk_size = @sizeOf(Nfd) * @as(usize, header.nfd_len);
    const cps_size = @sizeOf(u21) * @as(usize, header.cps_len);
    const nfd_cps = try allocator.alloc(Nfd, header.nfd_len);
    defer allocator.free(nfd_cps);

    var bytes_read = reader.readAll(std.mem.sliceAsBytes(nfd_cps)) catch unreachable;
    std.debug.assert(bytes_read == idk_size);
    const max_cp = nfd_cps[nfd_cps.len - 1].cp;

    const map_cap = header.map_size;
    const nfd_size = (max_cp + 1) * @sizeOf(Slice);
    const total_size = nfd_size + cps_size + hashMapAllocSize([2]u21, u21, map_cap);
    const bytes = try allocator.alignedAlloc(u8, .of(u64), total_size);
    errdefer allocator.free(bytes);
    bytes_read = reader.readAll(bytes[0..cps_size]) catch unreachable;
    std.debug.assert(bytes_read == cps_size);

    const cps: []const u21 = @ptrCast(bytes[0..cps_size]);
    const nfd: []Slice = @ptrCast(@alignCast(bytes[cps_size..][0..nfd_size]));
    const map_slice = bytes[cps_size + nfd_size ..];
    @memset(map_slice, 0);

    const MapHeader = HashMapHeader([2]u21, u21);
    var map: std.AutoHashMapUnmanaged([2]u21, u21) = .{
        .metadata = @ptrCast(@alignCast(map_slice.ptr + @sizeOf(MapHeader))),
        .size = 0,
        .available = map_cap,
        .pointer_stability = .{},
    };
    const keys_start = std.mem.alignForward(
        usize,
        @sizeOf(MapHeader) + map_cap,
        @alignOf([2]u21),
    );
    const vals_start = std.mem.alignForward(
        usize,
        @sizeOf(MapHeader) + map_cap + map_cap * @sizeOf([2]u21),
        @alignOf(u21),
    );

    const map_header: *MapHeader = @ptrCast(@alignCast(map_slice.ptr));
    map_header.* = .{
        .values = @ptrCast(@alignCast(map_slice.ptr + vals_start)),
        .keys = @ptrCast(@alignCast(map_slice.ptr + keys_start)),
        .capacity = map_cap,
    };
    std.debug.assert(map.capacity() == map_cap);

    @memset(nfd, .{ .offset = 0, .len = 0 });

    var offset: u14 = 0;
    for (nfd_cps) |n| {
        nfd[n.cp] = .{ .offset = offset, .len = @intCast(n.len) };
        if (n.len == 2) {
            map.putAssumeCapacity(cps[offset..][0..2].*, @intCast(n.cp));
        }
        offset += n.len;
    }

    return .{
        .nfd = nfd,
        .cps = cps,
        .nfc = map,
    };
}

pub fn deinit(cdata: *const CanonData, allocator: std.mem.Allocator) void {
    const total_size =
        cdata.nfd.len * @sizeOf(Slice) +
        cdata.cps.len * @sizeOf(u21) +
        hashMapAllocSize([2]u21, u21, cdata.nfc.capacity());

    const ptr: [*]const u8 = @ptrCast(cdata.cps.ptr);
    const slice = ptr[0..total_size];
    allocator.free(slice);
}

/// Returns canonical decomposition for `cp`.
pub fn toNfd(cdata: *const CanonData, cp: u21) []const u21 {
    const item = cdata.nfd[cp];
    return cdata.cps[item.offset..][0..item.len];
}

// Returns the primary composite for the codepoints in `cp`.
pub fn toNfc(cdata: *const CanonData, cps: [2]u21) ?u21 {
    return cdata.nfc.get(cps);
}

fn HashMapHeader(K: type, V: type) type {
    return struct {
        values: [*]V,
        keys: [*]K,
        capacity: std.AutoHashMap(K, V).Size,
    };
}

fn hashMapAllocSize(K: type, V: type, cap: u32) usize {
    const Header = HashMapHeader(K, V);
    const Metadata = u8;

    const header_align = @alignOf(Header);
    const key_align = if (@sizeOf(K) == 0) 1 else @alignOf(K);
    const val_align = if (@sizeOf(V) == 0) 1 else @alignOf(V);
    const max_align = comptime @max(header_align, key_align, val_align);

    const meta_size = @sizeOf(Header) + cap * @sizeOf(Metadata);
    comptime std.debug.assert(@alignOf(Metadata) == 1);

    const keys_start = std.mem.alignForward(usize, meta_size, key_align);
    const keys_end = keys_start + cap * @sizeOf(K);

    const vals_start = std.mem.alignForward(usize, keys_end, val_align);
    const vals_end = vals_start + cap * @sizeOf(V);

    return std.mem.alignForward(usize, vals_end, max_align);
}
