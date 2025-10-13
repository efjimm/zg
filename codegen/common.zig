const std = @import("std");
const panic = std.debug.panic;

var out_global: Output = undefined;

pub const Output = struct {
    file: std.fs.File,
    file_writer: std.fs.File.Writer,
    d: std.compress.flate.Compress,
    out_buf: [8192]u8,
    dbuf: [std.compress.flate.max_window_len]u8,
};

pub fn output() *std.Io.Writer {
    var args_iter = std.process.argsWithAllocator(std.heap.smp_allocator) catch @panic("OOM");
    _ = args_iter.skip();
    const output_path = args_iter.next() orelse @panic("No output file arg!");

    const file = std.fs.cwd().createFile(output_path, .{}) catch @panic("");

    out_global.file = file;
    out_global.file_writer = file.writer(&out_global.out_buf);
    out_global.d = std.compress.flate.Compress.init(
        &out_global.file_writer.interface,
        &out_global.dbuf,
        .gzip,
        .best,
    ) catch @panic("");

    return &out_global.d.writer;
}

pub fn finish() void {
    out_global.file_writer.interface.flush() catch @panic("");
}
