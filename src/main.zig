// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! RefursWM - a tiling + scrolling Wayland compositor on wlroots.
//! No Xwayland, no IPC socket, no config parser, no timers: the only code that runs is the
//! answer to a client request or an input event.
const std = @import("std");
const wm = @import("wm.zig");
const c = wm.c;
const cfg = wm.cfg;
const view = @import("view.zig");
const output = @import("output.zig");
const input = @import("input.zig");
const client = @import("client.zig");
const s = &wm.s;
const zero = std.mem.zeroes(wm.Listener);

var l_new_output = zero;
var l_layout_change = zero;
var l_new_toplevel = zero;
var l_new_popup = zero;
var l_new_layer = zero;
var l_new_deco = zero;
var l_activate = zero;
var l_new_input = zero;
var l_vkbd = zero;
var l_vptr = zero;
var l_motion = zero;
var l_motion_abs = zero;
var l_button = zero;
var l_axis = zero;
var l_frame = zero;
var l_req_cursor = zero;
var l_cursor_shape = zero;
var l_sel = zero;
var l_primary = zero;
var l_req_drag = zero;
var l_start_drag = zero;
var l_new_lock = zero;
var l_new_inhibitor = zero;

fn tree(parent: *c.struct_wlr_scene_tree) *c.struct_wlr_scene_tree {
    return c.wlr_scene_tree_create(parent) orelse @panic("out of memory");
}

/// Hides privileged globals from sandboxed clients (flatpak etc. tag their connection
/// with security-context-v1). Unsandboxed clients see what the config enables.
fn globalFilter(cl: ?*const c.struct_wl_client, global: ?*const c.struct_wl_global, _: ?*anyopaque) callconv(.c) bool {
    for (s.privileged.items) |g| if (g == global) {
        return c.wlr_security_context_manager_v1_lookup_client(s.security, cl) == null;
    };
    return true;
}

fn privileged(g: ?*c.struct_wl_global) void {
    if (g) |x| s.privileged.append(wm.gpa, x) catch {};
}

const Inhibitor = struct {
    owner: *client.State,
    l_destroy: wm.Listener = zero,
    fn onDestroy(x: *Inhibitor, _: ?*anyopaque) void {
        wm.off(&x.l_destroy);
        client.give(x.owner, .inhibitors);
        wm.gpa.destroy(x);
        s.inhibitors -|= 1;
        c.wlr_idle_notifier_v1_set_inhibited(s.idle, s.inhibitors > 0);
    }
};

fn onNewInhibitor(data: ?*anyopaque) void {
    const ih = wm.ptr(c.struct_wlr_idle_inhibitor_v1, data);
    const owner = client.take(client.of(ih.resource), .inhibitors) orelse return;
    const x = wm.gpa.create(Inhibitor) catch return client.give(owner, .inhibitors);
    x.* = .{ .owner = owner };
    wm.on(&ih.events.destroy, &x.l_destroy, wm.cb(Inhibitor, "l_destroy", Inhibitor.onDestroy));
    s.inhibitors += 1;
    c.wlr_idle_notifier_v1_set_inhibited(s.idle, true);
}

