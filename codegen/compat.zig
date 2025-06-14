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
    const writer = out_comp.writer();

    const endian = @import("options").target_endian;
    var line_buf: [4096]u8 = undefined;

    const Item = packed struct(u32) {
        cp: u24,
        len: u8,
    };
    var items: std.ArrayListUnmanaged(Item) = .empty;
    var out_cps: std.ArrayListUnmanaged(u32) = .empty;
    var max_cp: u24 = 0;

    try items.ensureTotalCapacity(allocator, 10_000);
    try out_cps.ensureTotalCapacity(allocator, 10_000);

    lines: while (try in_reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
        if (line.len == 0) continue;

        var field_iter = std.mem.splitScalar(u8, line, ';');
        var cps: std.BoundedArray(u32, 18) = .{};
        var index_cp: u24 = undefined;

        var i: usize = 0;
        while (field_iter.next()) |field| : (i += 1) {
            switch (i) {
                0 => index_cp = try std.fmt.parseInt(u24, field, 16),

                5 => {
                    // Not compatibility.
                    if (field.len == 0 or field[0] != '<') continue :lines;
                    var cp_iter = std.mem.tokenizeScalar(u8, field, ' ');
                    _ = cp_iter.next(); // <compat type>

                    while (cp_iter.next()) |cp_str| {
                        const cp = try std.fmt.parseInt(u24, cp_str, 16);
                        cps.appendAssumeCapacity(cp);
                    }
                },

                2 => if (line[0] == '<') continue :lines,

                else => {},
            }
        }

        std.debug.assert(cps.len >= 1);
        max_cp = index_cp;
        try items.append(allocator, .{
            .cp = index_cp,
            .len = @intCast(cps.len),
        });
        try out_cps.appendSlice(allocator, cps.constSlice());
    }

    try writer.writeInt(u32, @intCast(items.items.len), endian);
    try writer.writeInt(u32, @intCast(out_cps.items.len), endian);
    try writer.writeInt(u32, max_cp, endian);
    for (items.items) |item| try writer.writeStructEndian(item, endian);
    for (out_cps.items) |cp| try writer.writeInt(u32, cp, endian);

    try out_comp.flush();
}
