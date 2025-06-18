const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const builtin = @import("builtin");

core_s1: []u16,
core_s2: []u8,
props_s1: []u16,
props_s2: []u8,
num_s1: []u16,
num_s2: []u8,

const Properties = @This();

pub fn init(allocator: Allocator) Allocator.Error!Properties {
    const decompressor = std.compress.flate.inflate.decompressor;

    // Process DerivedCoreProperties.txt
    var fbs = std.io.fixedBufferStream(@embedFile("properties"));
    var decomp = decompressor(.raw, fbs.reader());
    var reader = decomp.reader();

    const Header = extern struct {
        s1_len: u16,
        s2_len: u16,

        fn totalSize(header: @This()) usize {
            return @as(usize, header.s1_len) * 2 + header.s2_len;
        }
    };

    const core_header = reader.readStruct(Header) catch unreachable;
    const props_header = reader.readStruct(Header) catch unreachable;
    const num_header = reader.readStruct(Header) catch unreachable;

    const total_size =
        std.mem.alignForward(usize, core_header.totalSize(), 2) +
        std.mem.alignForward(usize, props_header.totalSize(), 2) +
        num_header.totalSize();
    const bytes = try allocator.alignedAlloc(u8, .of(u16), total_size);
    errdefer allocator.free(bytes);

    const props_bytes_start = std.mem.alignForward(usize, core_header.totalSize(), 2);
    const num_bytes_start = std.mem.alignForward(usize, props_bytes_start + props_header.totalSize(), 2);

    const core_bytes = bytes[0..core_header.totalSize()];
    const props_bytes = bytes[props_bytes_start..][0..props_header.totalSize()];
    const num_bytes = bytes[num_bytes_start..][0..num_header.totalSize()];

    var bytes_read = reader.readAll(core_bytes) catch unreachable;
    std.debug.assert(bytes_read == core_bytes.len);

    bytes_read = reader.readAll(props_bytes) catch unreachable;
    std.debug.assert(bytes_read == props_bytes.len);

    bytes_read = reader.readAll(num_bytes) catch unreachable;
    std.debug.assert(bytes_read == num_bytes.len);

    return .{
        .core_s1 = @ptrCast(core_bytes[0 .. core_header.s1_len * 2]),
        .core_s2 = core_bytes[core_header.s1_len * 2 ..],

        .props_s1 = @ptrCast(@alignCast(props_bytes[0 .. props_header.s1_len * 2])),
        .props_s2 = props_bytes[props_header.s1_len * 2 ..],

        .num_s1 = @ptrCast(@alignCast(num_bytes[0 .. num_header.s1_len * 2])),
        .num_s2 = num_bytes[num_header.s1_len * 2 ..],
    };
}

pub fn deinit(self: *const Properties, allocator: Allocator) void {
    const total_size =
        std.mem.alignForward(usize, self.core_s1.len * 2 + self.core_s2.len, 2) +
        std.mem.alignForward(usize, self.props_s1.len * 2 + self.props_s2.len, 2) +
        self.num_s1.len * 2 + self.num_s2.len;
    const ptr: [*]const u8 = @ptrCast(self.core_s1.ptr);
    allocator.free(ptr[0..total_size]);
}

/// True if `cp` is a mathematical symbol.
pub fn isMath(self: *const Properties, cp: u21) bool {
    return self.core_s2[self.core_s1[cp >> 8] + (cp & 0xff)] & 1 == 1;
}

/// True if `cp` is an alphabetic character.
pub fn isAlphabetic(self: *const Properties, cp: u21) bool {
    return self.core_s2[self.core_s1[cp >> 8] + (cp & 0xff)] & 2 == 2;
}

/// True if `cp` is a valid identifier start character.
pub fn isIdStart(self: *const Properties, cp: u21) bool {
    return self.core_s2[self.core_s1[cp >> 8] + (cp & 0xff)] & 4 == 4;
}

/// True if `cp` is a valid identifier continuation character.
pub fn isIdContinue(self: *const Properties, cp: u21) bool {
    return self.core_s2[self.core_s1[cp >> 8] + (cp & 0xff)] & 8 == 8;
}

/// True if `cp` is a valid extended identifier start character.
pub fn isXidStart(self: *const Properties, cp: u21) bool {
    return self.core_s2[self.core_s1[cp >> 8] + (cp & 0xff)] & 16 == 16;
}

/// True if `cp` is a valid extended identifier continuation character.
pub fn isXidContinue(self: *const Properties, cp: u21) bool {
    return self.core_s2[self.core_s1[cp >> 8] + (cp & 0xff)] & 32 == 32;
}

/// True if `cp` is a whitespace character.
pub fn isWhitespace(self: *const Properties, cp: u21) bool {
    return self.props_s2[self.props_s1[cp >> 8] + (cp & 0xff)] & 1 == 1;
}

/// True if `cp` is a hexadecimal digit.
pub fn isHexDigit(self: *const Properties, cp: u21) bool {
    return self.props_s2[self.props_s1[cp >> 8] + (cp & 0xff)] & 2 == 2;
}

/// True if `cp` is a diacritic mark.
pub fn isDiacritic(self: *const Properties, cp: u21) bool {
    return self.props_s2[self.props_s1[cp >> 8] + (cp & 0xff)] & 4 == 4;
}

/// True if `cp` is numeric.
pub fn isNumeric(self: *const Properties, cp: u21) bool {
    return self.num_s2[self.num_s1[cp >> 8] + (cp & 0xff)] & 1 == 1;
}

/// True if `cp` is a digit.
pub fn isDigit(self: *const Properties, cp: u21) bool {
    return self.num_s2[self.num_s1[cp >> 8] + (cp & 0xff)] & 2 == 2;
}

/// True if `cp` is decimal.
pub fn isDecimal(self: *const Properties, cp: u21) bool {
    return self.num_s2[self.num_s1[cp >> 8] + (cp & 0xff)] & 4 == 4;
}

test "Props" {
    const self = try init(testing.allocator);
    defer self.deinit(testing.allocator);

    try testing.expect(self.isHexDigit('F'));
    try testing.expect(self.isHexDigit('a'));
    try testing.expect(self.isHexDigit('8'));
    try testing.expect(!self.isHexDigit('z'));

    try testing.expect(self.isDiacritic('\u{301}'));
    try testing.expect(self.isAlphabetic('A'));
    try testing.expect(!self.isAlphabetic('3'));
    try testing.expect(self.isMath('+'));

    try testing.expect(self.isNumeric('\u{277f}'));
    try testing.expect(self.isDigit('\u{2070}'));
    try testing.expect(self.isDecimal('3'));

    try testing.expect(!self.isNumeric('1'));
    try testing.expect(!self.isDigit('2'));
    try testing.expect(!self.isDecimal('g'));
}

fn testAllocator(allocator: Allocator) !void {
    var prop = try Properties.init(allocator);
    prop.deinit(allocator);
}

test "Allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, testAllocator, .{});
}
