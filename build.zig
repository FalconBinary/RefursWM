// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! zig build                    - ReleaseSafe (bounds/overflow checks stay on), pure wlroots
//! zig build -Dfx=true          - + scenefx: rounded corners (GLES2 renderer)
//! zig build test               - layout unit tests (run on any host)
//! zig build --prefix ~/.local  - install to ~/.local/bin/refurswm
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.Optimize, "optimize", "build mode (default safe = ReleaseSafe)") orelse .safe;
    const fx = b.option(bool, "fx", "link scenefx for rounded corners") orelse false;

    const opts = b.addOptions();
    opts.addOption(bool, "fx", fx);
    // test builds only: screencopy + virtual input on regardless of the config (grim/wtype in CI)
    opts.addOption(bool, "testing", b.option(bool, "testing", "enable screencopy and virtual input for tests") orelse false);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/layout.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    b.step("test", "layout unit tests").dependOn(&b.addRunArtifact(tests).step);

    const wlr = "wlroots-0.20";
    const fxlib = "scenefx-0.5";

    // wlr_layer_shell_v1.h includes this generated server header
    const scan = b.addSystemCommand(&.{ "wayland-scanner", "server-header" });
    scan.addFileArg(b.path("protocol/wlr-layer-shell-unstable-v1.xml"));
    const layer_h = scan.addOutputFileArg("wlr-layer-shell-unstable-v1-protocol.h");

    const tc = b.addTranslateC(.{ .root_source_file = b.path("src/c.h"), .target = target, .optimize = optimize });
    tc.addIncludePath(layer_h.dirname());
    if (fx) tc.defineCMacro("REFURS_FX", "1");
    // translate-c needs the same -I as a C compiler; take them from pkg-config
    var pc: std.ArrayList([]const u8) = .empty;
    pc.appendSlice(b.allocator, &.{ "pkg-config", "--cflags-only-I", wlr, "wayland-server", "xkbcommon", "libinput", "pixman-1" }) catch @panic("oom");
    if (fx) pc.append(b.allocator, fxlib) catch @panic("oom");
    var it = std.mem.tokenizeAny(u8, b.run(pc.items), " \n");
    while (it.next()) |flag| if (std.mem.startsWith(u8, flag, "-I")) tc.addIncludePath(.{ .cwd_relative = flag[2..] });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .single_threaded = true,
        .pic = true,
        .strip = optimize != .debug,
    });
    mod.addImport("c", tc.createModule());
    mod.addOptions("build_options", opts);
    for ([_][]const u8{ wlr, "wayland-server", "xkbcommon", "libinput" }) |lib| mod.linkSystemLibrary(lib, .{});
    if (fx) mod.linkSystemLibrary(fxlib, .{});

    const exe = b.addExecutable(.{ .name = "refurswm", .root_module = mod });
    // hardened binary: PIE + full RELRO + immediate binding
    exe.pie = true;
    exe.link_z_relro = true;
    exe.link_z_lazy = false;
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    b.step("run", "run refurswm").dependOn(&run.step);
}
