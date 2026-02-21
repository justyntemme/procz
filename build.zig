const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
    });

    const dep_zclay = b.dependency("zclay", .{
        .target = target,
        .optimize = optimize,
    });

    const dep_spsc = b.dependency("spsc_queue", .{
        .target = target,
        .optimize = optimize,
    });

    const sokol_mod = dep_sokol.module("sokol");
    const zclay_mod = dep_zclay.module("zclay");
    const spsc_mod = dep_spsc.module("spsc_queue");

    // -- model modules --
    const process_mod = b.createModule(.{
        .root_source_file = b.path("src/model/process.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tree_mod = b.createModule(.{
        .root_source_file = b.path("src/model/tree.zig"),
        .target = target,
        .optimize = optimize,
    });
    tree_mod.addImport("process", process_mod);

    // -- platform modules --
    const platform_mod = b.createModule(.{
        .root_source_file = b.path("src/platform/platform.zig"),
        .target = target,
        .optimize = optimize,
    });
    platform_mod.addImport("process", process_mod);

    // -- thread modules --
    const channel_mod = b.createModule(.{
        .root_source_file = b.path("src/thread/channel.zig"),
        .target = target,
        .optimize = optimize,
    });
    channel_mod.addImport("spsc_queue", spsc_mod);
    channel_mod.addImport("process", process_mod);

    const producer_mod = b.createModule(.{
        .root_source_file = b.path("src/thread/producer.zig"),
        .target = target,
        .optimize = optimize,
    });
    producer_mod.addImport("channel", channel_mod);
    producer_mod.addImport("platform", platform_mod);
    producer_mod.addImport("process", process_mod);

    // -- stb_truetype static library --
    const stbtt_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    const stbtt_lib = b.addLibrary(.{
        .name = "stbtt",
        .linkage = .static,
        .root_module = stbtt_mod,
    });
    stbtt_mod.addCSourceFile(.{ .file = b.path("lib/stb_impl.c"), .flags = &.{} });
    stbtt_mod.addIncludePath(b.path("lib"));
    stbtt_mod.link_libc = true;

    // -- ui modules --
    const theme_mod = b.createModule(.{
        .root_source_file = b.path("src/ui/theme.zig"),
        .target = target,
        .optimize = optimize,
    });
    theme_mod.addImport("zclay", zclay_mod);

    const font_mod = b.createModule(.{
        .root_source_file = b.path("src/ui/font.zig"),
        .target = target,
        .optimize = optimize,
    });
    font_mod.addImport("sokol", sokol_mod);
    font_mod.addImport("theme", theme_mod);
    font_mod.linkLibrary(stbtt_lib);
    font_mod.addIncludePath(b.path("lib"));

    const renderer_mod = b.createModule(.{
        .root_source_file = b.path("src/ui/renderer.zig"),
        .target = target,
        .optimize = optimize,
    });
    renderer_mod.addImport("sokol", sokol_mod);
    renderer_mod.addImport("zclay", zclay_mod);
    renderer_mod.addImport("theme", theme_mod);
    renderer_mod.addImport("font", font_mod);

    const layout_mod = b.createModule(.{
        .root_source_file = b.path("src/ui/layout.zig"),
        .target = target,
        .optimize = optimize,
    });
    layout_mod.addImport("zclay", zclay_mod);
    layout_mod.addImport("process", process_mod);
    layout_mod.addImport("theme", theme_mod);

    // -- main module --
    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_mod.addImport("sokol", sokol_mod);
    main_mod.addImport("zclay", zclay_mod);
    main_mod.addImport("process", process_mod);
    main_mod.addImport("platform", platform_mod);
    main_mod.addImport("tree", tree_mod);
    main_mod.addImport("theme", theme_mod);
    main_mod.addImport("renderer", renderer_mod);
    main_mod.addImport("layout", layout_mod);
    main_mod.addImport("channel", channel_mod);
    main_mod.addImport("producer", producer_mod);
    main_mod.addImport("font", font_mod);

    // -- executable --
    const exe = b.addExecutable(.{
        .name = "procz",
        .root_module = main_mod,
    });

    if (target.result.os.tag == .macos) {
        exe.linkSystemLibrary("proc");
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        for (args) |arg| run_cmd.addArg(arg);
    }
    const run_step = b.step("run", "Run procz");
    run_step.dependOn(&run_cmd.step);

    // macOS code signing with entitlements (separate step, requires sudo)
    // Usage: zig build sign-run -Didentity="<SHA-1 hash or identity name>"
    // Option registered unconditionally so zig build always recognises -Didentity
    const signing_identity = b.option(
        []const u8,
        "identity",
        "Code signing identity (SHA-1 hash or name from `security find-identity -v -p codesigning`)",
    );

    if (target.result.os.tag == .macos) {
        if (signing_identity) |identity| {
            const codesign = b.addSystemCommand(&.{
                "sudo",
                "codesign",
                "--force",
                "--options",
                "runtime",
                "--entitlements",
            });
            codesign.addFileArg(b.path("procz.entitlements"));
            codesign.addArg("--sign");
            codesign.addArg(identity);
            codesign.addArtifactArg(exe);

            const sign_step = b.step("sign", "Build and sign with entitlements (requires sudo)");
            sign_step.dependOn(&codesign.step);

            // sign-run: build, sign, then run
            const signed_run = b.addRunArtifact(exe);
            signed_run.step.dependOn(&codesign.step);
            const sign_run_step = b.step("sign-run", "Build, sign, and run (requires sudo)");
            sign_run_step.dependOn(&signed_run.step);
        }
    }
}
