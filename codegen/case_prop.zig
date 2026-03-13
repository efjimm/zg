const std = @import("std");
const builtin = @import("builtin");
const unicode_data_path = @import("options").unicode_data_path;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const fromFile = @import("properties.zig").fromFile;
    const props_data_path = unicode_data_path ++ "/DerivedCoreProperties.txt";
    const s1, const s2 = try fromFile(arena, io, props_data_path, &.{
        "Lowercase",
        "Uppercase",
        "Cased",
    });

    const Codegen = @import("Codegen.zig");
    const c: *Codegen = try .create(init);

    try c.writeInt(u16, @intCast(s1.len));
    try c.writeInt(u16, @intCast(s2.len));
    for (s1) |i| try c.writeInt(u16, i);
    try c.writeAll(s2);

    try c.flush();
    std.process.cleanExit(io);
}
