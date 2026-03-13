//! Common functionality shared across codegen files.
const std = @import("std");
const Codegen = @This();

compress: std.compress.flate.Compress,
compress_buffer: [std.compress.flate.max_window_len]u8,

output_file: std.Io.File,
output_file_writer: std.Io.File.Writer,
output_buffer: [8192]u8,

pub fn create(init: std.process.Init) !*Codegen {
    const c = try init.arena.allocator().create(Codegen);
    const output_path = std.mem.span(init.minimal.args.vector[1]);
    c.output_file = try std.Io.Dir.cwd().createFile(init.io, output_path, .{});
    c.output_file_writer = c.output_file.writer(init.io, &c.output_buffer);
    c.compress = try .init(&c.output_file_writer.interface, &c.compress_buffer, .gzip, .best);
    return c;
}

pub fn flush(c: *Codegen) !void {
    try c.compress.finish();
    try c.output_file_writer.flush();
}

pub fn writer(c: *Codegen) *std.Io.Writer {
    return &c.compress.writer;
}

/// Writes an integer with the correct endianness.
pub fn writeInt(c: *Codegen, T: type, int: T) !void {
    const endian = @import("options").target_endian;
    try c.writer().writeInt(T, int, endian);
}

/// Writes a struct with the correct endianness.
pub fn writeStruct(c: *Codegen, value: anytype) !void {
    const endian = @import("options").target_endian;
    try c.writer().writeStruct(value, endian);
}

pub fn writeAll(c: *Codegen, bytes: []const u8) !void {
    try c.writer().writeAll(bytes);
}
