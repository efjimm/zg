const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");

const CodePoint = @import("code_point.zig").CodePoint;
const CodePointIterator = @import("code_point.zig").Iterator;

s1: []const u16,
s2: []const u16,
s3: []const u8,

const Graphemes = @This();

pub const uninitialized: Graphemes = blk: {
    var g: Graphemes = undefined;
    g.s1 = &.{};
    break :blk g;
};

pub fn isInitialized(g: *const Graphemes) bool {
    return g.s1.len != 0;
}

pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Graphemes {
    const decompressor = std.compress.flate.inflate.decompressor;
    const in_bytes = @embedFile("gbp");
    var in_fbs = std.io.fixedBufferStream(in_bytes);
    var in_decomp = decompressor(.raw, in_fbs.reader());
    var reader = in_decomp.reader();

    const Header = extern struct {
        s1_len: u32,
        s2_len: u32,
        s3_len: u32,
    };

    const header = reader.readStruct(Header) catch unreachable;
    const total_size = header.s1_len * 2 + header.s2_len * 2 + header.s3_len;
    const bytes = try allocator.alignedAlloc(u8, .of(u16), total_size);
    const bytes_read = reader.readAll(bytes) catch unreachable;
    std.debug.assert(bytes_read == total_size);

    const s1_size = header.s1_len * 2;
    const s2_size = header.s2_len * 2;

    return .{
        .s1 = @ptrCast(@alignCast(bytes[0..s1_size])),
        .s2 = @ptrCast(@alignCast(bytes[s1_size..][0..s2_size])),
        .s3 = @ptrCast(@alignCast(bytes[s1_size + s2_size ..][0..header.s3_len])),
    };
}

pub fn deinit(g: *const Graphemes, allocator: std.mem.Allocator) void {
    assert(g.isInitialized());
    const total_size = g.s1.len * 2 + g.s2.len * 2 + g.s3.len;
    const ptr: [*]const u8 = @ptrCast(g.s1.ptr);
    allocator.free(ptr[0..total_size]);
}

/// Lookup the grapheme break property for a code point.
pub fn gbp(graphemes: *const Graphemes, cp: u21) Gbp {
    assert(graphemes.isInitialized());
    return @enumFromInt(graphemes.s3[graphemes.s2[graphemes.s1[cp >> 8] + (cp & 0xff)]] >> 4);
}

/// Lookup the indic syllable type for a code point.
pub fn indic(graphemes: *const Graphemes, cp: u21) Indic {
    assert(graphemes.isInitialized());
    return @enumFromInt((graphemes.s3[graphemes.s2[graphemes.s1[cp >> 8] + (cp & 0xff)]] >> 1) & 0x7);
}

/// Lookup the emoji property for a code point.
pub fn isEmoji(graphemes: *const Graphemes, cp: u21) bool {
    assert(graphemes.isInitialized());
    return graphemes.s3[graphemes.s2[graphemes.s1[cp >> 8] + (cp & 0xff)]] & 1 == 1;
}

pub fn iterator(graphemes: *const Graphemes, string: []const u8) Iterator {
    assert(graphemes.isInitialized());
    return Iterator.init(string, graphemes);
}

/// Indic syllable type.
pub const Indic = enum {
    none,

    consonant,
    extend,
    linker,
};

/// Grapheme break property.
pub const Gbp = enum {
    none,
    control,
    cr,
    extend,
    l,
    lf,
    lv,
    lvt,
    prepend,
    regional_indicator,
    spacing_mark,
    t,
    v,
    zwj,
};

/// `Grapheme` represents a Unicode grapheme cluster by its length and offset in the source bytes.
pub const Grapheme = struct {
    len: usize,
    offset: usize,

    /// `bytes` returns the slice of bytes that correspond to
    /// this grapheme cluster in `src`.
    pub fn bytes(self: Grapheme, src: []const u8) []const u8 {
        return src[self.offset..][0..self.len];
    }
};

