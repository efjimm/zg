const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

const CodePointIterator = @import("code_point.zig").Iterator;

case_map: [][2]u21,
prop_s1: []u16,
prop_s2: []u8,

const LetterCasing = @This();

fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!LetterCasing {
    const decompressor = std.compress.flate.inflate.decompressor;
    const endian = builtin.cpu.arch.endian();

    var fbs = std.io.fixedBufferStream(@embedFile("lettercasing"));
    var decomp = decompressor(.raw, fbs.reader());
    var reader = decomp.reader();

    const T = extern struct {
        cp: u32,
        lower: i32,
        upper: i32,
    };

    const case_map_size = reader.readInt(u32, endian) catch unreachable;
    const buf = try allocator.alloc(T, case_map_size);
    defer allocator.free(buf);
    const bytes_read = reader.readAll(std.mem.sliceAsBytes(buf)) catch unreachable;
    std.debug.assert(bytes_read == std.mem.sliceAsBytes(buf).len);

    const max_cp = buf[buf.len - 1].cp;

    // Case properties
    var cp_fbs = std.io.fixedBufferStream(@embedFile("case_prop"));
    var cp_decomp = decompressor(.raw, cp_fbs.reader());
    var cp_reader = cp_decomp.reader();

    const CpHeader = extern struct { s1_len: u16, s2_len: u16 };
    const header = cp_reader.readStruct(CpHeader) catch unreachable;
    const total_size = @as(usize, header.s1_len) * 2 + header.s2_len;

    const bytes = try allocator.alignedAlloc(u8, .of([2]u21), @sizeOf([2]u21) * (max_cp + 1) + total_size);
    errdefer allocator.free(bytes);

    const case_map: [][2]u21 = @alignCast(std.mem.bytesAsSlice([2]u21, bytes)[0 .. max_cp + 1]);

    for (case_map, 0..) |*c, i| {
        const cp: u21 = @intCast(i);
        c.* = .{ cp, cp };
    }

    for (buf) |c| {
        const cp: u21 = @intCast(c.cp);
        case_map[c.cp] = .{ @intCast(cp + c.lower), @intCast(cp + c.upper) };
    }

    const cp_bytes = bytes[@sizeOf([2]u21) * (max_cp + 1) ..];
    const cp_bytes_read = cp_reader.readAll(cp_bytes) catch unreachable;
    std.debug.assert(cp_bytes_read == total_size);

    return .{
        .case_map = case_map,
        .prop_s1 = @alignCast(std.mem.bytesAsSlice(u16, cp_bytes[0 .. header.s1_len * 2])),
        .prop_s2 = cp_bytes[header.s1_len * 2 ..][0..header.s2_len],
    };
}

pub fn deinit(self: *const LetterCasing, allocator: std.mem.Allocator) void {
    const ptr: [*]align(@alignOf([2]u21)) const u8 = @ptrCast(self.case_map.ptr);
    const total_size =
        std.mem.sliceAsBytes(self.case_map).len +
        self.prop_s1.len * 2 +
        self.prop_s2.len;

    allocator.free(ptr[0..total_size]);
}

// Returns true if `cp` is either upper, lower, or title case.
pub fn isCased(self: LetterCasing, cp: u21) bool {
    return self.prop_s2[self.prop_s1[cp >> 8] + (cp & 0xff)] & 4 == 4;
}

// Returns true if `cp` is uppercase.
pub fn isUpper(self: LetterCasing, cp: u21) bool {
    return self.prop_s2[self.prop_s1[cp >> 8] + (cp & 0xff)] & 2 == 2;
}

/// Returns true if `str` is all uppercase.
pub fn isUpperStr(self: LetterCasing, str: []const u8) bool {
    var iter = CodePointIterator{ .bytes = str };

    while (iter.next()) |cp| {
        if (self.isCased(cp.code) and !self.isUpper(cp.code))
            return false;
    }

    return true;
}

