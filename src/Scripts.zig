const std = @import("std");
const assert = std.debug.assert;

data: [*]const u8,
s1_size: u32,
s2_size: u16,
s3_size: u16,

const Scripts = @This();

pub const uninitialized: Scripts = blk: {
    var s: Scripts = undefined;
    s.s1_size = 0;
    break :blk s;
};

pub fn isInitialized(s: *const Scripts) bool {
    return s.s1_size != 0;
}

pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Scripts {
    const in_bytes = @embedFile("scripts");
    var in_fbs = std.io.fixedBufferStream(in_bytes);
    var in_decomp = std.compress.flate.inflate.decompressor(.raw, in_fbs.reader());
    var reader = in_decomp.reader();

    // The generated data should match the target's endianness.
    const Header = extern struct {
        s1_len: u16,
        s2_len: u16,
        s3_len: u16,
    };

    const header: Header = reader.readStruct(Header) catch unreachable;
    const total_len = @as(usize, header.s1_len) * 2 + header.s2_len + header.s3_len;
    const bytes = try allocator.alignedAlloc(u8, .of(u16), total_len);
    const bytes_read = reader.readAll(bytes) catch unreachable;
    std.debug.assert(bytes_read == bytes.len);

    return .{
        .data = bytes.ptr,
        .s1_size = @as(u32, header.s1_len) * 2,
        .s2_size = header.s2_len,
        .s3_size = header.s3_len,
    };
}

pub fn deinit(self: Scripts, allocator: std.mem.Allocator) void {
    assert(self.isInitialized());
    const len = self.s1_size + self.s2_size + self.s3_size;
    allocator.free(self.data[0..len]);
}

/// Lookup the Script type for `cp`.
pub fn script(self: Scripts, cp: u21) ?Script {
    assert(self.isInitialized());
    const s1: []const u16 = @alignCast(@ptrCast(self.data[0..self.s1_size]));
    const s2 = self.data[self.s1_size..][0..self.s2_size];
    const s3 = self.data[self.s1_size + self.s2_size ..][0..self.s3_size];

    const byte = s3[s2[s1[cp >> 8] + (cp & 0xff)]];
    if (byte == 0) return null;
    return @enumFromInt(byte);
}

test "script" {
    const self = try init(std.testing.allocator);
    defer self.deinit(std.testing.allocator);
    try std.testing.expectEqual(Script.Latin, self.script('A').?);
}

fn testAllocator(allocator: std.mem.Allocator) !void {
    var prop = try Scripts.init(allocator);
    prop.deinit(allocator);
}

test "Allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        testAllocator,
        .{},
    );
}

/// Scripts enum
pub const Script = enum {
    none,
    Adlam,
    Ahom,
    Anatolian_Hieroglyphs,
    Arabic,
    Armenian,
    Avestan,
    Balinese,
    Bamum,
    Bassa_Vah,
    Batak,
    Bengali,
    Bhaiksuki,
    Bopomofo,
    Brahmi,
    Braille,
    Buginese,
    Buhid,
    Canadian_Aboriginal,
    Carian,
    Caucasian_Albanian,
    Chakma,
    Cham,
    Cherokee,
    Chorasmian,
    Common,
    Coptic,
    Cuneiform,
    Cypriot,
    Cypro_Minoan,
    Cyrillic,
    Deseret,
    Devanagari,
    Dives_Akuru,
    Dogra,
    Duployan,
    Egyptian_Hieroglyphs,
    Elbasan,
    Elymaic,
    Ethiopic,
    Garay,
    Georgian,
    Glagolitic,
    Gothic,
    Grantha,
    Greek,
    Gujarati,
    Gunjala_Gondi,
    Gurmukhi,
    Gurung_Khema,
    Han,
    Hangul,
    Hanifi_Rohingya,
    Hanunoo,
    Hatran,
    Hebrew,
    Hiragana,
    Imperial_Aramaic,
    Inherited,
    Inscriptional_Pahlavi,
    Inscriptional_Parthian,
    Javanese,
    Kaithi,
    Kannada,
    Katakana,
    Kawi,
    Kayah_Li,
    Kharoshthi,
    Khitan_Small_Script,
    Khmer,
    Khojki,
    Khudawadi,
    Kirat_Rai,
    Lao,
    Latin,
    Lepcha,
    Limbu,
    Linear_A,
    Linear_B,
    Lisu,
    Lycian,
    Lydian,
    Mahajani,
    Makasar,
    Malayalam,
    Mandaic,
    Manichaean,
    Marchen,
    Masaram_Gondi,
    Medefaidrin,
    Meetei_Mayek,
    Mende_Kikakui,
    Meroitic_Cursive,
    Meroitic_Hieroglyphs,
    Miao,
    Modi,
    Mongolian,
    Mro,
    Multani,
    Myanmar,
    Nabataean,
    Nag_Mundari,
    Nandinagari,
    New_Tai_Lue,
    Newa,
    Nko,
    Nushu,
    Nyiakeng_Puachue_Hmong,
    Ogham,
    Ol_Chiki,
    Ol_Onal,
    Old_Hungarian,
    Old_Italic,
    Old_North_Arabian,
    Old_Permic,
    Old_Persian,
    Old_Sogdian,
    Old_South_Arabian,
    Old_Turkic,
    Old_Uyghur,
    Oriya,
    Osage,
    Osmanya,
    Pahawh_Hmong,
    Palmyrene,
    Pau_Cin_Hau,
    Phags_Pa,
    Phoenician,
    Psalter_Pahlavi,
    Rejang,
    Runic,
    Samaritan,
    Saurashtra,
    Sharada,
    Shavian,
    Siddham,
    SignWriting,
    Sinhala,
    Sogdian,
    Sora_Sompeng,
    Soyombo,
    Sundanese,
    Sunuwar,
    Syloti_Nagri,
    Syriac,
    Tagalog,
    Tagbanwa,
    Tai_Le,
    Tai_Tham,
    Tai_Viet,
    Takri,
    Tamil,
    Tangsa,
    Tangut,
    Telugu,
    Thaana,
    Thai,
    Tibetan,
    Tifinagh,
    Tirhuta,
    Todhri,
    Toto,
    Tulu_Tigalari,
    Ugaritic,
    Vai,
    Vithkuqi,
    Wancho,
    Warang_Citi,
    Yezidi,
    Yi,
    Zanabazar_Square,
};
