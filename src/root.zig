pub const codepoint = @import("code_point.zig");
pub const Graphemes = @import("Graphemes.zig");
pub const ascii = @import("ascii.zig");
pub const DisplayWidth = @import("DisplayWidth.zig");
pub const Normalize = @import("Normalize.zig");
pub const GeneralCategories = @import("GeneralCategories.zig");
pub const CaseFolding = @import("CaseFolding.zig");
pub const LetterCasing = @import("LetterCasing.zig");
pub const Scripts = @import("Scripts.zig");
pub const Properties = @import("Properties.zig");

test {
    const std = @import("std");
    std.testing.refAllDeclsRecursive(@This());
}
