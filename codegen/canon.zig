const std = @import("std");
const builtin = @import("builtin");
const unicode_data_path = @import("options").unicode_data_path;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    // Process UnicodeData.txt
    const data_path = unicode_data_path ++ "/UnicodeData.txt";
    var in_file = try std.Io.Dir.cwd().openFile(io, data_path, .{});
    defer in_file.close(io);
    var in_buf: [4096]u8 = undefined;
    var in_reader = in_file.reader(io, &in_buf);

    const Codegen = @import("Codegen.zig");
    const c: *Codegen = try .create(init);

    const Item = packed struct(u32) {
        cp: u24,
        len: u8,
    };

    var cps: std.ArrayListUnmanaged(u32) = .empty;
    var nfd: std.ArrayListUnmanaged(Item) = .empty;

    const Map = std.AutoHashMapUnmanaged([2]u21, u21);
    var map: Map = .empty;

    try map.ensureTotalCapacity(arena, 10_000);
    try cps.ensureTotalCapacity(arena, 10_000);
    try nfd.ensureTotalCapacity(arena, 10_000);

    lines: while (try in_reader.interface.takeDelimiter('\n')) |line| {
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
                        try map.put(arena, buf, cp);
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
        try nfd.append(arena, .{
            .cp = cp,
            .len = len,
        });
        cps.appendSliceAssumeCapacity(@ptrCast(buf[0..len]));
    }

    try c.writeInt(u32, @intCast(nfd.items.len));
    try c.writeInt(u32, @intCast(cps.items.len));
    try c.writeInt(u32, map.capacity());
    for (nfd.items) |i| try c.writeStruct(i);
    for (cps.items) |i| try c.writeInt(u32, i);
    try c.flush();
    std.process.cleanExit(io);
}
