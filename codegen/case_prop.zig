const std = @import("std");
const builtin = @import("builtin");
const unicode_data_path = @import("options").unicode_data_path;

pub fn main() !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded: std.Io.Threaded = .init(arena);
    defer threaded.deinit();
    const io = threaded.ioBasic();

    const fromFile = @import("properties.zig").fromFile;
    const props_data_path = unicode_data_path ++ "/DerivedCoreProperties.txt";
    const s1, const s2 = try fromFile(arena, io, props_data_path, &.{
        "Lowercase",
        "Uppercase",
        "Cased",
    });

    const codegen = @import("common.zig");
    const writer = codegen.output();
    defer codegen.finish();

    const endian = @import("options").target_endian;
    try writer.writeInt(u16, @intCast(s1.len), endian);
    try writer.writeInt(u16, @intCast(s2.len), endian);
    for (s1) |i| try writer.writeInt(u16, i, endian);
    try writer.writeAll(s2);

    try writer.flush();
}
