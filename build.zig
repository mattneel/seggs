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
    const shader_dir = b.option([]const u8, "shader-dir", "Directory of precompiled SPIR-V shaders, instead of running glslang");
    const ghostty_prefix = b.option([]const u8, "ghostty-prefix", "libghostty-vt installation prefix") orelse prefix;

    // This target needs only Zig. SDL discovery and shader compilation stay lazy.
    const unit = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    // The image path decodes with zignal - a codec library with no dependencies
    // of its own - and what it refuses is worth testing where the rest of the
    // core is tested. The decoder and the tests that prove its bounds are the
    // same build, so a limit that stops being enforced fails here rather than in
    // a run that needs a display.
    unit.root_module.addImport("zignal", zignal.module("zignal"));
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

    // libghostty-vt parses terminal data and holds terminal state. Its public
    // API is C, and the library is built by the Zig release Ghostty pins, so it
    // crosses translate-c here rather than joining this project's Zig graph.
    const ghostty_c = b.addTranslateC(.{
        .root_source_file = b.path("src/platform/ghostty.h"),
        .target = target,
        .optimize = optimize,
    });
    ghostty_c.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ ghostty_prefix, "include" }) });
    const ghostty = ghostty_c.createModule();
    ghostty.link_libc = true;
    ghostty.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ ghostty_prefix, "lib" }) });
    ghostty.linkSystemLibrary("ghostty-vt", .{ .use_pkg_config = .no });

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
    } else if (shader_dir) |dir| blk: {
        // A host where glslang cannot be run from the build graph hands over the
        // same shaders, compiled first with the command the build would run.
        _ = generated.addCopyFile(.{ .cwd_relative = b.pathJoin(&.{ dir, "ui.vert.spv" }) }, "ui.vert.spv");
        _ = generated.addCopyFile(.{ .cwd_relative = b.pathJoin(&.{ dir, "ui.frag.spv" }) }, "ui.frag.spv");
        break :blk generated.add("shaders.zig",
            \\pub const metal: []const u8 = &.{};
            \\pub const vertex_spv: []const u8 = @embedFile("ui.vert.spv");
            \\pub const fragment_spv: []const u8 = @embedFile("ui.frag.spv");
        );
    } else blk: {
        const vs = b.addSystemCommand(&.{ glslang, "-V", "--target-env", "vulkan1.0", "-S", "vert" });
        // glslang reports a file it cannot write on stdout, which a failing
        // step otherwise discards: capture it so the failure says why.
        _ = vs.captureStdOut(.{});
        vs.addFileArg(b.path("shaders/ui.vert.glsl"));
        vs.addArg("-o");
        _ = generated.addCopyFile(vs.addOutputFileArg("ui.vert.spv"), "ui.vert.spv");
        const fs = b.addSystemCommand(&.{ glslang, "-V", "--target-env", "vulkan1.0", "-S", "frag" });
        _ = fs.captureStdOut(.{});
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
    app.addImport("ghostty", ghostty);
    app.addImport("shaders", shaders);
    app.addImport("quickjs", qjs.module("quickjs"));
    app.addImport("zignal", zignal.module("zignal"));
    // MicroTex: the TeX engine behind display math.
    //
    // Its own CMake requires a GUI backend on Linux - gtkmm or Qt - and the
    // library has no such dependency. What is compiled here is the engine: the
    // atom/box tree, the parsers, the macros, and thirty-five font tables that
    // are C++ source rather than a font binary. Nothing here needs a toolkit,
    // and the drawing comes from the editor through the library's own abstract
    // Graphics2D, which src/ui/microtex_shim.cpp implements over callbacks.
    //
    // The list is explicit rather than globbed for the reason the Yoga list
    // above is: bumping the pin then fails here rather than silently compiling a
    // partial engine and rendering wrong.
    // Checked while configuring rather than left to the compiler: a missing
    // checkout means the bootstrap that fetches these did not run, and the
    // compiler's own error names a file without naming the remedy.
    for ([_][]const u8{ ".deps/src/MicroTex", ".deps/src/tinyxml2" }) |directory| {
        std.Io.Dir.cwd().access(b.graph.io, directory, .{}) catch
            std.debug.panic("{s} is missing. Run `python3 tools/bootstrap.py --sources-only`.", .{directory});
    }
    const microtex_root = b.path(".deps/src/MicroTex");
    const microtex_lib = b.addLibrary(.{ .name = "microtex", .root_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    }) });
    microtex_lib.root_module.addIncludePath(microtex_root.path(b, "src"));
    microtex_lib.root_module.addIncludePath(microtex_root.path(b, "src/graphic"));
    // The engine's one dependency that is not itself. Vendored and compiled
    // here rather than looked up with pkg-config, because the gate builds on
    // Linux, macOS, and Windows and the package is present on none of them.
    microtex_lib.root_module.addIncludePath(b.path(".deps/src/tinyxml2"));
    microtex_lib.root_module.addCSourceFiles(.{
        .root = b.path(".deps/src/tinyxml2"),
        .flags = &.{"-std=c++17"},
        .files = &.{"tinyxml2.cpp"},
    });
    microtex_lib.root_module.addCSourceFiles(.{
        .root = microtex_root,
        .flags = &.{"-std=c++17"},
        .files = &.{
            "src/atom/atom_basic.cpp",
            "src/atom/atom_char.cpp",
            "src/atom/atom_impl.cpp",
            "src/atom/atom_matrix.cpp",
            "src/atom/atom_row.cpp",
            "src/atom/atom_space.cpp",
            "src/atom/colors_def.cpp",
            "src/atom/unit_conversion.cpp",
            "src/box/box.cpp",
            "src/box/box_factory.cpp",
            "src/box/box_group.cpp",
            "src/box/box_single.cpp",
            "src/core/core.cpp",
            "src/core/formula.cpp",
            "src/core/formula_def.cpp",
            "src/core/glue.cpp",
            "src/core/localized_num.cpp",
            "src/core/macro.cpp",
            "src/core/macro_def.cpp",
            "src/core/macro_impl.cpp",
            "src/core/parser.cpp",
            "src/fonts/alphabet.cpp",
            "src/fonts/font_basic.cpp",
            "src/fonts/font_info.cpp",
            "src/fonts/fonts.cpp",
            "src/utils/string_utils.cpp",
            "src/utils/utf.cpp",
            "src/utils/utils.cpp",
            "src/res/builtin/formula_mappings.res.cpp",
            "src/res/builtin/symbol_mapping.res.cpp",
            "src/res/builtin/tex_param.res.cpp",
            "src/res/builtin/tex_symbols.res.cpp",
            "src/res/font/bi10.def.cpp",
            "src/res/font/bx10.def.cpp",
            "src/res/font/cmbsy10.def.cpp",
            "src/res/font/cmbx10.def.cpp",
            "src/res/font/cmbxti10.def.cpp",
            "src/res/font/cmex10.def.cpp",
            "src/res/font/cmmi10.def.cpp",
            "src/res/font/cmmi10_unchanged.def.cpp",
            "src/res/font/cmmib10.def.cpp",
            "src/res/font/cmmib10_unchanged.def.cpp",
            "src/res/font/cmr10.def.cpp",
            "src/res/font/cmss10.def.cpp",
            "src/res/font/cmssbx10.def.cpp",
            "src/res/font/cmssi10.def.cpp",
            "src/res/font/cmsy10.def.cpp",
            "src/res/font/cmti10.def.cpp",
            "src/res/font/cmti10_unchanged.def.cpp",
            "src/res/font/cmtt10.def.cpp",
            "src/res/font/dsrom10.def.cpp",
            "src/res/font/eufb10.def.cpp",
            "src/res/font/eufm10.def.cpp",
            "src/res/font/i10.def.cpp",
            "src/res/font/moustache.def.cpp",
            "src/res/font/msam10.def.cpp",
            "src/res/font/msbm10.def.cpp",
            "src/res/font/r10.def.cpp",
            "src/res/font/r10_unchanged.def.cpp",
            "src/res/font/rsfs10.def.cpp",
            "src/res/font/sb10.def.cpp",
            "src/res/font/sbi10.def.cpp",
            "src/res/font/si10.def.cpp",
            "src/res/font/special.def.cpp",
            "src/res/font/ss10.def.cpp",
            "src/res/font/stmary10.def.cpp",
            "src/res/font/tt10.def.cpp",
            "src/res/parser/font_parser.cpp",
            "src/res/parser/formula_parser.cpp",
            "src/res/reg/builtin_font_reg.cpp",
            "src/res/reg/builtin_syms_reg.cpp",
            "src/res/sym/amsfonts.def.cpp",
            "src/res/sym/amssymb.def.cpp",
            "src/res/sym/base.def.cpp",
            "src/res/sym/stmaryrd.def.cpp",
            "src/res/sym/symspecial.def.cpp",
            "src/latex.cpp",
            "src/render.cpp",
        },
    });

    app.addImport("yoga", yoga_module);
    // QuickJS-NG bindings use splitType, which needs LLVM codegen in Zig 0.16.
    const exe = b.addExecutable(.{ .name = "seggs", .root_module = app, .use_llvm = true });
    exe.root_module.linkLibrary(qjs.artifact("quickjs-ng"));
    exe.root_module.linkLibrary(yoga_lib);
    exe.root_module.linkLibrary(microtex_lib);
    exe.root_module.addIncludePath(microtex_root.path(b, "src"));
    exe.root_module.addIncludePath(microtex_root.path(b, "src/graphic"));
    exe.root_module.addIncludePath(b.path("src/ui"));
    // The backing that turns the engine's abstract Graphics2D into calls on
    // this renderer. It is one translation unit and it belongs to the app, not
    // to the engine: the engine ships one of these per toolkit and knows
    // nothing about ours.
    exe.root_module.addCSourceFiles(.{
        .root = b.path("."),
        .flags = &.{"-std=c++17"},
        .files = &.{"src/ui/microtex_shim.cpp"},
    });
    exe.root_module.link_libcpp = true;
    // The C surface of the shim, so Zig can call it without a C++ compiler in
    // the loop: the same translate-c step the Yoga module above uses.
    const microtex_c = b.addTranslateC(.{
        .root_source_file = b.path("src/ui/microtex.h"),
        .target = target,
        .optimize = optimize,
    });
    microtex_c.addIncludePath(b.path("src/ui"));
    const microtex_module = microtex_c.createModule();
    microtex_module.link_libc = true;
    exe.root_module.addImport("microtex", microtex_module);

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
    smoke_module.addImport("ghostty", ghostty);
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
    native_test.root_module.linkLibrary(microtex_lib);
    native_test.root_module.addIncludePath(microtex_root.path(b, "src"));
    native_test.root_module.addIncludePath(microtex_root.path(b, "src/graphic"));
    native_test.root_module.addIncludePath(b.path("src/ui"));
    native_test.root_module.addCSourceFiles(.{
        .root = b.path("."),
        .flags = &.{"-std=c++17"},
        .files = &.{"src/ui/microtex_shim.cpp"},
    });
    native_test.root_module.link_libcpp = true;
    native_test.root_module.addImport("microtex", microtex_module);
    native_test.root_module.addImport("native", native);
    native_test.root_module.addImport("ghostty", ghostty);
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
