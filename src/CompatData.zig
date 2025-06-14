const std = @import("std");
const builtin = @import("builtin");

const magic = @import("magic");

const Slice = packed struct {
    offset: Offset,
    len: u5,

    const Offset = std.math.IntFittingRange(0, magic.compat_size);
};

comptime {
    std.debug.assert(@sizeOf(Slice) <= @sizeOf(u32));
}

nfkd: []Slice,
cps: []u21,

const CompatData = @This();

pub fn init(allocator: std.mem.Allocator) !CompatData {
    const in_bytes = @embedFile("compat");
    var in_fbs = std.io.fixedBufferStream(in_bytes);
    var in_decomp = std.compress.flate.inflate.decompressor(.raw, in_fbs.reader());
    var reader = in_decomp.reader();

    const Header = extern struct {
        items_len: u32,
        cps_len: u32,
        max_cp: u32,
    };

    const Item = packed struct(u32) {
        cp: u24,
        len: u8,
    };

    const header = reader.readStruct(Header) catch unreachable;
    const items = try allocator.alloc(Item, header.items_len);
    defer allocator.free(items);

    var bytes_read = reader.readAll(std.mem.sliceAsBytes(items)) catch unreachable;
    std.debug.assert(bytes_read == items.len * 4);

    const bytes = try allocator.alignedAlloc(
        u8,
        .max(.of(u21), .of(Slice)),
        header.cps_len * @sizeOf(u21) + (header.max_cp + 1) * @sizeOf(Slice),
    );
    errdefer allocator.free(bytes);

    const cps_start = @sizeOf(u21) * (header.max_cp + 1);
    const nkfd: []Slice = @ptrCast(bytes[0..cps_start]);
    const cps: []u21 = @ptrCast(@alignCast(bytes[cps_start..]));
    @memset(nkfd, .{ .offset = 0, .len = 0 });

    bytes_read = reader.readAll(std.mem.sliceAsBytes(cps)) catch unreachable;
    std.debug.assert(bytes_read == cps.len * @sizeOf(u21));

    var offset: Slice.Offset = 0;
    for (items) |item| {
        nkfd[item.cp] = .{
            .offset = offset,
            .len = @intCast(item.len),
        };
        offset += item.len;
    }

    return .{
        .nfkd = nkfd,
        .cps = cps,
    };
}

pub fn deinit(cpdata: *const CompatData, allocator: std.mem.Allocator) void {
    const ptr: [*]align(4) const u8 = @ptrCast(cpdata.nfkd.ptr);
    const total_size = std.mem.sliceAsBytes(cpdata.nfkd).len + std.mem.sliceAsBytes(cpdata.cps).len;
    allocator.free(ptr[0..total_size]);
}

/// Returns compatibility decomposition for `cp`.
pub fn toNfkd(cpdata: *const CompatData, cp: u21) []u21 {
    const slice = cpdata.nfkd[cp];
    return cpdata.cps[slice.offset..][0..slice.len];
}
