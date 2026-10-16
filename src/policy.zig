// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Security decisions as pure functions (no Wayland here, unit-tested on any host).
const std = @import("std");
const T = @import("types.zig");

/// How a global is offered.
pub const Class = union(enum) {
    /// everyone
    normal,
    /// not to sandboxed clients: layer-shell (could cover the screen with a fake dialog),
    /// session-lock (could fake a lock screen), idle-notify (reveals when the user is away)
    sandbox_hidden,
    /// only to clients RefursWM started with a grant for this capability
    privileged: T.Caps,
};

/// `caps`: what the client was granted; `sandboxed`: flatpak & co (security-context-v1) or a
/// client of the sandbox socket. `testing` builds hand privileged globals to every unsandboxed
/// client, so the test scripts can run grim, wtype and wlrctl from a shell.
pub fn allowGlobal(class: Class, caps: T.Caps, sandboxed: bool, testing: bool) bool {
    return switch (class) {
        .normal => true,
        .sandbox_hidden => !sandboxed,
        .privileged => |need| !sandboxed and (testing or caps.any(need)),
    };
}

/// The capabilities `path` was granted, null for programs without a grant. Only exact absolute
/// paths match: a program found through $PATH could be a look-alike in a user-writable directory.
pub fn grantOf(grants: []const T.Grant, path: []const u8) ?T.Caps {
    if (path.len == 0 or path[0] != '/') return null;
    for (grants) |g| if (std.mem.eql(u8, g.path, path)) return g.caps;
    return null;
}

/// The display name the launcher puts into WAYLAND_DISPLAY: what wl_display_add_socket_auto makes.
pub fn validDisplayName(n: []const u8) bool {
    if (!std.mem.startsWith(u8, n, "wayland-") or n.len == 8 or n.len > 12) return false;
    for (n[8..]) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

/// xdg-activation tokens as wlroots makes them (hex); anything else never reaches an environment.
pub fn validToken(t: []const u8) bool {
    if (t.len == 0 or t.len > 64) return false;
    for (t) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return false;
    return true;
}

const tt = std.testing;

test "display names and tokens are validated before they reach an environment" {
    try tt.expect(validDisplayName("wayland-0"));
    try tt.expect(validDisplayName("wayland-32"));
    try tt.expect(!validDisplayName("wayland-"));
    try tt.expect(!validDisplayName("wayland-../x"));
    try tt.expect(!validDisplayName("/tmp/wayland-0"));
    try tt.expect(validToken("0123456789abcdef0123456789abcdef"));
    try tt.expect(!validToken(""));
    try tt.expect(!validToken("a b"));
    try tt.expect(!validToken("a\nLD_PRELOAD=x"));
}

test "privileged globals only with a matching grant, never for sandboxes" {
    const shot: T.Caps = .{ .screencopy = true };
    const clip: T.Caps = .{ .data_control = true };
    try tt.expect(allowGlobal(.normal, .{}, true, false));
    try tt.expect(allowGlobal(.sandbox_hidden, .{}, false, false));
    try tt.expect(!allowGlobal(.sandbox_hidden, .{}, true, false));
    try tt.expect(!allowGlobal(.{ .privileged = shot }, .{}, false, false));
    try tt.expect(!allowGlobal(.{ .privileged = shot }, clip, false, false));
    try tt.expect(allowGlobal(.{ .privileged = shot }, shot, false, false));
    try tt.expect(!allowGlobal(.{ .privileged = shot }, shot, true, false));
    try tt.expect(allowGlobal(.{ .privileged = shot }, .{}, false, true));
    try tt.expect(!allowGlobal(.{ .privileged = shot }, .{}, true, true));
}

test "grants match exact absolute paths only" {
    const g = [_]T.Grant{.{ .path = "/usr/bin/grim", .caps = .{ .screencopy = true } }};
    try tt.expect(grantOf(&g, "/usr/bin/grim") != null);
    try tt.expect(grantOf(&g, "grim") == null);
    try tt.expect(grantOf(&g, "/usr/bin/grim2") == null);
    try tt.expect(grantOf(&g, "/home/u/.local/bin/grim") == null);
    try tt.expect(grantOf(&g, "") == null);
}
