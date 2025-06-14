const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const fromFile = @import("properties.zig").fromFile;
    const s1, const s2 = try fromFile(allocator, "data/unicode/DerivedCoreProperties.txt", &.{
        "Lowercase",
        "Uppercase",
        "Cased",
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
    for (s1) |i| try writer.writeInt(u16, i, endian);
    try writer.writeAll(s2);

    try out_comp.flush();
}
