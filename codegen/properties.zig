const std = @import("std");
const builtin = @import("builtin");
const unicode_data_path = @import("options").unicode_data_path;

const block_size = 256;
const Block = [block_size]u8;

const BlockMap = std.HashMap(
    Block,
    u16,
    struct {
        pub fn hash(_: @This(), k: Block) u64 {
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHashStrat(&hasher, k, .DeepRecursive);
            return hasher.final();
        }

        pub fn eql(_: @This(), a: Block, b: Block) bool {
            return std.mem.eql(u8, &a, &b);
        }
    },
    std.hash_map.default_max_load_percentage,
);

pub fn fromFile(
    allocator: std.mem.Allocator,
    filepath: []const u8,
    field_names: []const []const u8,
) !struct { []const u16, []const u8 } {
    var flat_map = std.AutoHashMap(u21, u8).init(allocator);
    defer flat_map.deinit();

    var line_buf: [4096]u8 = undefined;

    // Process DerivedNumericType.txt
    const in_file = try std.fs.cwd().openFile(filepath, .{});
    defer in_file.close();
    var in_buf = std.io.bufferedReader(in_file.reader());
    const in_reader = in_buf.reader();

    while (try in_reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const no_comment = if (std.mem.indexOfScalar(u8, line, '#')) |octo| line[0..octo] else line;

        var field_iter = std.mem.tokenizeAny(u8, no_comment, "; ");
        var current_code: [2]u21 = undefined;

        var i: usize = 0;
        while (field_iter.next()) |field| : (i += 1) {
            switch (i) {
                0 => {
                    // Code point(s)
                    if (std.mem.indexOf(u8, field, "..")) |dots| {
                        current_code = .{
                            try std.fmt.parseInt(u21, field[0..dots], 16),
                            try std.fmt.parseInt(u21, field[dots + 2 ..], 16),
                        };
                    } else {
                        const code = try std.fmt.parseInt(u21, field, 16);
                        current_code = .{ code, code };
                    }
                },
                1 => {
                    for (field_names, 0..) |name, j| {
                        if (std.mem.eql(u8, field, name)) {
                            const bit = @as(u8, 1) << @intCast(j);
                            for (current_code[0]..current_code[1] + 1) |cp| {
                                const gop = try flat_map.getOrPut(@intCast(cp));
                                if (!gop.found_existing) gop.value_ptr.* = 0;
                                gop.value_ptr.* |= bit;
                            }
                            break;
                        }
                    }
                },
                else => {},
            }
        }
    }

    var blocks_map = BlockMap.init(allocator);
    defer blocks_map.deinit();

    var stage1 = std.ArrayList(u16).init(allocator);
    defer stage1.deinit();

    var stage2 = std.ArrayList(u8).init(allocator);
    defer stage2.deinit();

    var block: Block = [_]u8{0} ** block_size;
    var block_len: u16 = 0;

    for (0..0x110000) |i| {
        const cp: u21 = @intCast(i);
        const nt = flat_map.get(cp) orelse 0;

        // Process block
        block[block_len] = nt;
        block_len += 1;

        if (block_len < block_size and cp != 0x10ffff) continue;

        const gop = try blocks_map.getOrPut(block);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(stage2.items.len);
            try stage2.appendSlice(&block);
        }

        try stage1.append(gop.value_ptr.*);
        block_len = 0;
    }

    return .{
        try stage1.toOwnedSlice(),
        try stage2.toOwnedSlice(),
    };
}
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var flat_map = std.AutoHashMap(u21, u8).init(allocator);
    defer flat_map.deinit();

    const core_path = unicode_data_path ++ "/DerivedCoreProperties.txt";
    const props_path = unicode_data_path ++ "/PropList.txt";
    const num_path = unicode_data_path ++ "/extracted/DerivedNumericType.txt";

    const s1, const s2 = try fromFile(allocator, core_path, &.{
        "Math",
        "Alphabetic",
        "ID_Start",
        "ID_Continue",
        "XID_Start",
        "XID_Continue",
    });

    const s3, const s4 = try fromFile(allocator, props_path, &.{
        "White_Space",
        "Hex_Digit",
        "Diacritic",
    });

    const s5, const s6 = try fromFile(allocator, num_path, &.{
        "Numeric",
        "Digit",
        "Decimal",
    });

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
    try writer.writeInt(u16, @intCast(s1.len), endian);
    try writer.writeInt(u16, @intCast(s2.len), endian);
    try writer.writeInt(u16, @intCast(s3.len), endian);
    try writer.writeInt(u16, @intCast(s4.len), endian);
    try writer.writeInt(u16, @intCast(s5.len), endian);
    try writer.writeInt(u16, @intCast(s6.len), endian);
    for (s1) |i| try writer.writeInt(u16, i, endian);
    try writer.writeAll(s2);
    for (s3) |i| try writer.writeInt(u16, i, endian);
    try writer.writeAll(s4);
    for (s5) |i| try writer.writeInt(u16, i, endian);
    try writer.writeAll(s6);

    try out_comp.flush();
}
