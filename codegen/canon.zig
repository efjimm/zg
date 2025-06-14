const std = @import("std");
const builtin = @import("builtin");
const unicode_data_path = @import("options").unicode_data_path;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Process UnicodeData.txt
    const data_path = unicode_data_path ++ "/UnicodeData.txt";
    var in_file = try std.fs.cwd().openFile(data_path, .{});
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

    const Item = packed struct(u32) {
        cp: u24,
        len: u8,
    };

    var cps: std.ArrayListUnmanaged(u32) = .empty;
    var nfd: std.ArrayListUnmanaged(Item) = .empty;

    const Map = std.AutoHashMapUnmanaged([2]u21, u21);
    var map: Map = .empty;

    try map.ensureTotalCapacity(allocator, 10_000);
    try cps.ensureTotalCapacity(allocator, 10_000);
    try nfd.ensureTotalCapacity(allocator, 10_000);

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

        const len: u2 = if (singleton) 1 else 2;
        try nfd.append(allocator, .{
            .cp = cp,
            .len = len,
        });
        cps.appendSliceAssumeCapacity(@ptrCast(buf[0..len]));
    }

    const writer = out_comp.writer();
    try writer.writeInt(u32, @intCast(nfd.items.len), endian);
    try writer.writeInt(u32, @intCast(cps.items.len), endian);
    try writer.writeInt(u32, map.capacity(), endian);
    for (nfd.items) |i| try writer.writeStructEndian(i, endian);
    for (cps.items) |i| try writer.writeInt(u32, i, endian);
    try out_comp.flush();
}
