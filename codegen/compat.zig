const std = @import("std");
const builtin = @import("builtin");
const unicode_data_path = @import("options").unicode_data_path;

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded: std.Io.Threaded = .init(arena);
    defer threaded.deinit();
    const io = threaded.ioBasic();

    // Process UnicodeData.txt
    const unicode_data = unicode_data_path ++ "/UnicodeData.txt";
    var in_file = try std.fs.cwd().openFile(unicode_data, .{});
    defer in_file.close();
    var in_buf: [4096]u8 = undefined;
    var in_reader = in_file.reader(io, &in_buf);

    const codegen = @import("common.zig");
    const writer = codegen.output();
    defer codegen.finish();

    const endian = @import("options").target_endian;

    const Item = packed struct(u32) {
        cp: u24,
        len: u8,
    };
    var items: std.ArrayListUnmanaged(Item) = .empty;
    var out_cps: std.ArrayListUnmanaged(u32) = .empty;
    var max_cp: u24 = 0;

    try items.ensureTotalCapacity(arena, 10_000);
    try out_cps.ensureTotalCapacity(arena, 10_000);

    lines: while (try in_reader.interface.takeDelimiter('\n')) |line| {
        if (line.len == 0) continue;

        var field_iter = std.mem.splitScalar(u8, line, ';');
        var b: [18]u32 = undefined;
        var cps: std.ArrayListUnmanaged(u32) = .initBuffer(&b);
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

        std.debug.assert(cps.items.len >= 1);
        max_cp = index_cp;
        try items.append(arena, .{
            .cp = index_cp,
            .len = @intCast(cps.items.len),
        });
        try out_cps.appendSlice(arena, cps.items);
    }

    try writer.writeInt(u32, @intCast(items.items.len), endian);
    try writer.writeInt(u32, @intCast(out_cps.items.len), endian);
    try writer.writeInt(u32, max_cp, endian);
    for (items.items) |item| try writer.writeStruct(item, endian);
    for (out_cps.items) |cp| try writer.writeInt(u32, cp, endian);

    try writer.flush();
    std.process.cleanExit();
}
