const std = @import("std");
const builtin = @import("builtin");
const unicode_data_path = @import("options").unicode_data_path;

const block_size = 256;
const Block = [block_size]u3;

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
            return std.mem.eql(u3, &a, &b);
        }
    },
    std.hash_map.default_max_load_percentage,
);

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded: std.Io.Threaded = .init(arena);
    defer threaded.deinit();
    const io = threaded.ioBasic();

    var flat_map = std.AutoHashMap(u21, u3).init(arena);
    defer flat_map.deinit();

    var buf: [4096]u8 = undefined;

    // Process DerivedNormalizationProps.txt
    const data_path = unicode_data_path ++ "/DerivedNormalizationProps.txt";
    var in_file = try std.fs.cwd().openFile(data_path, .{});
    defer in_file.close();
    var in_reader = in_file.reader(io, &buf);

    while (try in_reader.interface.takeDelimiter('\n')) |line| {
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
                    // Norm props
                    for (current_code[0]..current_code[1] + 1) |cp| {
                        const gop = try flat_map.getOrPut(@intCast(cp));
                        if (!gop.found_existing) gop.value_ptr.* = 0;

                        if (std.mem.eql(u8, field, "NFD_QC")) {
                            gop.value_ptr.* |= 1;
                        } else if (std.mem.eql(u8, field, "NFKD_QC")) {
                            gop.value_ptr.* |= 2;
                        } else if (std.mem.eql(u8, field, "Full_Composition_Exclusion")) {
                            gop.value_ptr.* |= 4;
                        }
                    }
                },
                else => {},
            }
        }
    }

    var blocks_map = BlockMap.init(arena);
    var stage1: std.ArrayList(u16) = .empty;
    var stage2: std.ArrayList(u3) = .empty;

    var block: Block = @splat(0);
    var block_len: u16 = 0;

    for (0..0x110000) |i| {
        const cp: u21 = @intCast(i);
        const props = flat_map.get(cp) orelse 0;

        // Process block
        block[block_len] = props;
        block_len += 1;

        if (block_len < block_size and cp != 0x10ffff) continue;

        const gop = try blocks_map.getOrPut(block);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(stage2.items.len);
            try stage2.appendSlice(arena, &block);
        }

        try stage1.append(arena, gop.value_ptr.*);
        block_len = 0;
    }

    const codegen = @import("common.zig");
    const writer = codegen.output();
    defer codegen.finish();

    const endian = @import("options").target_endian;
    try writer.writeInt(u16, @intCast(stage1.items.len), endian);
    try writer.writeInt(u16, @intCast(stage2.items.len), endian);
    for (stage1.items) |i| try writer.writeInt(u16, i, endian);
    for (stage2.items) |i| try writer.writeInt(u8, i, endian);

    try writer.flush();
    std.process.cleanExit();
}
