const std = @import("std");
const flate = std.compress.flate;
const builtin = @import("builtin");
const unicode_data_path = @import("options").unicode_data_path;

const Indic = enum {
    none,

    Consonant,
    Extend,
    Linker,
};

const Gbp = enum {
    none,

    Control,
    CR,
    Extend,
    L,
    LF,
    LV,
    LVT,
    Prepend,
    Regional_Indicator,
    SpacingMark,
    T,
    V,
    ZWJ,
};

const block_size = 256;
const Block = [block_size]u16;

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
            return std.mem.eql(u16, &a, &b);
        }
    },
    std.hash_map.default_max_load_percentage,
);

pub fn main() !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded: std.Io.Threaded = .init(arena);
    defer threaded.deinit();
    const io = threaded.ioBasic();

    var indic_map = std.AutoHashMap(u21, Indic).init(arena);
    defer indic_map.deinit();

    var gbp_map = std.AutoHashMap(u21, Gbp).init(arena);
    defer gbp_map.deinit();

    var emoji_set = std.AutoHashMap(u21, void).init(arena);
    defer emoji_set.deinit();

    // Process Indic
    const indic_data_path = unicode_data_path ++ "/DerivedCoreProperties.txt";
    var indic_file = try std.fs.cwd().openFile(indic_data_path, .{});
    defer indic_file.close();
    var buf: [4096]u8 = undefined;
    var indic_reader = indic_file.reader(io, &buf);

    while (try indic_reader.interface.takeDelimiter('\n')) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.indexOf(u8, line, "InCB") == null) continue;
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
                2 => {
                    // Prop
                    const prop = std.meta.stringToEnum(Indic, field) orelse return error.InvalidPorp;
                    for (current_code[0]..current_code[1] + 1) |cp| try indic_map.put(@intCast(cp), prop);
                },
                else => {},
            }
        }
    }

    // Process GBP
    const gbp_data_path = unicode_data_path ++ "/auxiliary/GraphemeBreakProperty.txt";
    var gbp_file = try std.fs.cwd().openFile(gbp_data_path, .{});
    defer gbp_file.close();
    var gbp_reader = gbp_file.reader(io, &buf);

    while (try gbp_reader.interface.takeDelimiter('\n')) |line| {
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
                    // Prop
                    const prop = std.meta.stringToEnum(Gbp, field) orelse return error.InvalidPorp;
                    for (current_code[0]..current_code[1] + 1) |cp| try gbp_map.put(@intCast(cp), prop);
                },
                else => {},
            }
        }
    }

    // Process Emoji
    const emoji_data_path = unicode_data_path ++ "/emoji/emoji-data.txt";
    var emoji_file = try std.fs.cwd().openFile(emoji_data_path, .{});
    defer emoji_file.close();
    var emoji_reader = emoji_file.reader(io, &buf);

    while (try emoji_reader.interface.takeDelimiter('\n')) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.indexOf(u8, line, "Extended_Pictographic") == null) continue;
        const no_comment = if (std.mem.indexOfScalar(u8, line, '#')) |octo| line[0..octo] else line;

        var field_iter = std.mem.tokenizeAny(u8, no_comment, "; ");

        var i: usize = 0;
        while (field_iter.next()) |field| : (i += 1) {
            switch (i) {
                0 => {
                    // Code point(s)
                    if (std.mem.indexOf(u8, field, "..")) |dots| {
                        const from = try std.fmt.parseInt(u21, field[0..dots], 16);
                        const to = try std.fmt.parseInt(u21, field[dots + 2 ..], 16);
                        for (from..to + 1) |cp| try emoji_set.put(@intCast(cp), {});
                    } else {
                        const cp = try std.fmt.parseInt(u21, field, 16);
                        try emoji_set.put(@intCast(cp), {});
                    }
                },
                else => {},
            }
        }
    }

    var blocks_map = BlockMap.init(arena);
    defer blocks_map.deinit();

    var stage1: std.ArrayList(u16) = .empty;
    var stage2: std.ArrayList(u16) = .empty;
    var stage3 = std.AutoArrayHashMap(u8, u16).init(arena);
    defer stage3.deinit();
    var stage3_len: u16 = 0;

    var block: Block = @splat(0);
    var block_len: u16 = 0;

    for (0..0x110000) |i| {
        const cp: u21 = @intCast(i);
        const gbp_prop: u8 = @intFromEnum(gbp_map.get(cp) orelse .none);
        const indic_prop: u8 = @intFromEnum(indic_map.get(cp) orelse .none);
        const emoji_prop: u1 = @intFromBool(emoji_set.contains(cp));
        var props_byte: u8 = gbp_prop << 4;
        props_byte |= indic_prop << 1;
        props_byte |= emoji_prop;

        const stage3_idx = blk: {
            const gop = try stage3.getOrPut(props_byte);
            if (!gop.found_existing) {
                gop.value_ptr.* = stage3_len;
                stage3_len += 1;
            }

            break :blk gop.value_ptr.*;
        };

        block[block_len] = stage3_idx;
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

    const props_bytes = stage3.keys();
    try writer.writeInt(u32, @intCast(stage1.items.len), endian);
    try writer.writeInt(u32, @intCast(stage2.items.len), endian);
    try writer.writeInt(u32, @intCast(props_bytes.len), endian);

    for (stage1.items) |i| try writer.writeInt(u16, i, endian);
    for (stage2.items) |i| try writer.writeInt(u16, i, endian);
    try writer.writeAll(props_bytes);

    try writer.flush();
    std.process.cleanExit();
}
