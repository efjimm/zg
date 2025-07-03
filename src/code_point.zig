//! Provides a decoder and iterator over a UTF-8 encoded string.
//! Represents invalid data according to the Replacement of Maximal
//! Subparts algorithm.
const std = @import("std");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const assert = std.debug.assert;

/// `CodePoint` represents a Unicode code point by its code,
/// length, and offset in the source bytes.
pub const CodePoint = struct {
    code: u21,
    len: u3,
    offset: usize,
};

pub const DecodeResult = struct {
    code: u21,
    len: u3,
};

pub fn decode(bytes: []const u8) DecodeResult {
    if (bytes[0] < 0x80) return .{
        .code = bytes[0],
        .len = 1,
    };

    var st: usize = 0;
    var rune: u21 = undefined;
    inline for (0..4) |i| {
        const byte = bytes[i];
        const class = u8dfa[byte];
        st = state_dfa[st + class];
        rune = if (i == 0)
            byte & class_mask[class]
        else
            (byte & 0x3f) | (rune << 6);

        if (st == RUNE_ACCEPT) {
            return .{
                .code = rune,
                .len = i + 1,
            };
        }

        if (st == RUNE_REJECT or bytes.len == i + 1) {
            @branchHint(.cold);
            return .{
                .code = 0xfffd,
                .len = if (state_dfa[u8dfa[byte]] == RUNE_REJECT) 1 else i,
            };
        }
    } else unreachable;
}

/// `Iterator` iterates a string one `CodePoint` at-a-time.
pub const Iterator = struct {
    bytes: []const u8,
    i: usize,

    pub fn init(bytes: []const u8) Iterator {
        return .initAt(bytes, 0);
    }

    pub fn initEnd(bytes: []const u8) Iterator {
        return .initAt(bytes, bytes.len);
    }

    pub fn initAt(bytes: []const u8, index: usize) Iterator {
        assert(index <= bytes.len);
        return .{ .bytes = bytes, .i = index };
    }

    pub fn next(self: *Iterator) ?CodePoint {
        if (self.i >= self.bytes.len) return null;
        const res = decode(self.bytes[self.i..]);
        const offset = self.i;
        self.i += res.len;
        return .{
            .code = res.code,
            .len = res.len,
            .offset = offset,
        };
    }

    pub fn prev(iter: *Iterator) ?CodePoint {
        if (iter.i == 0) return null;
        while (iter.i > 0) {
            iter.i -= 1;
            if (iter.bytes[iter.i] & 0xC0 != 0x80) break;
        }

        const res = decode(iter.bytes[iter.i..]);
        return .{
            .code = res.code,
            .len = res.len,
            .offset = iter.i,
        };
    }

    pub fn peekNext(self: *Iterator) ?CodePoint {
        const saved_i = self.i;
        defer self.i = saved_i;
        return self.next();
    }

    pub fn peekPrev(self: *Iterator) ?CodePoint {
        const saved_i = self.i;
        defer self.i = saved_i;
        return self.prev();
    }
};

// A fast DFA decoder for UTF-8
//
// The algorithm used aims to be optimal, without involving SIMD, this
// strikes a balance between portability and efficiency.  That is done
// by using a DFA, represented as a few lookup tables, to track state,
// encoding valid transitions between bytes, arriving at 0 each time a
// codepoint is decoded.  In the process it builds up the value of the
// codepoint in question.
//
// The virtue of such an approach is low branching factor, achieved at
// a modest cost of storing the tables.  An embedded system might want
// to use a more familiar decision graph based on switches, but modern
// hosted environments can well afford the space, and may appreciate a
// speed increase in exchange.
//
// Credit for the algorithm goes to Björn Höhrmann, who wrote it up at
// https://bjoern.hoehrmann.de/utf-8/decoder/dfa/ .  The original
// license may be found in the ./credits folder.
//

/// Successful codepoint parse
const RUNE_ACCEPT = 0;

/// Error state
const RUNE_REJECT = 12;

/// Byte transitions: value to class
const u8dfa: [256]u8 = .{
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 00..1f
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 20..3f
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 40..5f
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 60..7f
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, // 80..9f
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, // a0..bf
    8, 8, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, // c0..df
    0xa, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x4, 0x3, 0x3, // e0..ef
    0xb, 0x6, 0x6, 0x6, 0x5, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, // f0..ff
};

/// State transition: state + class = new state
const state_dfa: [108]u8 = .{
    0, 12, 24, 36, 60, 96, 84, 12, 12, 12, 48, 72, // 0  (RUNE_ACCEPT)
    12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, // 12 (RUNE_REJECT)
    12, 0, 12, 12, 12, 12, 12, 0, 12, 0, 12, 12, // 24
    12, 24, 12, 12, 12, 12, 12, 24, 12, 24, 12, 12, // 32
    12, 12, 12, 12, 12, 12, 12, 24, 12, 12, 12, 12, // 48
    12, 24, 12, 12, 12, 12, 12, 12, 12, 24, 12, 12, // 60
    12, 12, 12, 12, 12, 12, 12, 36, 12, 36, 12, 12, // 72
    12, 36, 12, 12, 12, 12, 12, 36, 12, 36, 12, 12, // 84
    12, 36, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, // 96
};

