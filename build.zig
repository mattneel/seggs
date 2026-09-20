const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    // The font stack needs a 0.17 development build; see build.zig.zon.
    if (comptime builtin.zig_version.major != 0 or builtin.zig_version.minor != 17) {
        @compileError("Seggs requires Zig 0.17. See .zigversion.");
    }
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zignal = b.dependency("zignal", .{
        .target = target,
        .optimize = optimize,
    });
    const qjs = b.dependency("quickjs_ng", .{
        .target = target,
        .optimize = optimize,
    });
    // Zig 0.17 removed Build.pathFromRoot; call sites use `.cwd_relative`, which
    // resolves against the build root because `zig build` runs there.
    const prefix = b.option([]const u8, "sdl-prefix", "SDL3 and SDL3_ttf installation prefix") orelse ".deps/install";
    const python = b.option([]const u8, "python", "Python executable for the ACP mock") orelse "python3";
    const glslang = b.option([]const u8, "glslang", "Path to glslangValidator") orelse "glslangValidator";

    // This target needs only Zig. SDL discovery and shader compilation stay lazy.
    const unit = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const test_step = b.step("test", "Run the pure Zig core tests");
    test_step.dependOn(&b.addRunArtifact(unit).step);

    const native_c = b.addTranslateC(.{
        .root_source_file = b.path("src/platform/native.h"),
        .target = target,
        .optimize = optimize,
    });
    native_c.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
    const native = native_c.createModule();
    native.link_libc = true;
    native.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
    native.linkSystemLibrary("SDL3", .{ .use_pkg_config = .no });
    native.linkSystemLibrary("SDL3_ttf", .{ .use_pkg_config = .no });
    if (target.result.os.tag != .windows) {
        native.linkSystemLibrary("util", .{ .use_pkg_config = .no });
        native.addRPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
    }

    // Yoga lays out interface described by extensions. Its public API is C, so
    // it crosses a translate-c boundary like SDL. The source list is pinned with
    // the dependency, so bumping Yoga fails here rather than silently linking a
    // partial library.
    const yoga_dep = b.dependency("yoga", .{});
    const yoga_root = yoga_dep.path("");
    const yoga_c = b.addTranslateC(.{
        .root_source_file = b.path("src/ui/yoga.h"),
        .target = target,
        .optimize = optimize,
    });
    yoga_c.addIncludePath(yoga_root);
    const yoga_module = yoga_c.createModule();
    yoga_module.link_libc = true;
    const yoga_lib = b.addLibrary(.{ .name = "yoga", .root_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    }) });
    yoga_lib.root_module.addIncludePath(yoga_root);
    yoga_lib.root_module.addCSourceFiles(.{
        .root = yoga_root,
        .flags = &.{ "-std=c++20", "-fno-exceptions", "-fno-rtti", "-fno-sanitize=undefined" },
        .files = &.{
            "yoga/YGConfig.cpp",
            "yoga/YGEnums.cpp",
            "yoga/YGNode.cpp",
            "yoga/YGNodeLayout.cpp",
            "yoga/YGNodeStyle.cpp",
            "yoga/YGPixelGrid.cpp",
            "yoga/YGValue.cpp",
            "yoga/algorithm/AbsoluteLayout.cpp",
            "yoga/algorithm/Baseline.cpp",
            "yoga/algorithm/Cache.cpp",
            "yoga/algorithm/CalculateLayout.cpp",
            "yoga/algorithm/FlexLine.cpp",
            "yoga/algorithm/PixelGrid.cpp",
            "yoga/config/Config.cpp",
            "yoga/debug/AssertFatal.cpp",
            "yoga/debug/Log.cpp",
            "yoga/event/event.cpp",
            "yoga/node/LayoutResults.cpp",
            "yoga/node/Node.cpp",
        },
    });

    const generated = b.addWriteFiles();
    const shader_source = if (target.result.os.tag == .macos) blk: {
        _ = generated.addCopyFile(b.path("shaders/ui.metal"), "ui.metal");
        break :blk generated.add("shaders.zig",
            \\pub const metal: []const u8 = @embedFile("ui.metal");
            \\pub const vertex_spv: []const u8 = &.{};
            \\pub const fragment_spv: []const u8 = &.{};
        );
    } else blk: {
        const vs = b.addSystemCommand(&.{ glslang, "-V", "--target-env", "vulkan1.0", "-S", "vert" });
        vs.addFileArg(b.path("shaders/ui.vert.glsl"));
        vs.addArg("-o");
        _ = generated.addCopyFile(vs.addOutputFileArg("ui.vert.spv"), "ui.vert.spv");
        const fs = b.addSystemCommand(&.{ glslang, "-V", "--target-env", "vulkan1.0", "-S", "frag" });
        fs.addFileArg(b.path("shaders/ui.frag.glsl"));
        fs.addArg("-o");
        _ = generated.addCopyFile(fs.addOutputFileArg("ui.frag.spv"), "ui.frag.spv");
        break :blk generated.add("shaders.zig",
            \\pub const metal: []const u8 = &.{};
            \\pub const vertex_spv: []const u8 = @embedFile("ui.vert.spv");
            \\pub const fragment_spv: []const u8 = @embedFile("ui.frag.spv");
        );
    };
    const shaders = b.createModule(.{ .root_source_file = shader_source, .target = target, .optimize = optimize });
    const app = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    app.addImport("native", native);
    app.addImport("shaders", shaders);
    app.addImport("quickjs", qjs.module("quickjs"));
    app.addImport("zignal", zignal.module("zignal"));
    app.addImport("yoga", yoga_module);
    // QuickJS-NG bindings use splitType, which needs LLVM codegen in Zig 0.16.
    const exe = b.addExecutable(.{ .name = "seggs", .root_module = app, .use_llvm = true });
    exe.root_module.linkLibrary(qjs.artifact("quickjs-ng"));
    exe.root_module.linkLibrary(yoga_lib);
    b.installArtifact(exe);
    b.installFile("tools/mock_agent.py", "share/seggs/mock_agent.py");
    const run = b.addRunArtifact(exe);
    run.setCwd(b.path("."));
    // Zig 0.17 replaced Build.args with per-run passthrough: `zig build run -- ...`.
    run.addPassthruArgs();
    b.step("run", "Run Seggs from the repository root").dependOn(&run.step);
    b.step("check", "Compile the native app without execution").dependOn(&exe.step);

    const smoke_module = b.createModule(.{
        .root_source_file = b.path("src/smoke.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    smoke_module.addImport("native", native);
    const smoke = b.addExecutable(.{ .name = "seggs-acp-smoke", .root_module = smoke_module });
    const smoke_run = b.addRunArtifact(smoke);
    smoke_run.setCwd(b.path("."));
    smoke_run.addArg(python);
    smoke_run.addFileArg(b.path("tools/mock_agent.py"));
    b.step("integration", "Test three native ACP transports against the local mock").dependOn(&smoke_run.step);
    const live_run = b.addRunArtifact(smoke);
    live_run.setCwd(b.path("."));
    live_run.addArg("--omp");
    b.step("integration-omp", "Run a live Oh-My-Pi ACP turn (requires omp and credentials)").dependOn(&live_run.step);
    const live_claude = b.addRunArtifact(smoke);
    live_claude.setCwd(b.path("."));
    live_claude.addArg("--claude");
    b.step("integration-claude", "Run a live Claude Code ACP turn (requires claude-agent-acp and credentials)").dependOn(&live_claude.step);

    const native_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/native_tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    native_test.root_module.addImport("native", native);
    native_test.root_module.addImport("zignal", zignal.module("zignal"));
    native_test.root_module.addImport("yoga", yoga_module);
    // The extension engine is exercised here too: a callback registered from
    // Zig is what every bundle calls into.
    native_test.root_module.addImport("quickjs", qjs.module("quickjs"));
    native_test.root_module.linkLibrary(qjs.artifact("quickjs-ng"));
    native_test.root_module.link_libcpp = true;
    native_test.root_module.linkLibrary(yoga_lib);
    const native_test_step = b.step("test-native", "Run native filesystem tests against SDL");
    native_test_step.dependOn(&b.addRunArtifact(native_test).step);

    const verify = b.step("verify", "Run core, ACP, and native filesystem tests, then compile the UI");
    verify.dependOn(test_step);
    verify.dependOn(&smoke_run.step);
    verify.dependOn(native_test_step);
    verify.dependOn(&exe.step);

    // The screenshot gate needs a display and a Vulkan driver, so it stays a
    // separate opt-in step rather than part of `verify`.
    const shot_check = b.addSystemCommand(&.{ python, "tools/screenshot_check.py" });
    shot_check.addArtifactArg(exe);
    b.step("screenshot", "Render two offscreen frames and compare the readbacks").dependOn(&shot_check.step);
}
