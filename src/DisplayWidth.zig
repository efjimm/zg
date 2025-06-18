const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const builtin = @import("builtin");

const options = @import("options");

const ascii = @import("ascii.zig");
const CodePointIterator = @import("code_point.zig").Iterator;
const Graphemes = @import("Graphemes.zig");

graphemes: Graphemes,
s1: []const u16,
s2: []const i4,
owns_graphemes: bool,

const DisplayWidth = @This();

pub const uninitialized: DisplayWidth = blk: {
    var dw: DisplayWidth = undefined;
    dw.s1 = &.{};
    break :blk dw;
};

pub fn isInitialized(dw: *const DisplayWidth) bool {
    return dw.s1.len != 0;
}

pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!DisplayWidth {
    const graphemes: Graphemes = try .init(allocator);
    errdefer graphemes.deinit(allocator);

    var ret = try initWithGraphemes(allocator, graphemes);
    ret.owns_graphemes = true;
    return ret;
}

pub fn initWithGraphemes(
    allocator: std.mem.Allocator,
    graphemes: Graphemes,
) std.mem.Allocator.Error!DisplayWidth {
    var in_fbs = std.io.fixedBufferStream(@embedFile("dwp"));
    var in_decomp = std.compress.flate.inflate.decompressor(.raw, in_fbs.reader());
    const reader = in_decomp.reader();

    const Header = extern struct {
        s1_len: u32,
        s2_len: u32,
    };

    const header = reader.readStruct(Header) catch unreachable;
    const data = try allocator.alignedAlloc(u8, .of(u16), header.s1_len * 2 + header.s2_len);
    _ = reader.readAll(data) catch unreachable;
    const s1: []const u16 = @ptrCast(data[0 .. header.s1_len * 2]);
    const s2: []const i4 = @ptrCast(data[header.s1_len * 2 ..]);
    std.debug.assert(s2.len == header.s2_len);

    return .{
        .graphemes = graphemes,
        .owns_graphemes = false,
        .s1 = s1,
        .s2 = s2,
    };
}

pub fn deinit(dw: *const DisplayWidth, allocator: std.mem.Allocator) void {
    assert(dw.isInitialized());
    const ptr: [*]const u8 = @ptrCast(dw.s1.ptr);
    const bytes = ptr[0 .. dw.s1.len * 2 + dw.s2.len];
    allocator.free(bytes);
    if (dw.owns_graphemes) dw.graphemes.deinit(allocator);
}

/// codePointWidth returns the number of cells `cp` requires when rendered
/// in a fixed-pitch font (i.e. a terminal screen). This can range from -1 to
/// 3, where BACKSPACE and DELETE return -1 and 3-em-dash returns 3. C0/C1
/// control codes return 0. If `cjk` is true, ambiguous code points return 2,
/// otherwise they return 1.
pub fn codePointWidth(dw: *const DisplayWidth, cp: u21) i4 {
    assert(dw.isInitialized());
    return dw.s2[dw.s1[cp >> 8] + (cp & 0xff)];
}

