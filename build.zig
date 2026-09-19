const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    if (comptime builtin.zig_version.major != 0 or builtin.zig_version.minor != 16 or builtin.zig_version.patch != 0 or builtin.zig_version.pre != null) {
        @compileError("Seggs requires Zig 0.16.0. See .zigversion.");
    }
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const prefix = b.option([]const u8, "sdl-prefix", "SDL3 and SDL3_ttf installation prefix") orelse b.pathFromRoot(".deps/install");
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
    native.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib64" }) });
    native.linkSystemLibrary("SDL3", .{ .use_pkg_config = .no });
    native.linkSystemLibrary("SDL3_ttf", .{ .use_pkg_config = .no });
    if (target.result.os.tag != .windows) {
        native.addRPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
        native.addRPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib64" }) });
    }

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
    const exe = b.addExecutable(.{ .name = "seggs", .root_module = app });
    b.installArtifact(exe);
    b.installFile("tools/mock_agent.py", "share/seggs/mock_agent.py");
    const run = b.addRunArtifact(exe);
    run.setCwd(b.path("."));
    if (b.args) |args| run.addArgs(args);
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
    const verify = b.step("verify", "Run core and ACP tests, then compile the UI");
    verify.dependOn(test_step);
    verify.dependOn(&smoke_run.step);
    verify.dependOn(&exe.step);
}
