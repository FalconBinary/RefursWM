// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Process hardening of the compositor and the launcher.
const std = @import("std");
const linux = std.os.linux;
const wm = @import("wm.zig");
const c = wm.c;

const CapHeader = extern struct { version: u32, pid: c_int };
const CapData = extern struct { effective: u32, permitted: u32, inheritable: u32 };
const cap_version_3 = 0x20080522;
const PR_CAP_AMBIENT = 47;
const PR_CAP_AMBIENT_CLEAR_ALL = 4;

/// Gives up every capability (e.g. cap_sys_nice set on the binary for realtime scheduling, which
/// is applied before this). Dropping is always allowed; without capabilities this changes nothing.
pub fn dropCaps() void {
    var hdr: CapHeader = .{ .version = cap_version_3, .pid = 0 };
    const none = [2]CapData{ .{ .effective = 0, .permitted = 0, .inheritable = 0 }, .{ .effective = 0, .permitted = 0, .inheritable = 0 } };
    _ = linux.syscall2(.capset, @intFromPtr(&hdr), @intFromPtr(&none));
    _ = linux.prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0);
}

/// Same-user processes can no longer ptrace us or read our memory, and no core dump is written
/// (it would hold clipboard data and keystrokes). Programs we start are not affected (execve resets it).
pub fn noDump() void {
    _ = linux.prctl(@intFromEnum(linux.PR.SET_DUMPABLE), 0, 0, 0, 0);
}

/// No controlling terminal: from a VT, a compromised process could push input into the shell that
/// started us (TIOCSTI). stdin is never read, so it becomes /dev/null. Call with SIGHUP ignored:
/// a session leader giving up its terminal sends itself SIGHUP.
pub fn detachTty() void {
    const tty = c.open("/dev/tty", c.O_RDWR | c.O_CLOEXEC | c.O_NOCTTY);
    if (tty >= 0) {
        _ = c.ioctl(tty, c.TIOCNOTTY);
        _ = c.close(tty);
    }
    const nul = c.open("/dev/null", c.O_RDONLY);
    if (nul > 0) {
        _ = c.dup2(nul, 0);
        _ = c.close(nul);
    }
}

/// Every client connection and every shared-memory pool holds an fd: the default soft limit of 1024
/// lets one client exhaust them all. The launcher is forked before this, so programs keep the
/// usual limit (select() breaks above 1024).
pub fn raiseFdLimit() void {
    var rl: c.struct_rlimit = undefined;
    if (c.getrlimit(c.RLIMIT_NOFILE, &rl) != 0 or rl.rlim_cur >= rl.rlim_max) return;
    rl.rlim_cur = rl.rlim_max;
    _ = c.setrlimit(c.RLIMIT_NOFILE, &rl);
}

/// SCHED_RR at the lowest realtime priority, if the rtprio limit (or cap_sys_nice) allows it:
/// the cursor and frames keep their pace under full CPU load. Children are reset to normal.
pub fn realtime() bool {
    var p: c.struct_sched_param = .{ .sched_priority = c.sched_get_priority_min(c.SCHED_RR) };
    return c.sched_setscheduler(0, c.SCHED_RR | c.SCHED_RESET_ON_FORK, &p) == 0;
}
