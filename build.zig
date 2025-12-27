// MIT License
// Copyright (c) 2025 Max Legrand
// See LICENSE for full terms.

const std = @import("std");
const LibtoolStep = @import("src/build/LibtoolStep.zig");
const XCFrameworkStep = @import("src/build/XCFrameworkStep.zig");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const objc = b.dependency("zig_objc", .{
        .optimize = optimize,
    });
    const sort = b.dependency("sort", .{
        .optimize = optimize,
    });

    // Get macOS SDK path for framework search
    const sdk_path = std.mem.trim(u8, b.run(&.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" }), " \n\r\t");
    const frameworks_path = b.fmt("{s}/System/Library/Frameworks", .{sdk_path});
    const include_path = b.fmt("{s}/usr/include", .{sdk_path});

    // Create aarch64 target
    const aarch_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
    });
    const x86_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .macos,
    });

    const aarch_lib = b.addLibrary(.{
        .name = "swap_aarch64",
        .root_module = b.addModule("swap", .{
            .root_source_file = b.path("src/lib.zig"),
            .target = aarch_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig_objc", .module = objc.module("objc") },
                .{ .name = "sort", .module = sort.module("sort") },
            },
        }),
    });
    aarch_lib.addFrameworkPath(.{ .cwd_relative = frameworks_path });
    aarch_lib.addSystemIncludePath(.{ .cwd_relative = include_path });
    aarch_lib.linkLibC();
    aarch_lib.linkFramework("CoreFoundation");
    aarch_lib.linkFramework("CoreGraphics");
    aarch_lib.linkFramework("ApplicationServices");
    aarch_lib.bundle_compiler_rt = true;

    const x86_lib = b.addLibrary(.{
        .name = "swap_x86_64",
        .root_module = b.addModule("swap", .{
            .root_source_file = b.path("src/lib.zig"),
            .target = x86_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig_objc", .module = objc.module("objc") },
                .{ .name = "sort", .module = sort.module("sort") },
            },
        }),
    });
    x86_lib.addFrameworkPath(.{ .cwd_relative = frameworks_path });
    x86_lib.addSystemIncludePath(.{ .cwd_relative = include_path });
    x86_lib.linkLibC();
    x86_lib.linkFramework("CoreFoundation");
    x86_lib.linkFramework("CoreGraphics");
    x86_lib.linkFramework("ApplicationServices");
    x86_lib.bundle_compiler_rt = true;

    // Install both libraries
    b.installArtifact(aarch_lib);
    b.installArtifact(x86_lib);

    const aarch_bin = aarch_lib.getEmittedBin();
    const x86_bin = x86_lib.getEmittedBin();

    var sources = [_]std.Build.LazyPath{ aarch_bin, x86_bin };
    const libtool = LibtoolStep.create(b, .{
        .name = "swap",
        .out_name = "libswap-universal.a",
        .sources = &sources,
    });
    libtool.step.dependOn(&aarch_lib.step);
    libtool.step.dependOn(&x86_lib.step);

    // Install the combined library
    const install_combined = b.addInstallFile(libtool.output, "lib/libswap-universal.a");
    install_combined.step.dependOn(libtool.step);
    b.getInstallStep().dependOn(&install_combined.step);

    var libraries = [_]XCFrameworkStep.Library{
        .{
            .library = libtool.output,
            .headers = b.path("src/include"),
            .dsym = null,
        },
    };
    const xcframework = XCFrameworkStep.create(b, .{
        .name = "SwapKit",
        .out_path = "zig-out/Swap.xcframework",
        .libraries = &libraries,
    });
    xcframework.step.dependOn(libtool.step);
    b.getInstallStep().dependOn(xcframework.step);

    const default_target = b.standardTargetOptions(.{});
    const swap_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = default_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig_objc", .module = objc.module("objc") },
            .{ .name = "sort", .module = sort.module("sort") },
        },
    });
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test.zig"),
        .target = default_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "swap", .module = swap_mod },
            .{ .name = "zig_objc", .module = objc.module("objc") },
            .{ .name = "sort", .module = sort.module("sort") },
        },
    });

    const tests = b.addTest(.{
        .root_module = test_mod,
        .test_runner = .{ .path = b.path("src/test_runner.zig"), .mode = .simple },
    });
    tests.addFrameworkPath(.{ .cwd_relative = frameworks_path });
    tests.addSystemIncludePath(.{ .cwd_relative = include_path });
    tests.linkLibC();
    tests.linkSystemLibrary("objc");
    tests.linkFramework("Cocoa");
    tests.linkFramework("Foundation");
    tests.linkFramework("CoreFoundation");
    tests.linkFramework("CoreGraphics");
    tests.linkFramework("ApplicationServices");

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    const exe_mod = b.addModule("swap", .{
        .root_source_file = b.path("src/exe.zig"),
        .target = default_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "swap", .module = swap_mod },
        },
    });
    const exe = b.addExecutable(.{
        .root_module = exe_mod,
        .name = "swap-exe",
    });
    exe.addFrameworkPath(.{ .cwd_relative = frameworks_path });
    exe.addSystemIncludePath(.{ .cwd_relative = include_path });
    exe.linkLibC();
    exe.linkSystemLibrary("objc");
    exe.linkFramework("Cocoa");
    exe.linkFramework("Foundation");
    exe.linkFramework("CoreFoundation");
    exe.linkFramework("CoreGraphics");
    exe.linkFramework("ApplicationServices");
    b.installArtifact(exe);
    // Add a run step
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
