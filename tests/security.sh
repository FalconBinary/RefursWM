#!/bin/sh
# Copyright (c) 2026 Denys (FalconBinary)
# SPDX-License-Identifier: GPL-3.0-or-later
# Security regression tests, headless (pixman, no GPU). A hostile client (tests/evil) tries to crash
# RefursWM with extreme values, flood it with objects, take the clipboard from the background, steal
# the focus and keep the session from going idle while hidden. Then, with a normal build: who gets
# the privileged protocols, what the sandbox socket offers. Each check gets a fresh compositor.
# usage: tests/security.sh TESTING_BIN NORMAL_BIN EVIL OUTDIR   (TESTING_BIN built with -Dtesting=true)
set -u
BIN=$1; NORMAL=$2; EVIL=$3; OUT=$4
mkdir -p "$OUT"
R=$OUT/result.txt
: >"$R"
export WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_HEADLESS_OUTPUTS=1
fails=0
ok() { echo "PASS $1" | tee -a "$R"; }
bad() { echo "FAIL $1${2:+: $2}" | tee -a "$R"; fails=$((fails + 1)); }

start() {
	XDG_RUNTIME_DIR=$(mktemp -d); export XDG_RUNTIME_DIR
	LOG=$OUT/$1.log
	"$BIN" >"$LOG" 2>&1 &
	WM=$!
	for _ in $(seq 100); do [ -S "$XDG_RUNTIME_DIR/wayland-0" ] && break; sleep 0.05; done
	export WAYLAND_DISPLAY=wayland-0
}
# headless has no keyboard: hold a virtual one, so windows get keyboard focus events
startkb() { start "$1"; "$EVIL" keyboard 120 >/dev/null 2>&1 & sleep 0.3; }
alive() { kill -0 "$WM" 2>/dev/null; }
stop() {
	pkill -x foot; pkill -x evil; pkill -x swayidle
	if alive; then kill "$WM"; wait "$WM"; echo "exit=$?" >>"$LOG"; else wait "$WM"; echo "died=$?" >>"$LOG"; fi
}
# $1 name, $2 file the client wrote: the compositor must survive, the client must be cut off
survives() { if alive; then ok "$1: compositor alive"; else bad "$1" "compositor died ($(tail -n 3 "$LOG" | tr '\n' ' '))"; fi; }

for mode in geom layer vkey; do
	start "$mode"
	"$EVIL" "$mode" >"$OUT/$mode.txt" 2>&1
	sleep 0.3
	survives "$mode"
	stop "$mode"
done

for mode in flood popups; do
	start "$mode"
	"$EVIL" "$mode" 3000 >"$OUT/$mode.txt" 2>&1
	sleep 0.3
	survives "$mode"
	if grep -q disconnected "$OUT/$mode.txt"; then ok "$mode: client cut off ($(grep created "$OUT/$mode.txt"))"
	else bad "$mode" "no limit ($(grep created "$OUT/$mode.txt"))"; fi
	if "$EVIL" registry >/dev/null 2>&1; then ok "$mode: new clients still connect"; else bad "$mode" "new clients cannot connect"; fi
	stop "$mode"
done

# a background window sets the clipboard; the next focused window must not see that text
startkb clip
"$EVIL" clip >"$OUT/clip.txt" 2>&1 &
sleep 1; foot >/dev/null 2>&1 &
sleep 2
"$EVIL" paste >"$OUT/paste.txt" 2>&1
if grep -q EVIL "$OUT/paste.txt"; then bad clipboard "background client replaced the clipboard"
elif grep -q "set_selection sent" "$OUT/clip.txt"; then ok "clipboard: background set_selection ignored"
else bad clipboard "test did not run ($(cat "$OUT/clip.txt"))"; fi
stop clip

