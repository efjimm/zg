const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const ascii = @import("ascii.zig");
const Normalize = @import("Normalize.zig");

cutoff: u21,
cwcf_exceptions_min: u21,
cwcf_exceptions_max: u21,
cwcf_exceptions: []const u21,
multiple_start: u21,
s1: []const u8,
s2: []const u8,
s3: []const i24,
normalize: Normalize,
owns_normalize: bool,

const CaseFolding = @This();

pub const uninitialized: CaseFolding = blk: {
    var c: CaseFolding = undefined;
    c.s1 = &.{};
    break :blk c;
};

pub fn isInitialized(c: *const CaseFolding) bool {
    return c.s1.len != 0;
}

pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!CaseFolding {
    const normalize: Normalize = try .init(allocator);
    errdefer normalize.deinit(allocator);

    var case_fold = try initWithNormalize(allocator, normalize);
    case_fold.owns_normalize = true;
    return case_fold;
}

pub fn initWithNormalize(
    allocator: std.mem.Allocator,
    normalize: Normalize,
) std.mem.Allocator.Error!CaseFolding {
    const in_bytes = @embedFile("fold");
    var in_fbs = std.io.fixedBufferStream(in_bytes);
    var in_decomp = std.compress.flate.inflate.decompressor(.raw, in_fbs.reader());
    var reader = in_decomp.reader();

    const Header = extern struct {
        cutoff: u32,
        multiple_start: u32,

        s1_len: u32,
        s2_len: u32,
        s3_len: u32,

        cwcf_exceptions_min: u32,
        cwcf_exceptions_max: u32,
        cwcf_exceptions_len: u32,
    };

    const header = reader.readStruct(Header) catch unreachable;
    const s3_size = header.s3_len * 4;
    const cwcf_exceptions_size = header.cwcf_exceptions_len * 4;

    const total_size = header.s1_len + header.s2_len + s3_size + cwcf_exceptions_size;
    const bytes = try allocator.alignedAlloc(u8, .of(u32), total_size);
    const bytes_read = reader.read(bytes) catch unreachable;
    std.debug.assert(bytes_read == total_size);

    const s3: []const i24 = @ptrCast(bytes[0..s3_size]);
    const cwcf_exceptions: []const u21 = @ptrCast(@alignCast(
        bytes[s3_size..][0..cwcf_exceptions_size],
    ));
    const s1 = bytes[s3_size + cwcf_exceptions_size ..][0..header.s1_len];
    const s2 = bytes[s3_size + cwcf_exceptions_size + header.s1_len ..];
    std.debug.assert(s2.len == header.s2_len);

    return .{
        .cutoff = @intCast(header.cutoff),
        .multiple_start = @intCast(header.multiple_start),
        .s1 = s1,
        .s2 = s2,
        .s3 = s3,
        .cwcf_exceptions_min = @intCast(header.cwcf_exceptions_min),
        .cwcf_exceptions_max = @intCast(header.cwcf_exceptions_max),
        .cwcf_exceptions = cwcf_exceptions,
        .owns_normalize = false,
        .normalize = normalize,
    };
}

pub fn deinit(fdata: *const CaseFolding, allocator: std.mem.Allocator) void {
    assert(fdata.isInitialized());
    const total_size = fdata.s1.len + fdata.s2.len + fdata.s3.len * 4 + fdata.cwcf_exceptions.len * 4;
    const slice: []align(4) const u8 = @alignCast(fdata.s1.ptr[0..total_size]);
    allocator.free(slice);
    if (fdata.owns_normalize) fdata.normalize.deinit(allocator);
}

/// Returns the case fold for `cp`.
pub fn caseFold(fdata: *const CaseFolding, cp: u21, buf: []u21) []const u21 {
    assert(fdata.isInitialized());
    if (cp >= fdata.cutoff) return &.{};

    const stage1_val = fdata.s1[cp >> 8];
    if (stage1_val == 0) return &.{};

    const stage2_index = @as(usize, stage1_val) * 256 + (cp & 0xFF);
    const stage3_index = fdata.s2[stage2_index];

    if (stage3_index & 0x80 != 0) {
        const real_index = @as(usize, fdata.multiple_start) + (stage3_index ^ 0x80) * 3;
        const mapping = std.mem.sliceTo(fdata.s3[real_index..][0..3], 0);
        for (mapping, 0..) |c, i| buf[i] = @intCast(c);

        return buf[0..mapping.len];
    }

    const offset = fdata.s3[stage3_index];
    if (offset == 0) return &.{};

    buf[0] = @intCast(@as(i32, cp) + offset);

    return buf[0..1];
}

