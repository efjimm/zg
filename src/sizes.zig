const std = @import("std");

pub fn main() void {
    const t = .{
        .gbp = @embedFile("gbp"),
        .dwp = @embedFile("dwp"),
        .canon = @embedFile("canon"),
        .compat = @embedFile("compat"),
        .hangul = @embedFile("hangul"),
        .normp = @embedFile("normp"),
        .ccc = @embedFile("ccc"),
        .gencat = @embedFile("gencat"),
        .fold = @embedFile("fold"),
        .case_prop = @embedFile("case_prop"),
        .lettercasing = @embedFile("lettercasing"),
        .scripts = @embedFile("scripts"),
        .properties = @embedFile("properties"),
    };

    inline for (std.meta.fields(@TypeOf(t))) |field| {
        const data = @field(t, field.name);
        std.debug.print("{s: <20} {: >20}\n", .{ field.name, std.fmt.fmtIntSizeDec(data.len) });
    }
}