fn setup() !void {
    const dsp = c.wl_display_create() orelse return error.Display;
    s.display = dsp;
    const loop = c.wl_display_get_event_loop(dsp);
    _ = c.wl_event_loop_add_signal(loop, c.SIGTERM, onTerminate, null);
    _ = c.wl_event_loop_add_signal(loop, c.SIGINT, onTerminate, null);
    s.backend = c.wlr_backend_autocreate(loop, &s.session) orelse return error.Backend;
    s.renderer = (if (wm.fx) c.fx_renderer_create(s.backend) else c.wlr_renderer_autocreate(s.backend)) orelse return error.Renderer;
    _ = c.wlr_renderer_init_wl_shm(s.renderer, dsp);
    s.allocator = c.wlr_allocator_autocreate(s.backend, s.renderer) orelse return error.Allocator;

    s.scene = c.wlr_scene_create() orelse return error.Scene;
    // dmabuf feedback lets the scene hand fullscreen/opaque buffers straight to the display (scanout)
    if (c.wlr_renderer_get_texture_formats(s.renderer, c.WLR_BUFFER_CAP_DMABUF) != null) {
        if (c.wlr_linux_dmabuf_v1_create_with_renderer(dsp, 5, s.renderer)) |dmabuf| c.wlr_scene_set_linux_dmabuf_v1(s.scene, dmabuf);
    }
    _ = c.wlr_compositor_create(dsp, 6, s.renderer);
    _ = c.wlr_subcompositor_create(dsp);
    _ = c.wlr_data_device_manager_create(dsp);
    _ = c.wlr_primary_selection_v1_device_manager_create(dsp);
    _ = c.wlr_viewporter_create(dsp);
    _ = c.wlr_presentation_create(dsp, s.backend, 2);
    _ = c.wlr_fractional_scale_manager_v1_create(dsp, 1);
    _ = c.wlr_single_pixel_buffer_manager_v1_create(dsp);

    s.output_layout = c.wlr_output_layout_create(dsp) orelse return error.Layout;
    _ = c.wlr_xdg_output_manager_v1_create(dsp, s.output_layout);
    s.scene_layout = c.wlr_scene_attach_output_layout(s.scene, s.output_layout) orelse return error.Scene;
    wm.on(&s.output_layout.events.change, &l_layout_change, wm.gcb(output.onLayoutChange));
    wm.on(&s.backend.events.new_output, &l_new_output, wm.gcb(output.onNewOutput));

    // stacking order, bottom to top
    const root = &s.scene.*.tree;
    s.layers = .{
        .color = tree(root),
        .background = tree(root),
        .bottom = tree(root),
        .tiled = tree(root),
        .floating = tree(root),
        .top = tree(root),
        .fullscreen = tree(root),
        .overlay = tree(root),
        .dnd = tree(root),
        .lock_bg = tree(root),
        .lock = tree(root),
    };
    c.wlr_scene_node_set_enabled(&s.layers.lock_bg.*.node, false);

    const xdg = c.wlr_xdg_shell_create(dsp, 6) orelse return error.XdgShell;
    wm.on(&xdg.*.events.new_toplevel, &l_new_toplevel, wm.gcb(view.onNewToplevel));
    wm.on(&xdg.*.events.new_popup, &l_new_popup, wm.gcb(view.onNewPopup));
    const layer = c.wlr_layer_shell_v1_create(dsp, 4) orelse return error.LayerShell;
    wm.on(&layer.*.events.new_surface, &l_new_layer, wm.gcb(output.onNewLayerSurface));
    const deco = c.wlr_xdg_decoration_manager_v1_create(dsp) orelse return error.Decoration;
    wm.on(&deco.*.events.new_toplevel_decoration, &l_new_deco, wm.gcb(view.onNewDecoration));
    const act = c.wlr_xdg_activation_v1_create(dsp) orelse return error.Activation;
    wm.on(&act.*.events.request_activate, &l_activate, wm.gcb(view.onActivate));

    s.cursor = c.wlr_cursor_create() orelse return error.Cursor;
    c.wlr_cursor_attach_output_layout(s.cursor, s.output_layout);
    s.xcursor = c.wlr_xcursor_manager_create(cfg.cursor_theme, cfg.cursor_size) orelse return error.Cursor;
    wm.on(&s.cursor.events.motion, &l_motion, wm.gcb(input.onMotion));
    wm.on(&s.cursor.events.motion_absolute, &l_motion_abs, wm.gcb(input.onMotionAbsolute));
    wm.on(&s.cursor.events.button, &l_button, wm.gcb(input.onButton));
    wm.on(&s.cursor.events.axis, &l_axis, wm.gcb(input.onAxis));
    wm.on(&s.cursor.events.frame, &l_frame, wm.gcb(input.onFrame));
    const shape = c.wlr_cursor_shape_manager_v1_create(dsp, 1) orelse return error.Cursor;
    wm.on(&shape.*.events.request_set_shape, &l_cursor_shape, wm.gcb(input.onCursorShape));
    s.relptr = c.wlr_relative_pointer_manager_v1_create(dsp) orelse return error.Pointer;

    if (!input.init()) return error.Keymap;
    wm.on(&s.backend.events.new_input, &l_new_input, wm.gcb(input.onNewInput));
    s.seat = c.wlr_seat_create(dsp, "seat0") orelse return error.Seat;
    wm.on(&s.seat.events.request_set_cursor, &l_req_cursor, wm.gcb(input.onRequestCursor));
    wm.on(&s.seat.events.request_set_selection, &l_sel, wm.gcb(input.onSetSelection));
    wm.on(&s.seat.events.request_set_primary_selection, &l_primary, wm.gcb(input.onSetPrimary));
    wm.on(&s.seat.events.request_start_drag, &l_req_drag, wm.gcb(input.onRequestDrag));
    wm.on(&s.seat.events.start_drag, &l_start_drag, wm.gcb(input.onStartDrag));

    s.idle = c.wlr_idle_notifier_v1_create(dsp) orelse return error.Idle;
    const inhibit = c.wlr_idle_inhibit_v1_create(dsp) orelse return error.Idle;
    wm.on(&inhibit.*.events.new_inhibitor, &l_new_inhibitor, wm.gcb(onNewInhibitor));
    const lock = c.wlr_session_lock_manager_v1_create(dsp) orelse return error.Lock;
    wm.on(&lock.*.events.new_lock, &l_new_lock, wm.gcb(output.onNewLock));

    // sandboxed clients may not draw over everything or lock the screen either
    s.security = c.wlr_security_context_manager_v1_create(dsp) orelse return error.Security;
    privileged(layer.*.global);
    privileged(lock.*.global);
    if (cfg.allow_screencopy or wm.testing) {
        privileged(if (c.wlr_screencopy_manager_v1_create(dsp)) |x| x.*.global else null);
        privileged(if (c.wlr_ext_image_copy_capture_manager_v1_create(dsp, 1)) |x| x.*.global else null);
        privileged(if (c.wlr_ext_output_image_capture_source_manager_v1_create(dsp, 1)) |x| x.*.global else null);
    }
    if (cfg.allow_data_control) {
        privileged(if (c.wlr_data_control_manager_v1_create(dsp)) |x| x.*.global else null);
        privileged(if (c.wlr_ext_data_control_manager_v1_create(dsp, 1)) |x| x.*.global else null);
    }
    if (cfg.allow_virtual_input or wm.testing) {
        const vk = c.wlr_virtual_keyboard_manager_v1_create(dsp) orelse return error.VirtualInput;
        wm.on(&vk.*.events.new_virtual_keyboard, &l_vkbd, wm.gcb(input.onVirtualKeyboard));
        privileged(vk.*.global);
        const vp = c.wlr_virtual_pointer_manager_v1_create(dsp) orelse return error.VirtualInput;
        wm.on(&vp.*.events.new_virtual_pointer, &l_vptr, wm.gcb(input.onVirtualPointer));
        privileged(vp.*.global);
    }
    if (cfg.allow_gamma_control) {
        const g = c.wlr_gamma_control_manager_v1_create(dsp) orelse return error.Gamma;
        c.wlr_scene_set_gamma_control_manager_v1(s.scene, g);
        privileged(g.*.global);
    }
    c.wl_display_set_global_filter(dsp, globalFilter, null);
}