/// Produces the case folded code points for `cps`. Caller must free returned
/// slice with `allocator`.
pub fn caseFoldAlloc(
    casefold: *const CaseFolding,
    allocator: std.mem.Allocator,
    cps: []const u21,
) std.mem.Allocator.Error![]const u21 {
    assert(casefold.isInitialized());
    var cfcps = std.ArrayList(u21).init(allocator);
    defer cfcps.deinit();
    var buf: [3]u21 = undefined;

    for (cps) |cp| {
        const cf = casefold.caseFold(cp, &buf);

        if (cf.len == 0) {
            try cfcps.append(cp);
        } else {
            try cfcps.appendSlice(cf);
        }
    }

    return try cfcps.toOwnedSlice();
}

/// Returns true when caseFold(NFD(`cp`)) != NFD(`cp`).
pub fn cpChangesWhenCaseFolded(casefold: *const CaseFolding, cp: u21) bool {
    assert(casefold.isInitialized());
    var buf: [3]u21 = undefined;
    const has_mapping = casefold.caseFold(cp, &buf).len != 0;
    return has_mapping and !casefold.isCwcfException(cp);
}

pub fn changesWhenCaseFolded(casefold: *const CaseFolding, cps: []const u21) bool {
    assert(casefold.isInitialized());
    return for (cps) |cp| {
        if (casefold.cpChangesWhenCaseFolded(cp)) break true;
    } else false;
}

fn isCwcfException(casefold: *const CaseFolding, cp: u21) bool {
    return cp >= casefold.cwcf_exceptions_min and
        cp <= casefold.cwcf_exceptions_max and
        std.mem.indexOfScalar(u21, casefold.cwcf_exceptions, cp) != null;
}

/// Caseless compare `a` and `b` by decomposing to NFKD. This is the most
/// comprehensive comparison possible, but slower than `canonCaselessMatch`.
pub fn compatCaselessMatch(
    casefold: *const CaseFolding,
    allocator: std.mem.Allocator,
    a: []const u8,
    b: []const u8,
) std.mem.Allocator.Error!bool {
    assert(casefold.isInitialized());
    if (ascii.isAsciiOnly(a) and ascii.isAsciiOnly(b)) return std.ascii.eqlIgnoreCase(a, b);

    // Process a
    const nfd_a = try casefold.normalize.nfxdCodePoints(allocator, a, .nfd);
    defer allocator.free(nfd_a);

    var need_free_cf_nfd_a = false;
    var cf_nfd_a: []const u21 = nfd_a;
    if (casefold.changesWhenCaseFolded(nfd_a)) {
        cf_nfd_a = try casefold.caseFoldAlloc(allocator, nfd_a);
        need_free_cf_nfd_a = true;
    }
    defer if (need_free_cf_nfd_a) allocator.free(cf_nfd_a);

    const nfkd_cf_nfd_a = try casefold.normalize.nfkdCodePoints(allocator, cf_nfd_a);
    defer allocator.free(nfkd_cf_nfd_a);
    const cf_nfkd_cf_nfd_a = try casefold.caseFoldAlloc(allocator, nfkd_cf_nfd_a);
    defer allocator.free(cf_nfkd_cf_nfd_a);
    const nfkd_cf_nfkd_cf_nfd_a = try casefold.normalize.nfkdCodePoints(allocator, cf_nfkd_cf_nfd_a);
    defer allocator.free(nfkd_cf_nfkd_cf_nfd_a);

    // Process b
    const nfd_b = try casefold.normalize.nfxdCodePoints(allocator, b, .nfd);
    defer allocator.free(nfd_b);

    var need_free_cf_nfd_b = false;
    var cf_nfd_b: []const u21 = nfd_b;
    if (casefold.changesWhenCaseFolded(nfd_b)) {
        cf_nfd_b = try casefold.caseFoldAlloc(allocator, nfd_b);
        need_free_cf_nfd_b = true;
    }
    defer if (need_free_cf_nfd_b) allocator.free(cf_nfd_b);

    const nfkd_cf_nfd_b = try casefold.normalize.nfkdCodePoints(allocator, cf_nfd_b);
    defer allocator.free(nfkd_cf_nfd_b);
    const cf_nfkd_cf_nfd_b = try casefold.caseFoldAlloc(allocator, nfkd_cf_nfd_b);
    defer allocator.free(cf_nfkd_cf_nfd_b);
    const nfkd_cf_nfkd_cf_nfd_b = try casefold.normalize.nfkdCodePoints(allocator, cf_nfkd_cf_nfd_b);
    defer allocator.free(nfkd_cf_nfkd_cf_nfd_b);

    return std.mem.eql(u21, nfkd_cf_nfkd_cf_nfd_a, nfkd_cf_nfkd_cf_nfd_b);
}

