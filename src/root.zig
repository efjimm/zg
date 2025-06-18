const std = @import("std");

pub const ascii = @import("ascii.zig");
pub const CaseFolding = @import("CaseFolding.zig");
pub const codepoint = @import("code_point.zig");
pub const DisplayWidth = @import("DisplayWidth.zig");
pub const GeneralCategories = @import("GeneralCategories.zig");
pub const Graphemes = @import("Graphemes.zig");
pub const LetterCasing = @import("LetterCasing.zig");
pub const Normalize = @import("Normalize.zig");
pub const Properties = @import("Properties.zig");
pub const Scripts = @import("Scripts.zig");

var refs: std.EnumArray(UnicodeData, u32) = .initFill(0);
pub var case_folding: CaseFolding = undefined;
pub var display_width: DisplayWidth = undefined;
pub var general_categories: GeneralCategories = undefined;
pub var graphemes: Graphemes = undefined;
pub var letter_casing: LetterCasing = undefined;
pub var normalize: Normalize = undefined;
pub var properties: Properties = undefined;
pub var scripts: Scripts = undefined;

pub const UnicodeData = enum {
    case_folding,
    display_width,
    general_categories,
    graphemes,
    letter_casing,
    normalize,
    properties,
    scripts,
};

pub fn initData(allocator: std.mem.Allocator, comptime fields: []const UnicodeData) !void {
    for (fields) |tag| {
        const ref = refs.getPtr(tag);
        switch (tag) {
            .case_folding => {
                if (ref.* == 0) {
                    try initData(allocator, &.{.normalize});
                    case_folding = try .initWithNormalize(allocator, normalize.?);
                }
            },
            .display_width => {
                if (ref.* == 0) {
                    try initData(allocator, &.{.graphemes});
                    display_width = try .initWithGraphemes(allocator, graphemes.?);
                }
            },
            else => {
                if (ref.* == 0)
                    @field(@This(), @tagName(tag)) = try .init(allocator);
            },
        }
        ref.* += 1;
    }
}

pub fn deinitData(allocator: std.mem.Allocator, comptime fields: []const UnicodeData) void {
    for (fields) |tag| {
        const ref = refs.getPtr(tag);
        if (ref.* == 0) continue;
        ref.* -= 1;
        if (ref.* != 0) continue;

        switch (tag) {
            inline else => |t| {
                switch (t) {
                    .case_folding => {
                        deinitData(allocator, &.{.normalize});
                    },
                    .display_width => {
                        deinitData(allocator, &.{.graphemes});
                    },
                    .normalize => {
                        std.debug.assert(refs.get(.case_folding) == 0);
                    },
                    .graphemes => {
                        std.debug.assert(refs.get(.display_width) == 0);
                    },
                }
                const ptr = &@field(@This(), @tagName(tag));
                ptr.deinit(allocator);
                ptr.* = undefined;
            },
        }
    }
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