test "codePointWidth" {
    const dw = try DisplayWidth.init(std.testing.allocator);
    defer dw.deinit(std.testing.allocator);
    try testing.expectEqual(0, dw.codePointWidth(0x0000)); // null
    try testing.expectEqual(-1, dw.codePointWidth(0x8)); // \b
    try testing.expectEqual(-1, dw.codePointWidth(0x7f)); // DEL
    try testing.expectEqual(0, dw.codePointWidth(0x0005)); // Cf
    try testing.expectEqual(0, dw.codePointWidth(0x0007)); // \a BEL
    try testing.expectEqual(0, dw.codePointWidth(0x000A)); // \n LF
    try testing.expectEqual(0, dw.codePointWidth(0x000B)); // \v VT
    try testing.expectEqual(0, dw.codePointWidth(0x000C)); // \f FF
    try testing.expectEqual(0, dw.codePointWidth(0x000D)); // \r CR
    try testing.expectEqual(0, dw.codePointWidth(0x000E)); // SQ
    try testing.expectEqual(0, dw.codePointWidth(0x000F)); // SI

    try testing.expectEqual(0, dw.codePointWidth(0x070F)); // Cf
    try testing.expectEqual(1, dw.codePointWidth(0x0603)); // Cf Arabic

    try testing.expectEqual(1, dw.codePointWidth(0x00AD)); // soft-hyphen
    try testing.expectEqual(2, dw.codePointWidth(0x2E3A)); // two-em dash
    try testing.expectEqual(3, dw.codePointWidth(0x2E3B)); // three-em dash

    try testing.expectEqual(1, dw.codePointWidth(0x00BD)); // ambiguous halfwidth

    try testing.expectEqual(1, dw.codePointWidth('é'));
    try testing.expectEqual(2, dw.codePointWidth('😊'));
    try testing.expectEqual(2, dw.codePointWidth('统'));
}

/// strWidth returns the total display width of `str` as the number of cells
/// required in a fixed-pitch font (i.e. a terminal screen).
pub fn strWidth(dw: *const DisplayWidth, str: []const u8) usize {
    assert(dw.isInitialized());
    var total: isize = 0;

    // ASCII fast path
    if (ascii.isAsciiOnly(str)) {
        for (str) |b| total += dw.codePointWidth(b);
        return @intCast(@max(0, total));
    }

    var giter = dw.graphemes.iterator(str);

    while (giter.next()) |gc| {
        var cp_iter = CodePointIterator{ .bytes = gc.bytes(str) };
        var gc_total: isize = 0;

        while (cp_iter.next()) |cp| {
            var w = dw.codePointWidth(cp.code);

            if (w != 0) {
                // Handle text emoji sequence.
                if (cp_iter.next()) |ncp| {
                    // emoji text sequence.
                    if (ncp.code == 0xFE0E) w = 1;
                    if (ncp.code == 0xFE0F) w = 2;
                }

                // Only adding width of first non-zero-width code point.
                if (gc_total == 0) {
                    gc_total = w;
                    break;
                }
            }
        }

        total += gc_total;
    }

    return @intCast(@max(0, total));
}