test "isUpperStr" {
    const cd = try init(testing.allocator);
    defer cd.deinit(testing.allocator);

    try testing.expect(cd.isUpperStr("HELLO, WORLD 2112!"));
    try testing.expect(!cd.isUpperStr("hello, world 2112!"));
    try testing.expect(!cd.isUpperStr("Hello, World 2112!"));
}

/// Returns uppercase mapping for `cp`.
pub fn toUpper(self: LetterCasing, cp: u21) u21 {
    return if (cp >= self.case_map.len) cp else self.case_map[cp][0];
}

/// Returns a new string with all letters in uppercase.
/// Caller must free returned bytes with `allocator`.
pub fn toUpperStr(
    self: LetterCasing,
    allocator: std.mem.Allocator,
    str: []const u8,
) ![]u8 {
    var bytes = std.ArrayList(u8).init(allocator);
    defer bytes.deinit();

    var iter = CodePointIterator{ .bytes = str };
    var buf: [4]u8 = undefined;

    while (iter.next()) |cp| {
        const len = try std.unicode.utf8Encode(self.toUpper(cp.code), &buf);
        try bytes.appendSlice(buf[0..len]);
    }

    return try bytes.toOwnedSlice();
}

test "toUpperStr" {
    const cd = try init(testing.allocator);
    defer cd.deinit(testing.allocator);

    const uppered = try cd.toUpperStr(testing.allocator, "Hello, World 2112!");
    defer testing.allocator.free(uppered);
    try testing.expectEqualStrings("HELLO, WORLD 2112!", uppered);
}

// Returns true if `cp` is lowercase.
pub fn isLower(self: LetterCasing, cp: u21) bool {
    return self.prop_s2[self.prop_s1[cp >> 8] + (cp & 0xff)] & 1 == 1;
}

/// Returns true if `str` is all lowercase.
pub fn isLowerStr(self: LetterCasing, str: []const u8) bool {
    var iter = CodePointIterator{ .bytes = str };

    while (iter.next()) |cp| {
        if (self.isCased(cp.code) and !self.isLower(cp.code))
            return false;
    }

    return true;
}

test "isLowerStr" {
    const cd = try init(testing.allocator);
    defer cd.deinit(testing.allocator);

    try testing.expect(cd.isLowerStr("hello, world 2112!"));
    try testing.expect(!cd.isLowerStr("HELLO, WORLD 2112!"));
    try testing.expect(!cd.isLowerStr("Hello, World 2112!"));
}

/// Returns lowercase mapping for `cp`.
pub fn toLower(self: LetterCasing, cp: u21) u21 {
    return if (cp >= self.case_map.len) cp else self.case_map[cp][1];
}

// TODO: Delete this shit
/// Returns a new string with all letters in lowercase.
/// Caller must free returned bytes with `allocator`.
pub fn toLowerStr(
    self: LetterCasing,
    allocator: std.mem.Allocator,
    str: []const u8,
) ![]u8 {
    var bytes = std.ArrayList(u8).init(allocator);
    defer bytes.deinit();

    var iter = CodePointIterator{ .bytes = str };
    var buf: [4]u8 = undefined;

    while (iter.next()) |cp| {
        const len = try std.unicode.utf8Encode(self.toLower(cp.code), &buf);
        try bytes.appendSlice(buf[0..len]);
    }

    return try bytes.toOwnedSlice();
}

test "toLowerStr" {
    const cd = try init(testing.allocator);
    defer cd.deinit(testing.allocator);

    const lowered = try cd.toLowerStr(testing.allocator, "Hello, World 2112!");
    defer testing.allocator.free(lowered);
    try testing.expectEqualStrings("hello, world 2112!", lowered);
}

fn testAllocator(allocator: std.mem.Allocator) !void {
    var prop = try LetterCasing.init(allocator);
    prop.deinit(allocator);
}

test "Allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, testAllocator, .{});
}