# focus stealing with an activation token that has a seat serial but no surface
startkb activate
"$EVIL" activate >"$OUT/activate.txt" 2>&1 &
EV=$!
sleep 1; foot >/dev/null 2>&1 &
wait $EV
if grep -q "focus: kept" "$OUT/activate.txt"; then ok "activation: surface-less token refused"
else bad activation "$(cat "$OUT/activate.txt")"; fi
stop activate

# re-activating the focused window must not cost the client a configure (and a redraw)
startkb selfactivate
"$EVIL" selfactivate 20 >"$OUT/selfactivate.txt" 2>&1
n=$(sed -n 's/.*: \([0-9]*\)$/\1/p' "$OUT/selfactivate.txt")
if [ "${n:-x}" = 0 ]; then ok "re-activation: no configures"
else bad re-activation "$(cat "$OUT/selfactivate.txt")"; fi
stop selfactivate

# an idle inhibitor counts only while its window is visible
startkb inhibit
rm -f "$OUT/idled"
swayidle -w timeout 1 "touch $OUT/idled" >/dev/null 2>&1 &
"$EVIL" inhibit 10 >"$OUT/inhibit.txt" 2>&1 &
sleep 3
if [ -e "$OUT/idled" ]; then bad "idle inhibit" "visible inhibitor ignored"; else ok "idle inhibit: visible window keeps the session awake"; fi
wtype -M logo -k 2 -m logo
sleep 3
if [ -e "$OUT/idled" ]; then ok "idle inhibit: hidden window does not"; else bad "idle inhibit" "hidden window still blocks idle"; fi
stop inhibit

# ---- normal build: privileged protocols only for programs RefursWM starts with a grant
BIN=$NORMAL
PRIV="zwlr_screencopy_manager_v1|ext_image_copy_capture_manager_v1|zwlr_data_control_manager_v1|ext_data_control_manager_v1|zwp_virtual_keyboard_manager_v1|zwlr_virtual_pointer_manager_v1|zwlr_gamma_control_manager_v1"
export REFURS_STARTUP="/usr/bin/grim $OUT/granted.png"
rm -f "$OUT/granted.png" "$OUT/shell.png"
start privileges
unset REFURS_STARTUP
sleep 2
if [ -s "$OUT/granted.png" ]; then ok "grant: grim started by RefursWM captures the screen"; else bad grant "granted grim got no screenshot"; fi
if grim "$OUT/shell.png" >"$OUT/grim-shell.txt" 2>&1; then bad grant "grim from a shell captured the screen"
else ok "grant: grim from a shell cannot ($(head -n 1 "$OUT/grim-shell.txt"))"; fi
"$EVIL" registry >"$OUT/registry-main.txt" 2>&1
if grep -Eq "$PRIV" "$OUT/registry-main.txt"; then bad "main socket" "offers $(grep -E "$PRIV" "$OUT/registry-main.txt" | tr '\n' ' ')"
elif grep -q zwlr_layer_shell_v1 "$OUT/registry-main.txt"; then ok "main socket: no privileged globals"
else bad "main socket" "registry incomplete"; fi
WAYLAND_DISPLAY=wayland-0-sandbox "$EVIL" registry >"$OUT/registry-sandbox.txt" 2>&1
HIDDEN="$PRIV|zwlr_layer_shell_v1|ext_session_lock_manager_v1|ext_idle_notifier_v1"
if grep -Eq "$HIDDEN" "$OUT/registry-sandbox.txt"; then bad "sandbox socket" "offers $(grep -E "$HIDDEN" "$OUT/registry-sandbox.txt" | tr '\n' ' ')"
elif grep -q wl_compositor "$OUT/registry-sandbox.txt"; then ok "sandbox socket: no layer-shell, lock, idle-notify or privileged globals"
else bad "sandbox socket" "cannot connect"; fi
if pgrep -P "$WM" -x refurs-launcher >/dev/null; then ok "launcher: running"; else bad launcher "no refurs-launcher child"; fi
stop privileges

echo "failures: $fails" | tee -a "$R"
exit "$fails"
