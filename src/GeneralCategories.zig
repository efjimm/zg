const std = @import("std");
const builtin = @import("builtin");

s1: []const u16,
s2: []const u5,
s3: []const u5,

/// General Category
pub const Gc = enum {
    Cc, // Other, Control
    Cf, // Other, Format
    Cn, // Other, Unassigned
    Co, // Other, Private Use
    Cs, // Other, Surrogate
    Ll, // Letter, Lowercase
    Lm, // Letter, Modifier
    Lo, // Letter, Other
    Lu, // Letter, Uppercase
    Lt, // Letter, Titlecase
    Mc, // Mark, Spacing Combining
    Me, // Mark, Enclosing
    Mn, // Mark, Non-Spacing
    Nd, // Number, Decimal Digit
    Nl, // Number, Letter
    No, // Number, Other
    Pc, // Punctuation, Connector
    Pd, // Punctuation, Dash
    Pe, // Punctuation, Close
    Pf, // Punctuation, Final quote (may behave like Ps or Pe depending on usage)
    Pi, // Punctuation, Initial quote (may behave like Ps or Pe depending on usage)
    Po, // Punctuation, Other
    Ps, // Punctuation, Open
    Sc, // Symbol, Currency
    Sk, // Symbol, Modifier
    Sm, // Symbol, Math
    So, // Symbol, Other
    Zl, // Separator, Line
    Zp, // Separator, Paragraph
    Zs, // Separator, Space
};

const GeneralCategories = @This();

pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!GeneralCategories {
    const in_bytes = @embedFile("gencat");
    var in_fbs = std.io.fixedBufferStream(in_bytes);
    var in_decomp = std.compress.flate.inflate.decompressor(.raw, in_fbs.reader());
    var reader = in_decomp.reader();

    const Header = extern struct {
        s1_len: u32,
        s2_len: u32,
        s3_len: u32,
    };

    const header = reader.readStruct(Header) catch unreachable;
    const total_size = header.s1_len * 2 + header.s2_len + header.s3_len;
    const bytes = try allocator.alignedAlloc(u8, .of(u16), total_size);
    const bytes_read = reader.readAll(bytes) catch unreachable;
    std.debug.assert(bytes_read == total_size);

    const s1: []const u16 = @ptrCast(bytes[0 .. header.s1_len * 2]);
    const s2: []const u5 = @ptrCast(bytes[header.s1_len * 2 ..][0..header.s2_len]);
    const s3: []const u5 = @ptrCast(bytes[header.s1_len * 2 + header.s2_len ..][0..header.s3_len]);

    return .{
        .s1 = s1,
        .s2 = s2,
        .s3 = s3,
    };
}

pub fn deinit(gencat: *const GeneralCategories, allocator: std.mem.Allocator) void {
    const total_size = gencat.s1.len * 2 + gencat.s2.len + gencat.s3.len;
    const ptr: [*]const u8 = @ptrCast(gencat.s1.ptr);
    const slice = ptr[0..total_size];
    allocator.free(slice);
}

/// Lookup the General Category for `cp`.
pub fn gc(gencat: *const GeneralCategories, cp: u21) Gc {
    return @enumFromInt(gencat.s3[gencat.s2[gencat.s1[cp >> 8] + (cp & 0xff)]]);
}

/// True if `cp` has an C general category.
pub fn isControl(gencat: *const GeneralCategories, cp: u21) bool {
    return switch (gencat.gc(cp)) {
        .Cc,
        .Cf,
        .Cn,
        .Co,
        .Cs,
        => true,
        else => false,
    };
}

/// True if `cp` has an L general category.
pub fn isLetter(gencat: *const GeneralCategories, cp: u21) bool {
    return switch (gencat.gc(cp)) {
        .Ll,
        .Lm,
        .Lo,
        .Lu,
        .Lt,
        => true,
        else => false,
    };
}

/// True if `cp` has an M general category.
pub fn isMark(gencat: *const GeneralCategories, cp: u21) bool {
    return switch (gencat.gc(cp)) {
        .Mc,
        .Me,
        .Mn,
        => true,
        else => false,
    };
}

/// True if `cp` has an N general category.
pub fn isNumber(gencat: *const GeneralCategories, cp: u21) bool {
    return switch (gencat.gc(cp)) {
        .Nd,
        .Nl,
        .No,
        => true,
        else => false,
    };
}

/// True if `cp` has an P general category.
pub fn isPunctuation(gencat: *const GeneralCategories, cp: u21) bool {
    return switch (gencat.gc(cp)) {
        .Pc,
        .Pd,
        .Pe,
        .Pf,
        .Pi,
        .Po,
        .Ps,
        => true,
        else => false,
    };
}

/// True if `cp` has an S general category.
pub fn isSymbol(gencat: *const GeneralCategories, cp: u21) bool {
    return switch (gencat.gc(cp)) {
        .Sc,
        .Sk,
        .Sm,
        .So,
        => true,
        else => false,
    };
}

/// True if `cp` has an Z general category.
pub fn isSeparator(gencat: *const GeneralCategories, cp: u21) bool {
    return switch (gencat.gc(cp)) {
        .Zl,
        .Zp,
        .Zs,
        => true,
        else => false,
    };
}

fn testAllocator(allocator: std.mem.Allocator) !void {
    var gen_cat = try GeneralCategories.init(allocator);
    gen_cat.deinit(allocator);
}

test "Allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        testAllocator,
        .{},
    );
}