fn ignore(_: c_int) callconv(.c) void {}

/// SIGTERM/SIGINT end the session cleanly (VT and DRM state restored); delivered via signalfd
fn onTerminate(_: c_int, _: ?*anyopaque) callconv(.c) c_int {
    c.wl_display_terminate(s.display);
    return 0;
}

pub fn main() u8 {
    c.wlr_log_init(if (c.getenv("REFURS_DEBUG") != null) c.WLR_DEBUG else c.WLR_ERROR, null);
    // children are reaped by the kernel; a dead client socket must not kill us
    var sa = std.mem.zeroes(c.struct_sigaction);
    sa.sa_flags = c.SA_NOCLDWAIT;
    _ = c.sigaction(c.SIGCHLD, &sa, null);
    sa.sa_flags = 0;
    sa.__sigaction_handler.sa_handler = ignore;
    _ = c.sigaction(c.SIGPIPE, &sa, null);

    setup() catch |e| {
        wm.log("startup failed: {s}", .{@errorName(e)});
        return 1;
    };
    const sock = c.wl_display_add_socket_auto(s.display) orelse {
        wm.log("cannot create a Wayland socket", .{});
        return 1;
    };
    if (!c.wlr_backend_start(s.backend)) {
        wm.log("cannot start the backend", .{});
        return 1;
    }
    _ = c.setenv("WAYLAND_DISPLAY", sock, 1);
    _ = c.setenv("XDG_CURRENT_DESKTOP", "RefursWM", 1);
    _ = c.setenv("XDG_SESSION_TYPE", "wayland", 1);
    _ = c.unsetenv("DISPLAY");
    var size_buf: [16]u8 = undefined;
    if (std.fmt.bufPrintSentinel(&size_buf, "{d}", .{cfg.cursor_size}, 0)) |sz| {
        _ = c.setenv("XCURSOR_SIZE", sz.ptr, 1);
    } else |_| {}
    if (cfg.cursor_theme) |th| _ = c.setenv("XCURSOR_THEME", th, 1);
    wm.log("running on WAYLAND_DISPLAY={s}", .{sock});

    const hooks: []const wm.T.Cmd = if (s.theme == .dark) &cfg.theme_hooks_dark else &cfg.theme_hooks_light;
    for (hooks) |h| wm.spawn(h);
    for (cfg.autostart) |cmd| wm.spawn(cmd);
    // REFURS_STARTUP="prog arg" runs one extra program (handy for tests); split on spaces, no shell
    if (c.getenv("REFURS_STARTUP")) |st| {
        var args: [16][*:0]const u8 = undefined;
        var n: usize = 0;
        var buf: [512:0]u8 = @splat(0);
        const src = std.mem.span(st);
        if (src.len < buf.len) {
            @memcpy(buf[0..src.len], src);
            for (buf[0..src.len]) |*ch| if (ch.* == ' ') {
                ch.* = 0;
            };
            var it = std.mem.tokenizeScalar(u8, buf[0..src.len], 0);
            while (it.next()) |tok| if (n < args.len) {
                args[n] = @ptrCast(tok.ptr);
                n += 1;
            };
            wm.spawn(args[0..n]);
        }
    }

    c.wl_display_run(s.display);

    c.wl_display_destroy_clients(s.display);
    // wlroots asserts that nobody still listens to an object it destroys
    for ([_]*wm.Listener{
        &l_new_output, &l_layout_change, &l_new_toplevel,  &l_new_popup, &l_new_layer,
        &l_new_deco,   &l_activate,      &l_new_input,     &l_vkbd,      &l_vptr,
        &l_motion,     &l_motion_abs,    &l_button,        &l_axis,      &l_frame,
        &l_req_cursor, &l_cursor_shape,  &l_sel,           &l_primary,   &l_req_drag,
        &l_start_drag, &l_new_lock,      &l_new_inhibitor,
    }) |l| wm.off(l);
    output.shutdown();
    input.shutdown();
    c.wlr_backend_destroy(s.backend);
    c.wl_display_destroy(s.display);
    return 0;
}
