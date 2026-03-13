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

    const T = extern struct {
        cp: u32,
        /// These store the offset to the target codepoint from `cp` as it compresses better.
        lower: i32,
        upper: i32,
    };

    var out_buf: std.ArrayListUnmanaged(T) = .empty;
    try out_buf.ensureTotalCapacity(arena, 10_000);

    lines: while (try in_reader.interface.takeDelimiter('\n')) |line| {
        if (line.len == 0) continue;

        var field_iter = std.mem.splitScalar(u8, line, ';');
        var cp: u21 = undefined;
        var lower: i24 = 0;
        var upper: i24 = 0;

        var i: usize = 0;
        while (field_iter.next()) |field| : (i += 1) {
            switch (i) {
                0 => cp = try std.fmt.parseInt(u21, field, 16),
                2 => {
                    if (line[0] == '<') continue :lines;
                },
                12 => {
                    // Simple uppercase mapping
                    if (field.len != 0) {
                        const mapping = try std.fmt.parseInt(i24, field, 16);
                        lower = mapping - cp;
                    }
                },
                13 => {
                    // Simple lowercase mapping
                    if (field.len != 0) {
                        const mapping = try std.fmt.parseInt(i24, field, 16);
                        upper = mapping - cp;
                    }
                    break;
                },
                else => {},
            }
        }

        if (lower != 0 or upper != 0) {
            try out_buf.append(arena, .{ .cp = cp, .lower = lower, .upper = upper });
        }
    }

    try c.writeInt(u32, @intCast(out_buf.items.len));
    for (out_buf.items) |arr| {
        try c.writeStruct(arr);
    }
    try c.flush();
    std.process.cleanExit(io);
}