/// `Iterator` iterates a sting of UTF-8 encoded bytes one grapheme cluster at-a-time.
/// Right now, I have no idea if it is legal to call `next` and `prev` on the same iterator
/// instance without resetting the internal state.
pub const Iterator = struct {
    buf: [2]?CodePoint = @splat(null),
    cp_iter: CodePointIterator,
    data: *const Graphemes,
    pending: Pending = .{ .none = {} },

    pub const Pending = union(enum) {
        none,
        /// Count of pending RI codepoints, it is an even number
        ri_count: usize,
        /// End of (Extend* ZWJ) sequence pending from failed GB11: !Emoji Extend* ZWJ x Emoji
        extend_end: usize,
    };

    /// Assumes `src` is valid UTF-8.
    pub fn init(str: []const u8, data: *const Graphemes) Iterator {
        assert(data.isInitialized());
        var iter: Iterator = .{ .cp_iter = .init(str), .data = data };
        iter.advanceForward();
        return iter;
    }

    /// Assumes `src` is valid UTF-8.
    pub fn initEnd(str: []const u8, data: *const Graphemes) Iterator {
        assert(data.isInitialized());
        var self: Iterator = .{ .cp_iter = .initEnd(str), .data = data };
        self.advanceBackward();
        self.advanceBackward();
        return self;
    }

    fn advanceForward(self: *Iterator) void {
        self.buf[0] = self.buf[1];
        self.buf[1] = self.cp_iter.next();
    }

    fn advanceBackward(self: *Iterator) void {
        self.buf[1] = self.buf[0];
        self.buf[0] = self.cp_iter.prev();
    }

    pub fn next(self: *Iterator) ?Grapheme {
        assert(self.data.isInitialized());
        self.advanceForward();

        var cp0 = self.buf[0] orelse return null;
        var code1 = if (self.buf[1]) |cp| cp.code else return .{
            .len = cp0.len,
            .offset = cp0.offset,
        };

        // If ASCII
        if (cp0.code != '\r' and cp0.code < 0x80 and code1 < 0x80)
            return .{ .len = cp0.len, .offset = cp0.offset };

        const gc_start = cp0.offset;
        var gc_len: usize = cp0.len;
        var state: State = .reset;

        while (!self.data.isBreak(cp0.code, code1, &state)) : (gc_len += cp0.len) {
            self.advanceForward();
            cp0 = self.buf[0] orelse break;
            code1 = if (self.buf[1]) |cp| cp.code else 0;
        }

        return .{ .len = gc_len, .offset = gc_start };
    }

    pub fn prev(self: *Iterator) ?Grapheme {
        const first_cp = self.buf[1] orelse return null;

        const grapheme_end: usize = end: switch (self.pending) {
            // BUF: [?Any, Any]
            .none => first_cp.offset + first_cp.len,
            .ri_count => |ri_count| {
                assert(ri_count > 0);
                assert(ri_count % 2 == 0);

                if (ri_count > 2) {
                    self.pending.ri_count -= 2;

                    // Use the fact that all RI have length 4 in utf8 encoding
                    // since they are in range 0x1f1e6...0x1f1ff
                    // https://en.wikipedia.org/wiki/UTF-8#Encoding
                    return .{
                        .len = 8,
                        .offset = first_cp.offset + self.pending.ri_count * 4,
                    };
                } else {
                    self.pending = .none;
                    break :end first_cp.offset + first_cp.len + 4;
                }
            },
            // BUF: [?Any, Extend] Extend* ZWJ
            .extend_end => |extend_end| {
                self.pending = .none;
                break :end extend_end;
            },
        };

        while (self.buf[0] != null) {
            var state: State = .reset;
            state.setXpic();
            state.unsetRegional();
            state.setIndic();

            if (self.data.isBreak(self.buf[0].?.code, self.buf[1].?.code, &state))
                break;

            self.advanceBackward();

            if (!state.hasIndic()) {

                // BUF: [?Any, Extend | Linker] Consonant
                var indic_offset: usize = self.buf[1].?.offset + self.buf[1].?.len;

                while (self.buf[0]) |cp0| {
                    switch (self.data.indic(cp0.code)) {
                        .extend, .linker => {
                            self.advanceBackward();
                            continue;
                        },
                        .consonant => {
                            // BUF: [Consonant, Extend | Linker] (Extend | Linker)* Consonant
                            indic_offset = cp0.offset;
                            self.advanceBackward();

                            const new_cp0 = self.buf[0] orelse break;
                            state.setIndic();

                            const has_break = self.data.isBreak(new_cp0.code, self.buf[1].?.code, &state);
                            if (has_break or state.hasIndic())
                                break;
                        },
                        .none => {
                            // BUF: [Any, Extend | Linker] (Extend | Linker)* Consonant
                            self.pending = .{ .extend_end = indic_offset };
                            return .{
                                .len = grapheme_end - indic_offset,
                                .offset = indic_offset,
                            };
                        },
                    }
                } else {
                    self.pending = .{ .extend_end = indic_offset };
                    return .{
                        .len = grapheme_end - indic_offset,
                        .offset = indic_offset,
                    };
                }
            }

            if (!state.hasXpic()) {
                // BUF: [?Any, ZWJ] Emoji
                var emoji_offset = self.buf[1].?.offset + self.buf[1].?.len;

                // Look for previous Emoji
                while (self.buf[0]) |codepoint| : (self.advanceBackward()) {
                    if (self.data.gbp(codepoint.code) == .extend)
                        continue;

                    if (!self.data.isEmoji(codepoint.code)) {
                        // BUF: [Any, Extend] (Extend* ZWJ Emoji)*
                        self.pending = .{ .extend_end = emoji_offset };
                        return .{
                            .len = grapheme_end - emoji_offset,
                            .offset = emoji_offset,
                        };
                    }

                    // BUF: [Emoji, Extend] (Extend* ZWJ Emoji)*
                    emoji_offset = codepoint.offset;
                    self.advanceBackward();

                    // ZWJ = 0x200d
                    if (self.buf[0] == null or self.buf[0].?.code != 0x200d)
                        // BUF: [?Any, Emoji] (Extend* ZWJ Emoji)*
                        break;

                    // BUF: [ZWJ, Emoji] (Extend* ZWJ Emoji)*
                    // Back at the beginning of the loop, "recursively" look for emoji
                } else {
                    self.pending = .{ .extend_end = emoji_offset };
                    return .{
                        .len = grapheme_end - emoji_offset,
                        .offset = emoji_offset,
                    };
                }
            }

            if (state.hasRegional()) {
                var ri_count: usize = 0;
                while (self.buf[0] != null and
                    self.data.gbp(self.buf[0].?.code) == .regional_indicator)
                {
                    ri_count += 1;
                    self.advanceBackward();
                }

                // Use the fact that all RI have length 4 in utf8 encoding
                // since they are in range 0x1f1e6...0x1f1ff
                // https://en.wikipedia.org/wiki/UTF-8#Encoding
                if (ri_count == 0) {
                    // There are no pending RI codepoints
                } else if (ri_count % 2 == 0) {
                    self.pending = .{ .ri_count = ri_count };
                    return .{ .len = 8, .offset = grapheme_end - 8 };
                } else {
                    // Add one to count for the unused RI
                    self.pending = .{ .ri_count = ri_count + 1 };
                    return .{ .len = 4, .offset = grapheme_end - 4 };
                }
            }
        }

        const grapheme_start = if (self.buf[1]) |codepoint| codepoint.offset else 0;
        self.advanceBackward();
        return .{
            .len = grapheme_end - grapheme_start,
            .offset = grapheme_start,
        };
    }

    pub fn peekNext(iter: *const Iterator) ?Grapheme {
        var temp = iter.*;
        return temp.next();
    }

    pub fn peekPrev(iter: *const Iterator) ?Grapheme {
        var temp = iter.*;
        return temp.prev();
    }
};

