const std = @import("std");
const builtin = @import("builtin");

const magic = @import("magic");
const options = @import("options");

const Item = packed struct(u16) {
    offset: u14,
    len: u2,
};

nfc: std.AutoHashMapUnmanaged([2]u21, u21),
nfd: []const Item,
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
        map_slice_len: u32,
        map_size: u32,
        map_available: u32,
    };

    const header = reader.readStruct(Header) catch unreachable;
    const total_size = header.nfd_len * 2 + header.cps_len * 4 + header.map_slice_len;
    const bytes = try allocator.alignedAlloc(u8, .of(u64), total_size);
    const bytes_read = reader.readAll(bytes) catch unreachable;
    std.debug.assert(bytes_read == total_size);

    const cps: []const u21 = @ptrCast(bytes[0 .. header.cps_len * 4]);
    const nfd: []const Item = @ptrCast(@alignCast(bytes[header.cps_len * 4 ..][0 .. header.nfd_len * 2]));
    const map_slice = bytes[header.nfd_len * 2 + header.cps_len * 4 ..][0..header.map_slice_len];

    const MapHeader = HashMapHeader([2]u21, u21);
    var map: @FieldType(CanonData, "nfc") = .{
        .metadata = @ptrCast(@alignCast(map_slice.ptr + @sizeOf(MapHeader))),
        .size = header.map_size,
        .available = header.map_available,
        .pointer_stability = .{},
    };

    const map_cap = map.capacity();
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
    map_header.values = @ptrCast(@alignCast(map_slice.ptr + vals_start));
    map_header.keys = @ptrCast(@alignCast(map_slice.ptr + keys_start));

    return .{
        .nfd = nfd,
        .cps = cps,
        .nfc = map,
    };
}

pub fn deinit(cdata: *const CanonData, allocator: std.mem.Allocator) void {
    const map_size = hashMapAllocSize([2]u21, u21, &cdata.nfc);
    const total_size = cdata.nfd.len * 2 + cdata.cps.len * 4 + map_size;
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

fn hashMapAllocSize(K: type, V: type, self: *const std.AutoHashMapUnmanaged(K, V)) usize {
    if (self.metadata == null) unreachable;

    const Header = HashMapHeader(K, V);
    const Metadata = u8;

    const header_align = @alignOf(Header);
    const key_align = if (@sizeOf(K) == 0) 1 else @alignOf(K);
    const val_align = if (@sizeOf(V) == 0) 1 else @alignOf(V);
    const max_align = comptime @max(header_align, key_align, val_align);

    const cap: usize = self.capacity();
    const meta_size = @sizeOf(Header) + cap * @sizeOf(Metadata);
    comptime std.debug.assert(@alignOf(Metadata) == 1);

    const keys_start = std.mem.alignForward(usize, meta_size, key_align);
    const keys_end = keys_start + cap * @sizeOf(K);

    const vals_start = std.mem.alignForward(usize, keys_end, val_align);
    const vals_end = vals_start + cap * @sizeOf(V);

    return std.mem.alignForward(usize, vals_end, max_align);
}