test "strWidth" {
    const dw = try DisplayWidth.init(testing.allocator);
    defer dw.deinit(testing.allocator);
    const c0 = options.c0_width orelse 0;

    try testing.expectEqual(5, dw.strWidth("Hello\r\n"));
    try testing.expectEqual(1, dw.strWidth("\u{0065}\u{0301}"));
    try testing.expectEqual(2, dw.strWidth("\u{1F476}\u{1F3FF}\u{0308}\u{200D}\u{1F476}\u{1F3FF}"));
    try testing.expectEqual(8, dw.strWidth("Hello 😊"));
    try testing.expectEqual(8, dw.strWidth("Héllo 😊"));
    try testing.expectEqual(8, dw.strWidth("Héllo :)"));
    try testing.expectEqual(8, dw.strWidth("Héllo 🇪🇸"));
    try testing.expectEqual(2, dw.strWidth("\u{26A1}")); // Lone emoji
    try testing.expectEqual(1, dw.strWidth("\u{26A1}\u{FE0E}")); // Text sequence
    try testing.expectEqual(2, dw.strWidth("\u{26A1}\u{FE0F}")); // Presentation sequence
    try testing.expectEqual(1, dw.strWidth("\u{2764}")); // Default text presentation
    try testing.expectEqual(1, dw.strWidth("\u{2764}\u{FE0E}")); // Default text presentation with VS15 selector
    try testing.expectEqual(2, dw.strWidth("\u{2764}\u{FE0F}")); // Default text presentation with VS16 selector
    const expect_bs: usize = if (c0 == 0) 0 else 1 + c0;
    try testing.expectEqual(expect_bs, dw.strWidth("A\x08")); // Backspace
    try testing.expectEqual(expect_bs, dw.strWidth("\x7FA")); // DEL
    const expect_long_del: usize = if (c0 == 0) 0 else 1 + (c0 * 3);
    try testing.expectEqual(expect_long_del, dw.strWidth("\x7FA\x08\x08")); // never less than 0

    // wcwidth Python lib tests. See: https://github.com/jquast/wcwidth/blob/master/tests/test_core.py
    const empty = "";
    try testing.expectEqual(0, dw.strWidth(empty));
    const with_null = "hello\x00world";
    try testing.expectEqual(10 + c0, dw.strWidth(with_null));
    const hello_jp = "コンニチハ, セカイ!";
    try testing.expectEqual(19, dw.strWidth(hello_jp));
    const control = "\x1b[0m";
    try testing.expectEqual(3 + c0, dw.strWidth(control));
    const balinese = "\u{1B13}\u{1B28}\u{1B2E}\u{1B44}";
    try testing.expectEqual(3, dw.strWidth(balinese));

    // These commented out tests require a new specification for complex scripts.
    // See: https://www.unicode.org/L2/L2023/23107-terminal-suppt.pdf
    // const jamo = "\u{1100}\u{1160}";
    // try testing.expectEqual(@as(usize, 3), strWidth(jamo));
    // const devengari = "\u{0915}\u{094D}\u{0937}\u{093F}";
    // try testing.expectEqual(@as(usize, 3), strWidth(devengari));
    // const tamal = "\u{0b95}\u{0bcd}\u{0bb7}\u{0bcc}";
    // try testing.expectEqual(@as(usize, 5), strWidth(tamal));
    // const kannada_1 = "\u{0cb0}\u{0ccd}\u{0c9d}\u{0cc8}";
    // try testing.expectEqual(@as(usize, 3), strWidth(kannada_1));
    // The following passes but as a mere coincidence.
    const kannada_2 = "\u{0cb0}\u{0cbc}\u{0ccd}\u{0c9a}";
    try testing.expectEqual(2, dw.strWidth(kannada_2));

    // From Rust https://github.com/jameslanska/unicode-display-width
    try testing.expectEqual(15, dw.strWidth("🔥🗡🍩👩🏻‍🚀⏰💃🏼🔦👍🏻"));
    try testing.expectEqual(2, dw.strWidth("🦀"));
    try testing.expectEqual(2, dw.strWidth("👨‍👩‍👧‍👧"));
    try testing.expectEqual(2, dw.strWidth("👩‍🔬"));
    try testing.expectEqual(9, dw.strWidth("sane text"));
    try testing.expectEqual(9, dw.strWidth("Ẓ̌á̲l͔̝̞̄̑͌g̖̘̘̔̔͢͞͝o̪̔T̢̙̫̈̍͞e̬͈͕͌̏͑x̺̍ṭ̓̓ͅ"));
    try testing.expectEqual(17, dw.strWidth("슬라바 우크라이나"));
    try testing.expectEqual(1, dw.strWidth("\u{378}"));
}

/// centers `str` in a new string of width `total_width` (in display cells) using `pad` as padding.
/// If the length of `str` and `total_width` have different parity, the right side of `str` will
/// receive one additional pad. This makes sure the returned string fills the requested width.
/// Caller must free returned bytes with `allocator`.
pub fn center(
    dw: *const DisplayWidth,
    allocator: std.mem.Allocator,
    str: []const u8,
    total_width: usize,
    pad: []const u8,
) ![]u8 {
    assert(dw.isInitialized());
    const str_width = dw.strWidth(str);
    if (str_width > total_width) return error.StrTooLong;
    if (str_width == total_width) return try allocator.dupe(u8, str);

    const pad_width = dw.strWidth(pad);
    if (pad_width > total_width or str_width + pad_width > total_width) return error.PadTooLong;

    const margin_width = @divFloor((total_width - str_width), 2);
    if (pad_width > margin_width) return error.PadTooLong;
    const extra_pad: usize = if (total_width % 2 != str_width % 2) 1 else 0;
    const pads = @divFloor(margin_width, pad_width) * 2 + extra_pad;

    var result = try allocator.alloc(u8, pads * pad.len + str.len);
    var bytes_index: usize = 0;
    var pads_index: usize = 0;

    while (pads_index < pads / 2) : (pads_index += 1) {
        @memcpy(result[bytes_index..][0..pad.len], pad);
        bytes_index += pad.len;
    }

    @memcpy(result[bytes_index..][0..str.len], str);
    bytes_index += str.len;

    pads_index = 0;
    while (pads_index < pads / 2 + extra_pad) : (pads_index += 1) {
        @memcpy(result[bytes_index..][0..pad.len], pad);
        bytes_index += pad.len;
    }

    return result;
}

