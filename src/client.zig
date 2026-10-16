// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Per-client bookkeeping, kept in the wl_client user data (wlroots leaves that slot alone).
//! Object limits: one client cannot flood the compositor with windows, popups, layer surfaces or
//! idle inhibitors. They are far above what real apps use; a client over a limit is disconnected.
const std = @import("std");
const wm = @import("wm.zig");
const c = wm.c;

pub const Kind = enum { views, popups, layers, inhibitors };

const Limit = struct { per_client: u16, total: u32 };
const limits = std.enums.EnumArray(Kind, Limit).init(.{
    .views = .{ .per_client = 256, .total = 1024 },
    .popups = .{ .per_client = 128, .total = 512 },
    .layers = .{ .per_client = 32, .total = 128 },
    .inhibitors = .{ .per_client = 16, .total = 64 },
});
var totals = std.enums.EnumArray(Kind, u32).initFill(0);

pub const State = struct {
    count: std.enums.EnumArray(Kind, u16) = .initFill(0),
};

fn free(data: ?*anyopaque) callconv(.c) void {
    if (data) |d| wm.gpa.destroy(@as(*State, @ptrCast(@alignCast(d))));
}

pub fn get(cl: ?*c.struct_wl_client) ?*State {
    return @ptrCast(@alignCast(c.wl_client_get_user_data(cl)));
}

fn ensure(cl: ?*c.struct_wl_client) ?*State {
    if (get(cl)) |st| return st;
    const st = wm.gpa.create(State) catch return null;
    st.* = .{};
    c.wl_client_set_user_data(cl, st, free);
    return st;
}

/// Counts a new object of `cl`. Null when the client is over a limit (it is then disconnected) or
/// memory ran out; the caller leaves the object alone. libwayland frees the State only after all
/// of the client's objects are destroyed, so `give` from their destroy handlers is always valid.
pub fn take(cl: ?*c.struct_wl_client, kind: Kind) ?*State {
    const st = ensure(cl) orelse {
        c.wl_client_post_no_memory(cl);
        return null;
    };
    const lim = limits.get(kind);
    const n = st.count.getPtr(kind);
    if (n.* >= lim.per_client or totals.get(kind) >= lim.total) {
        wm.log("a client went over the limit of {s}, disconnecting it", .{@tagName(kind)});
        c.wl_client_post_implementation_error(cl, "too many objects");
        return null;
    }
    n.* += 1;
    totals.getPtr(kind).* += 1;
    return st;
}

pub fn give(st: *State, kind: Kind) void {
    st.count.getPtr(kind).* -|= 1;
    totals.getPtr(kind).* -|= 1;
}

/// The client that owns a wlroots object with a `resource` field.
pub fn of(resource: ?*c.struct_wl_resource) ?*c.struct_wl_client {
    return c.wl_resource_get_client(resource);
}
