const std = @import("std");

fn isAsciiOnlyScalar(str: []const u8) bool {
    for (str) |b| {
        if (b > 127) return false;
    }
    return true;
}

/// Returns true if `str` only contains ASCII bytes. Uses SIMD if possible.
pub fn isAsciiOnly(str: []const u8) bool {
    const vec_len = std.simd.suggestVectorLength(u8) orelse
        return isAsciiOnlyScalar(str);

    const Vec = @Vector(vec_len, u8);
    var remaining = str;

    while (remaining.len >= vec_len) {
        const v1: Vec = remaining[0..vec_len].*;
        const v2: Vec = @splat(127);
        if (@reduce(.Or, v1 > v2)) return false;
        remaining = remaining[vec_len..];
    }

    return isAsciiOnlyScalar(remaining);
}

test "isAsciiOnly" {
    const ascii_only = "Hello, World! 0123456789 !@#$%^&*()_-=+";
    const not_ascii_only = "Héllo, World! 0123456789 !@#$%^&*()_-=+";

    try std.testing.expect(isAsciiOnly(ascii_only));
    try std.testing.expect(!isAsciiOnly(not_ascii_only));
}