pub fn reverseIterator(data: *const Graphemes, str: []const u8) Iterator {
    return .initEnd(str, data);
}

// Predicates
fn isBreaker(cp: u21, data: *const Graphemes) bool {
    // Extract relevant properties.
    const cp_gbp_prop = data.gbp(cp);
    return cp == '\x0d' or cp == '\x0a' or cp_gbp_prop == .control;
}

// TODO: Make this a packed struct
// Grapheme break state.
pub const State = struct {
    bits: u3 = 0,

    pub const reset: State = .{ .bits = 0 };

    // Extended Pictographic (emoji)
    fn hasXpic(self: State) bool {
        return self.bits & 1 == 1;
    }
    fn setXpic(self: *State) void {
        self.bits |= 1;
    }
    fn unsetXpic(self: *State) void {
        self.bits &= ~@as(u3, 1);
    }

    // Regional Indicatior (flags)
    fn hasRegional(self: State) bool {
        return self.bits & 2 == 2;
    }
    fn setRegional(self: *State) void {
        self.bits |= 2;
    }
    fn unsetRegional(self: *State) void {
        self.bits &= ~@as(u3, 2);
    }

    // Indic Conjunct
    fn hasIndic(self: State) bool {
        return self.bits & 4 == 4;
    }
    fn setIndic(self: *State) void {
        self.bits |= 4;
    }
    fn unsetIndic(self: *State) void {
        self.bits &= ~@as(u3, 4);
    }
};

