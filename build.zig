const std = @import("std");

const codegen_files: []const []const u8 = &.{
    "codegen/gbp.zig",
    "codegen/dwp.zig",
    "codegen/canon.zig",
    "codegen/compat.zig",
    "codegen/hangul.zig",
    "codegen/normp.zig",
    "codegen/ccc.zig",
    "codegen/gencat.zig",
    "codegen/fold.zig",
    "codegen/case_prop.zig",
    "codegen/lettercasing.zig",
    "codegen/scripts.zig",
    "codegen/properties.zig",
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Display width
    const cjk = b.option(bool, "cjk", "Ambiguous code points are wide (display width: 2).") orelse false;
    const options = b.addOptions();
    try options.contents.writer().print(
        "pub const target_endian = @import(\"std\").{};\n",
        .{target.result.cpu.arch.endian()},
    );
    options.addOption(bool, "cjk", cjk);

    // Visible Controls
    const c0_width = b.option(
        i4,
        "c0_width",
        "C0 controls have this width (default: 0, <BS> <Del> default -1)",
    );
    options.addOption(?i4, "c0_width", c0_width);
    const c1_width = b.option(
        i4,
        "c1_width",
        "C1 controls have this width (default: 0)",
    ) orelse 0;
    options.addOption(i4, "c1_width", c1_width);

    options.addOptionPath("unicode_data_path", b.path("data/unicode"));

    const root_module = b.addModule("zg", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    root_module.addAnonymousImport("magic", .{ .root_source_file = b.path("src/magic_numbers.zig") });

    inline for (codegen_files) |path| {
        const name = comptime std.fs.path.stem(path);
        const gen_exe = b.addExecutable(.{
            .name = name,
            .root_source_file = b.path(path),
            .target = b.graph.host,
            .optimize = .Debug,
        });
        gen_exe.root_module.addOptions("options", options);
        const run_gen_exe = b.addRunArtifact(gen_exe);
        const output = run_gen_exe.addOutputFileArg(name ++ ".bin.z");
        root_module.addAnonymousImport(name, .{ .root_source_file = output });
    }
    root_module.addOptions("options", options);

    const tests = b.addTest(.{ .root_module = root_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run all module tests");
    test_step.dependOn(&run_tests.step);
}