test "compatCaselessMatch" {
    const allocator = std.testing.allocator;

    const caser = try CaseFolding.init(allocator);
    defer caser.deinit(allocator);

    try std.testing.expect(try caser.compatCaselessMatch(allocator, "ascii only!", "ASCII Only!"));

    const a = "Héllo World! \u{3d3}";
    const b = "He\u{301}llo World! \u{3a5}\u{301}";
    try std.testing.expect(try caser.compatCaselessMatch(allocator, a, b));

    const c = "He\u{301}llo World! \u{3d2}\u{301}";
    try std.testing.expect(try caser.compatCaselessMatch(allocator, a, c));
}

/// Performs canonical caseless string matching by decomposing to NFD. This is
/// faster than `compatCaselessMatch`, but less comprehensive.
pub fn canonCaselessMatch(
    casefold: *const CaseFolding,
    allocator: std.mem.Allocator,
    a: []const u8,
    b: []const u8,
) std.mem.Allocator.Error!bool {
    assert(casefold.isInitialized());
    if (ascii.isAsciiOnly(a) and ascii.isAsciiOnly(b)) return std.ascii.eqlIgnoreCase(a, b);

    // Process a
    const nfd_a = try casefold.normalize.nfxdCodePoints(allocator, a, .nfd);
    defer allocator.free(nfd_a);

    var need_free_cf_nfd_a = false;
    var cf_nfd_a: []const u21 = nfd_a;
    if (casefold.changesWhenCaseFolded(nfd_a)) {
        cf_nfd_a = try casefold.caseFoldAlloc(allocator, nfd_a);
        need_free_cf_nfd_a = true;
    }
    defer if (need_free_cf_nfd_a) allocator.free(cf_nfd_a);

    var need_free_nfd_cf_nfd_a = false;
    var nfd_cf_nfd_a = cf_nfd_a;
    if (!need_free_cf_nfd_a) {
        nfd_cf_nfd_a = try casefold.normalize.nfdCodePoints(allocator, cf_nfd_a);
        need_free_nfd_cf_nfd_a = true;
    }
    defer if (need_free_nfd_cf_nfd_a) allocator.free(nfd_cf_nfd_a);

    // Process b
    const nfd_b = try casefold.normalize.nfxdCodePoints(allocator, b, .nfd);
    defer allocator.free(nfd_b);

    var need_free_cf_nfd_b = false;
    var cf_nfd_b: []const u21 = nfd_b;
    if (casefold.changesWhenCaseFolded(nfd_b)) {
        cf_nfd_b = try casefold.caseFoldAlloc(allocator, nfd_b);
        need_free_cf_nfd_b = true;
    }
    defer if (need_free_cf_nfd_b) allocator.free(cf_nfd_b);

    var need_free_nfd_cf_nfd_b = false;
    var nfd_cf_nfd_b = cf_nfd_b;
    if (!need_free_cf_nfd_b) {
        nfd_cf_nfd_b = try casefold.normalize.nfdCodePoints(allocator, cf_nfd_b);
        need_free_nfd_cf_nfd_b = true;
    }
    defer if (need_free_nfd_cf_nfd_b) allocator.free(nfd_cf_nfd_b);

    return std.mem.eql(u21, nfd_cf_nfd_a, nfd_cf_nfd_b);
}

test "canonCaselessMatch" {
    const allocator = std.testing.allocator;

    const caser = try CaseFolding.init(allocator);
    defer caser.deinit(allocator);

    try std.testing.expect(try caser.canonCaselessMatch(allocator, "ascii only!", "ASCII Only!"));

    const a = "Héllo World! \u{3d3}";
    const b = "He\u{301}llo World! \u{3a5}\u{301}";
    try std.testing.expect(!try caser.canonCaselessMatch(allocator, a, b));

    const c = "He\u{301}llo World! \u{3d2}\u{301}";
    try std.testing.expect(try caser.canonCaselessMatch(allocator, a, c));
}

fn testAllocations(allocator: std.mem.Allocator) !void {
    // With normalize provided
    {
        const normalize = try Normalize.init(allocator);
        defer normalize.deinit(allocator);
        const caser1 = try CaseFolding.initWithNormalize(allocator, normalize);
        defer caser1.deinit(allocator);
    }
    // With normalize owned
    {
        const caser2 = try CaseFolding.init(allocator);
        defer caser2.deinit(allocator);
    }
}

test "Allocation Failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        testAllocations,
        .{},
    );
}