test "center" {
    const allocator = testing.allocator;
    const dw = try DisplayWidth.init(allocator);
    defer dw.deinit(allocator);

    // Input and width both have odd length
    var centered = try dw.center(allocator, "abc", 9, "*");
    try testing.expectEqualSlices(u8, "***abc***", centered);

    // Input and width both have even length
    testing.allocator.free(centered);
    centered = try dw.center(allocator, "w😊w", 10, "-");
    try testing.expectEqualSlices(u8, "---w😊w---", centered);

    // Input has even length, width has odd length
    testing.allocator.free(centered);
    centered = try dw.center(allocator, "1234", 9, "-");
    try testing.expectEqualSlices(u8, "--1234---", centered);

    // Input has odd length, width has even length
    testing.allocator.free(centered);
    centered = try dw.center(allocator, "123", 8, "-");
    try testing.expectEqualSlices(u8, "--123---", centered);

    // Input is the same length as the width
    testing.allocator.free(centered);
    centered = try dw.center(allocator, "123", 3, "-");
    try testing.expectEqualSlices(u8, "123", centered);

    // Input is empty
    testing.allocator.free(centered);
    centered = try dw.center(allocator, "", 3, "-");
    try testing.expectEqualSlices(u8, "---", centered);

    // Input is empty and width is zero
    testing.allocator.free(centered);
    centered = try dw.center(allocator, "", 0, "-");
    try testing.expectEqualSlices(u8, "", centered);

    // Input is longer than the width, which is an error
    testing.allocator.free(centered);
    try testing.expectError(error.StrTooLong, dw.center(allocator, "123", 2, "-"));
}

/// padLeft returns a new string of width `total_width` (in display cells) using `pad` as padding
/// on the left side. Caller must free returned bytes with `allocator`.
pub fn padLeft(
    dw: *const DisplayWidth,
    allocator: std.mem.Allocator,
    str: []const u8,
    total_width: usize,
    pad: []const u8,
) ![]u8 {
    assert(dw.isInitialized());
    const str_width = dw.strWidth(str);
    if (str_width > total_width) return error.StrTooLong;

    const pad_width = dw.strWidth(pad);
    if (pad_width > total_width or str_width + pad_width > total_width) return error.PadTooLong;

    const margin_width = total_width - str_width;
    if (pad_width > margin_width) return error.PadTooLong;

    const pads = @divFloor(margin_width, pad_width);

    var result = try allocator.alloc(u8, pads * pad.len + str.len);
    var bytes_index: usize = 0;
    var pads_index: usize = 0;

    while (pads_index < pads) : (pads_index += 1) {
        @memcpy(result[bytes_index..][0..pad.len], pad);
        bytes_index += pad.len;
    }

    @memcpy(result[bytes_index..][0..str.len], str);

    return result;
}

test "padLeft" {
    const allocator = testing.allocator;
    const dw = try DisplayWidth.init(allocator);
    defer dw.deinit(allocator);

    var right_aligned = try dw.padLeft(allocator, "abc", 9, "*");
    defer testing.allocator.free(right_aligned);
    try testing.expectEqualSlices(u8, "******abc", right_aligned);

    testing.allocator.free(right_aligned);
    right_aligned = try dw.padLeft(allocator, "w😊w", 10, "-");
    try testing.expectEqualSlices(u8, "------w😊w", right_aligned);
}

