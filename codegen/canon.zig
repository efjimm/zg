const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Process UnicodeData.txt
    var in_file = try std.fs.cwd().openFile("data/unicode/UnicodeData.txt", .{});
    defer in_file.close();
    var in_buf = std.io.bufferedReader(in_file.reader());
    const in_reader = in_buf.reader();

    var args_iter = try std.process.argsWithAllocator(allocator);
    defer args_iter.deinit();
    _ = args_iter.skip();
    const output_path = args_iter.next() orelse @panic("No output file arg!");

    const compressor = std.compress.flate.deflate.compressor;
    var out_file = try std.fs.cwd().createFile(output_path, .{});
    defer out_file.close();
    var out_comp = try compressor(.raw, out_file.writer(), .{ .level = .best });

    const endian = @import("options").target_endian;
    var line_buf: [4096]u8 = undefined;

    const Item = packed struct(u16) {
        n: u14,
        len: u2,
    };

    var cps: std.ArrayListUnmanaged(u32) = .empty;
    var nfd: std.ArrayListUnmanaged(Item) = .empty;

    const Map = std.AutoHashMapUnmanaged([2]u21, u21);
    var map: Map = .empty;

    try map.ensureTotalCapacity(allocator, 10_000);
    try cps.ensureTotalCapacity(allocator, 10_000);
    try nfd.ensureTotalCapacity(allocator, 0x100000);
    @memset(nfd.allocatedSlice(), .{ .n = 0, .len = 0 });

    lines: while (try in_reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
        if (line.len == 0) continue;

        var field_iter = std.mem.splitScalar(u8, line, ';');
        var buf: [2]u21 = undefined;
        var singleton: bool = true;

        var cp: u21 = undefined;
        var i: usize = 0;
        while (field_iter.next()) |field| : (i += 1) {
            switch (i) {
                0 => cp = try std.fmt.parseInt(u21, field, 16),

                5 => {
                    // Not canonical.
                    if (field.len == 0 or field[0] == '<') continue :lines;
                    if (std.mem.indexOfScalar(u8, field, ' ')) |space| {
                        // Canonical
                        singleton = false;
                        buf[0] = try std.fmt.parseInt(u21, field[0..space], 16);
                        buf[1] = try std.fmt.parseInt(u21, field[space + 1 ..], 16);
                        try map.put(allocator, buf, cp);
                    } else {
                        // Singleton
                        buf[0] = try std.fmt.parseInt(u21, field, 16);
                    }
                },

                2 => if (line[0] == '<') continue :lines,

                else => {},
            }
        }

        nfd.items.len = cp + 1;
        std.debug.assert(nfd.items.len <= nfd.capacity);
        const len: u2 = if (singleton) 1 else 2;
        nfd.items[cp] = .{
            .n = @intCast(cps.items.len),
            .len = len,
        };
        cps.appendSliceAssumeCapacity(@ptrCast(buf[0..len]));
    }

    const map_slice = hashmapAllocatedSlice([2]u21, u21, &map);
    const writer = out_comp.writer();
    try writer.writeInt(u32, @intCast(nfd.items.len), endian);
    try writer.writeInt(u32, @intCast(cps.items.len), endian);
    try writer.writeInt(u32, @intCast(map_slice.len), endian);
    try writer.writeInt(u32, map.size, endian);
    try writer.writeInt(u32, map.available, endian);
    for (cps.items) |i| try writer.writeInt(u32, i, endian);
    for (nfd.items) |i| try writer.writeInt(u16, @bitCast(i), endian);
    try writer.writeAll(map_slice);
    try out_comp.flush();
}

fn hashmapAllocatedSlice(K: type, V: type, self: *const std.AutoHashMapUnmanaged(K, V)) []const u8 {
    if (self.metadata == null) unreachable;

    const Header = struct {
        values: [*]V,
        keys: [*]K,
        capacity: std.AutoHashMapUnmanaged(K, V).Size,
    };

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

    const total_size = std.mem.alignForward(usize, vals_end, max_align);

    const ptr: [*]Header = @ptrCast(@alignCast(self.metadata.?));
    const slice = @as([*]align(max_align) u8, @alignCast(@ptrCast(ptr - 1)))[0..total_size];
    return slice;
}