/// `graphemeBreak` returns true only if a grapheme break point is required
/// between `cp1` and `cp2`. `state` should start out as 0. If calling
/// iteratively over a sequence of code points, this function must be called
/// IN ORDER on ALL potential breaks in a string.
/// Modeled after the API of utf8proc's `utf8proc_grapheme_break_stateful`.
/// https://github.com/JuliaStrings/utf8proc/blob/2bbb1ba932f727aad1fab14fafdbc89ff9dc4604/utf8proc.h#L599-L617
pub fn isBreak(
    data: *const Graphemes,
    cp1: u21,
    cp2: u21,
    state: *State,
) bool {
    assert(data.isInitialized());
    // Extract relevant properties.
    const cp1_gbp_prop = data.gbp(cp1);
    const cp1_indic_prop = data.indic(cp1);
    const cp1_is_emoji = data.isEmoji(cp1);

    const cp2_gbp_prop = data.gbp(cp2);
    const cp2_indic_prop = data.indic(cp2);
    const cp2_is_emoji = data.isEmoji(cp2);

    // GB11: Emoji Extend* ZWJ x Emoji
    if (!state.hasXpic() and cp1_is_emoji) state.setXpic();
    // GB9c: Indic Conjunct Break
    if (!state.hasIndic() and cp1_indic_prop == .consonant) state.setIndic();

    // GB3: CR x LF
    if (cp1 == '\r' and cp2 == '\n') return false;

    // GB4: Control
    if (isBreaker(cp1, data)) return true;

    // GB11: Emoji Extend* ZWJ x Emoji
    if (state.hasXpic() and
        cp1_gbp_prop == .zwj and
        cp2_is_emoji)
    {
        state.unsetXpic();
        return false;
    }

    // GB9b: x (Extend | ZWJ)
    if (cp2_gbp_prop == .extend or cp2_gbp_prop == .zwj) return false;

    // GB9a: x Spacing
    if (cp2_gbp_prop == .spacing_mark) return false;

    // GB9b: Prepend x
    if (cp1_gbp_prop == .prepend and !isBreaker(cp2, data)) return false;

    // GB12, GB13: RI x RI
    if (cp1_gbp_prop == .regional_indicator and cp2_gbp_prop == .regional_indicator) {
        if (state.hasRegional()) {
            state.unsetRegional();
            return true;
        } else {
            state.setRegional();
            return false;
        }
    }

    // GB6: Hangul L x (L|V|LV|VT)
    if (cp1_gbp_prop == .l) {
        if (cp2_gbp_prop == .l or
            cp2_gbp_prop == .v or
            cp2_gbp_prop == .lv or
            cp2_gbp_prop == .lvt) return false;
    }

    // GB7: Hangul (LV | V) x (V | T)
    if (cp1_gbp_prop == .lv or cp1_gbp_prop == .v) {
        if (cp2_gbp_prop == .v or
            cp2_gbp_prop == .t) return false;
    }

    // GB8: Hangul (LVT | T) x T
    if (cp1_gbp_prop == .lvt or cp1_gbp_prop == .t) {
        if (cp2_gbp_prop == .t) return false;
    }

    // GB9c: Indic Conjunct Break
    if (state.hasIndic() and
        cp1_indic_prop == .consonant and
        (cp2_indic_prop == .extend or cp2_indic_prop == .linker))
    {
        return false;
    }

    if (state.hasIndic() and
        cp1_indic_prop == .extend and
        cp2_indic_prop == .linker)
    {
        return false;
    }

    if (state.hasIndic() and
        (cp1_indic_prop == .linker or cp1_gbp_prop == .zwj) and
        cp2_indic_prop == .consonant)
    {
        state.unsetIndic();
        return false;
    }

    return true;
}

test "Segmentation ZWJ and ZWSP emoji sequences" {
    const seq_1 = "\u{1F43B}\u{200D}\u{2744}\u{FE0F}";
    const seq_2 = "\u{1F43B}\u{200D}\u{2744}\u{FE0F}";
    const with_zwj = seq_1 ++ "\u{200D}" ++ seq_2;
    const with_zwsp = seq_1 ++ "\u{200B}" ++ seq_2;
    const no_joiner = seq_1 ++ seq_2;

    const graphemes = try Graphemes.init(std.testing.allocator);
    defer graphemes.deinit(std.testing.allocator);

    {
        var iter = graphemes.iterator(with_zwj);
        var i: usize = 0;
        while (iter.next()) |_| : (i += 1) {}
        try std.testing.expectEqual(@as(usize, 1), i);
    }

    {
        var iter = graphemes.iterator(with_zwsp);
        var i: usize = 0;
        while (iter.next()) |_| : (i += 1) {}
        try std.testing.expectEqual(@as(usize, 3), i);
    }

    {
        var iter = graphemes.iterator(no_joiner);
        var i: usize = 0;
        while (iter.next()) |_| : (i += 1) {}
        try std.testing.expectEqual(@as(usize, 2), i);
    }
}
