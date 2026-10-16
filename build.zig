// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! zig build                    - ReleaseSafe (bounds/overflow checks stay on), pure wlroots
//! zig build -Dfx=true          - + scenefx: rounded corners (GLES2 renderer)
//! zig build test               - unit tests (pure Zig, run on any host)
//! zig build evil               - hostile test client for tests/security.sh (Linux)
//! zig build --prefix ~/.local  - install to ~/.local/bin/refurswm
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.Optimize, "optimize", "build mode (default safe = ReleaseSafe)") orelse .safe;
    const fx = b.option(bool, "fx", "link scenefx for rounded corners") orelse false;

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/layout.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    b.step("test", "unit tests").dependOn(&b.addRunArtifact(tests).step);

    // everything below links Linux libraries found through pkg-config
    if (target.result.os.tag != .linux) return;

    const opts = b.addOptions();
    opts.addOption(bool, "fx", fx);
    // test builds only: screencopy + virtual input on regardless of the config (grim/wtype in CI)
    opts.addOption(bool, "testing", b.option(bool, "testing", "enable screencopy and virtual input for tests") orelse false);

    const wlr = "wlroots-0.20";
    const fxlib = "scenefx-0.5";

    // wlr_layer_shell_v1.h includes this generated server header
    const layer_h = scan(b, "server-header", b.path("protocol/wlr-layer-shell-unstable-v1.xml"), "wlr-layer-shell-unstable-v1-protocol.h");

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

    evil(b, target, optimize);
}

/// A protocol XML: a file in this repo or a path inside the wayland-protocols data dir.
const Xml = union(enum) { repo: std.Build.LazyPath, system: []const u8 };

/// Runs wayland-scanner. System XMLs are looked up through pkg-config when the step runs, so builds
/// that never need them do not need the wayland-protocols package either.
fn scanXml(b: *std.Build, kind: []const u8, xml: Xml, out: []const u8) std.Build.LazyPath {
    switch (xml) {
        .repo => |p| return scan(b, kind, p, out),
        .system => |rel| {
            const r = b.addSystemCommand(&.{ "sh", "-c", "exec wayland-scanner \"$1\" \"$(pkg-config --variable=pkgdatadir wayland-protocols)/$2\" \"$3\"", "sh", kind, rel });
            return r.addOutputFileArg(out);
        },
    }
}

fn scan(b: *std.Build, kind: []const u8, xml: std.Build.LazyPath, out: []const u8) std.Build.LazyPath {
    const r = b.addSystemCommand(&.{ "wayland-scanner", kind });
    r.addFileArg(xml);
    return r.addOutputFileArg(out);
}

/// tests/evil: a hostile Wayland client used by tests/security.sh and tests/bench.sh.
fn evil(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const protos = [_]struct { name: []const u8, xml: Xml }{
        .{ .name = "xdg-shell", .xml = .{ .system = "stable/xdg-shell/xdg-shell.xml" } },
        .{ .name = "xdg-activation-v1", .xml = .{ .system = "staging/xdg-activation/xdg-activation-v1.xml" } },
        .{ .name = "idle-inhibit-unstable-v1", .xml = .{ .system = "unstable/idle-inhibit/idle-inhibit-unstable-v1.xml" } },
        .{ .name = "wlr-layer-shell-unstable-v1", .xml = .{ .repo = b.path("protocol/wlr-layer-shell-unstable-v1.xml") } },
        .{ .name = "virtual-keyboard-unstable-v1", .xml = .{ .repo = b.path("tests/evil/protocol/virtual-keyboard-unstable-v1.xml") } },
        .{ .name = "wlr-virtual-pointer-unstable-v1", .xml = .{ .repo = b.path("tests/evil/protocol/wlr-virtual-pointer-unstable-v1.xml") } },
    };
    const tc = b.addTranslateC(.{ .root_source_file = b.path("tests/evil/c.h"), .target = target, .optimize = optimize });
    const mod = b.createModule(.{
        .root_source_file = b.path("tests/evil/evil.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    for (protos) |p| {
        const h = scanXml(b, "client-header", p.xml, b.fmt("{s}-client-protocol.h", .{p.name}));
        tc.addIncludePath(h.dirname());
        mod.addCSourceFile(.{ .file = scanXml(b, "private-code", p.xml, b.fmt("{s}-protocol.c", .{p.name})) });
    }
    mod.addImport("c", tc.createModule());
    mod.linkSystemLibrary("wayland-client", .{});
    const exe = b.addExecutable(.{ .name = "evil", .root_module = mod });
    b.step("evil", "build the hostile test client (tests/evil)").dependOn(&b.addInstallArtifact(exe, .{}).step);
}