/// State masks
const class_mask: [12]u8 = .{
    0xff,
    0,
    0b0011_1111,
    0b0001_1111,
    0b0000_1111,
    0b0000_0111,
    0b0000_0011,
    0,
    0,
    0,
    0,
    0,
};

test "decode" {
    const bytes = "🌩️";
    const cp = decode(bytes);

    try std.testing.expectEqual(0x1F329, cp.code);
    try std.testing.expectEqual(4, cp.len);
}

test Iterator {
    var iter: Iterator = .init("Hi");

    try testing.expectEqual('H', iter.next().?.code);
    try testing.expectEqual('i', iter.peekNext().?.code);
    try testing.expectEqual('i', iter.next().?.code);
    try testing.expectEqual(null, iter.peekNext());
    try testing.expectEqual(null, iter.next());
    try testing.expectEqual(null, iter.next());

    iter = .initEnd("ABC");
    try testing.expectEqual('C', iter.prev().?.code);
    try testing.expectEqual('B', iter.peekPrev().?.code);
    try testing.expectEqual('B', iter.prev().?.code);
    try testing.expectEqual('A', iter.prev().?.code);
    try testing.expectEqual(null, iter.peekPrev());
    try testing.expectEqual(null, iter.prev());
    try testing.expectEqual(null, iter.prev());

    iter = .initEnd("∅δq🦾ă");
    try testing.expectEqual('ă', iter.prev().?.code);
    try testing.expectEqual('🦾', iter.prev().?.code);
    try testing.expectEqual('q', iter.prev().?.code);
    try testing.expectEqual('δ', iter.peekPrev().?.code);
    try testing.expectEqual('δ', iter.prev().?.code);
    try testing.expectEqual('∅', iter.peekPrev().?.code);
    try testing.expectEqual('∅', iter.peekPrev().?.code);
    try testing.expectEqual('∅', iter.prev().?.code);
    try testing.expectEqual(null, iter.peekPrev());
    try testing.expectEqual(null, iter.prev());
    try testing.expectEqual(null, iter.prev());
}

test "overlongs" {
    // None of these should equal `/`, all should be byte-for-byte
    // handled as replacement characters.
    {
        const bytes = "\xc0\xaf";
        var iter: Iterator = .init(bytes);
        const first = iter.next().?;
        try expect('/' != first.code);
        try expectEqual(0xfffd, first.code);
        try testing.expectEqual(1, first.len);
        const second = iter.next().?;
        try expectEqual(0xfffd, second.code);
        try testing.expectEqual(1, second.len);
    }
    {
        const bytes = "\xe0\x80\xaf";
        var iter: Iterator = .init(bytes);
        const first = iter.next().?;
        try expect('/' != first.code);
        try expectEqual(0xfffd, first.code);
        try testing.expectEqual(1, first.len);
        const second = iter.next().?;
        try expectEqual(0xfffd, second.code);
        try testing.expectEqual(1, second.len);
        const third = iter.next().?;
        try expectEqual(0xfffd, third.code);
        try testing.expectEqual(1, third.len);
    }
    {
        const bytes = "\xf0\x80\x80\xaf";
        var iter: Iterator = .init(bytes);
        const first = iter.next().?;
        try expect('/' != first.code);
        try expectEqual(0xfffd, first.code);
        try testing.expectEqual(1, first.len);
        const second = iter.next().?;
        try expectEqual(0xfffd, second.code);
        try testing.expectEqual(1, second.len);
        const third = iter.next().?;
        try expectEqual(0xfffd, third.code);
        try testing.expectEqual(1, third.len);
        const fourth = iter.next().?;
        try expectEqual(0xfffd, fourth.code);
        try testing.expectEqual(1, fourth.len);
    }
}

test "surrogates" {
    // Substitution of Maximal Subparts dictates a
    // replacement character for each byte of a surrogate.
    {
        const bytes = "\xed\xad\xbf";
        var iter: Iterator = .init(bytes);
        const first = iter.next().?;
        try expectEqual(0xfffd, first.code);
        try testing.expectEqual(1, first.len);
        const second = iter.next().?;
        try expectEqual(0xfffd, second.code);
        try testing.expectEqual(1, second.len);
        const third = iter.next().?;
        try expectEqual(0xfffd, third.code);
        try testing.expectEqual(1, third.len);
    }
}

test "truncation" {
    // Truncation must return one (1) replacement
    // character for each stem of a valid UTF-8 codepoint
    // Sample from Table 3-11 of the Unicode Standard 16.0.0
    {
        const bytes = "\xe1\x80\xe2\xf0\x91\x92\xf1\xbf\x41";
        var iter: Iterator = .init(bytes);
        const first = iter.next().?;
        try expectEqual(0xfffd, first.code);
        try testing.expectEqual(2, first.len);
        const second = iter.next().?;
        try expectEqual(0xfffd, second.code);
        try testing.expectEqual(1, second.len);
        const third = iter.next().?;
        try expectEqual(0xfffd, third.code);
        try testing.expectEqual(3, third.len);
        const fourth = iter.next().?;
        try expectEqual(0xfffd, fourth.code);
        try testing.expectEqual(2, fourth.len);
        const fifth = iter.next().?;
        try expectEqual(0x41, fifth.code);
        try testing.expectEqual(1, fifth.len);
    }
}