/// padRight returns a new string of width `total_width` (in display cells) using `pad` as padding
/// on the right side.  Caller must free returned bytes with `allocator`.
pub fn padRight(
    dw: *const DisplayWidth,
    allocator: std.mem.Allocator,
    str: []const u8,
    total_width: usize,
    pad: []const u8,
) ![]u8 {
    assert(dw.isInitialized());
    const str_width = dw.strWidth(str);
    if (str_width > total_width) return error.StrTooLong;

    const pad_width = dw.strWidth(pad);
    if (pad_width > total_width or str_width + pad_width > total_width) return error.PadTooLong;

    const margin_width = total_width - str_width;
    if (pad_width > margin_width) return error.PadTooLong;

    const pads = @divFloor(margin_width, pad_width);

    var result = try allocator.alloc(u8, pads * pad.len + str.len);
    var bytes_index: usize = 0;
    var pads_index: usize = 0;

    @memcpy(result[bytes_index..][0..str.len], str);
    bytes_index += str.len;

    while (pads_index < pads) : (pads_index += 1) {
        @memcpy(result[bytes_index..][0..pad.len], pad);
        bytes_index += pad.len;
    }

    return result;
}

test "padRight" {
    const allocator = testing.allocator;
    const dw = try DisplayWidth.init(allocator);
    defer dw.deinit(allocator);

    var left_aligned = try dw.padRight(allocator, "abc", 9, "*");
    defer testing.allocator.free(left_aligned);
    try testing.expectEqualSlices(u8, "abc******", left_aligned);

    testing.allocator.free(left_aligned);
    left_aligned = try dw.padRight(allocator, "w😊w", 10, "-");
    try testing.expectEqualSlices(u8, "w😊w------", left_aligned);
}

/// Wraps a string approximately at the given number of colums per line.
/// `threshold` defines how far the last column of the last word can be
/// from the edge. Caller must free returned bytes with `allocator`.
pub fn wrap(
    dw: *const DisplayWidth,
    allocator: std.mem.Allocator,
    str: []const u8,
    columns: usize,
    threshold: usize,
) ![]u8 {
    assert(dw.isInitialized());
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    var line_iter = std.mem.tokenizeAny(u8, str, "\r\n");
    var line_width: usize = 0;

    while (line_iter.next()) |line| {
        var word_iter = std.mem.tokenizeScalar(u8, line, ' ');

        while (word_iter.next()) |word| {
            try result.appendSlice(word);
            try result.append(' ');
            line_width += dw.strWidth(word) + 1;

            if (line_width > columns or columns - line_width <= threshold) {
                try result.append('\n');
                line_width = 0;
            }
        }
    }

    // Remove trailing space and newline.
    _ = result.pop();
    _ = result.pop();

    return try result.toOwnedSlice();
}

test "wrap" {
    const allocator = testing.allocator;
    const dw = try DisplayWidth.init(allocator);
    defer dw.deinit(allocator);

    const input = "The quick brown fox\r\njumped over the lazy dog!";
    const got = try dw.wrap(allocator, input, 10, 3);
    defer testing.allocator.free(got);
    const want = "The quick \nbrown fox \njumped \nover the \nlazy dog!";
    try testing.expectEqualStrings(want, got);
}

fn testAllocation(allocator: std.mem.Allocator) !void {
    {
        var dw = try DisplayWidth.init(allocator);
        dw.deinit(allocator);
    }
    {
        var graph = try Graphemes.init(allocator);
        defer graph.deinit(allocator);
        var dw = try DisplayWidth.initWithGraphemes(allocator, graph);
        dw.deinit(allocator);
    }
}

test "allocation test" {
    try testing.checkAllAllocationFailures(testing.allocator, testAllocation, .{});
}
