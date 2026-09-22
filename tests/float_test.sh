#!/usr/bin/env bash
# Automated tests for the floating window (scripts/float.sh + scripts/float.tmux).
#
# Nothing here touches your real tmux server or your real sessions. Two private
# servers are used, on their own sockets:
#
#   float-test-outer  one pane whose size we can set exactly with resize-window.
#                     That pane runs a client of the server under test, so the
#                     "terminal" the float lives in has a size we control —
#                     which is how font zoom / window resize is simulated.
#   float-test        the server under test: a normal session to float over, plus
#                     fake claude-*/misc-* sessions.
#
# Mouse gestures are exercised for real, by writing SGR mouse reports into the
# outer pane with `send-keys -H`; tmux parses them exactly as it would from a
# terminal.
#
# External tools (fzf, claude, fastfetch, zoxide, fd, eza) are stubbed by putting
# a directory first on the PATH the server under test is started with, so the
# production code path — including the picker — runs unmodified.
#
# Usage: tests/float_test.sh [-v]
set -uo pipefail

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "$HERE/.." && pwd -P)"
FLOAT="$ROOT/scripts/float.sh"
FRAGMENT="$ROOT/scripts/float.tmux"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/float-test.XXXXXX")"
STUBS="$TMPROOT/stubs"
PICKFILE="$TMPROOT/pick"
DIR_A="$TMPROOT/projA"
DIR_B="$TMPROOT/projB"

OUTER_SOCKET=float-test-outer
INNER_SOCKET=float-test

OT() { command tmux -L "$OUTER_SOCKET" "$@"; }
FT() { command tmux -L "$INNER_SOCKET" "$@"; }

PASS=0; FAIL=0; FAILED_NAMES=()

# ---------------------------------------------------------------------------
# harness
# ---------------------------------------------------------------------------

note() { [ "$VERBOSE" = 1 ] && printf '      %s\n' "$*" || true; }

ok()   { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  \033[31m✗\033[0m %s\n      %s\n' "$1" "$2"; }

check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi
}

check_near() { # <name> <expected> <actual> <tolerance>
  local d=$(( $3 - $2 )); [ "$d" -lt 0 ] && d=$(( -d ))
  if [ "$d" -le "$4" ]; then ok "$1"; else bad "$1" "expected ~$2 (±$4), got $3"; fi
}

# wait_until <deciseconds> <command...> — poll until the command succeeds.
wait_until() {
  local n=$1; shift
  local i
  for (( i = 0; i < n; i++ )); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 0.1
  done
  return 1
}

cleanup() {
  OT kill-server 2>/dev/null
  FT kill-server 2>/dev/null
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

make_stubs() {
  mkdir -p "$STUBS" "$DIR_A" "$DIR_B"
  # fzf: pick the line whose path field matches $PICKFILE's contents; an empty
  # PICKFILE means the user pressed Esc.
  cat > "$STUBS/fzf" <<EOF
#!/usr/bin/env bash
want=\$(cat "$PICKFILE" 2>/dev/null)
[ -n "\$want" ] || exit 130
awk -F'\t' -v w="\$want" '\$2 == w { print; found=1; exit } END { exit !found }'
EOF
  printf '#!/bin/sh\nexec sleep 3600\n'                    > "$STUBS/claude"
  printf '#!/bin/sh\nexit 0\n'                             > "$STUBS/fastfetch"
  printf '#!/bin/sh\n[ "$1" = query ] && printf "%%s\\n%%s\\n" "%s" "%s"\nexit 0\n' \
      "$DIR_A" "$DIR_B"                                    > "$STUBS/zoxide"
  printf '#!/bin/sh\nexit 0\n'                             > "$STUBS/fd"
  printf '#!/bin/sh\nexit 0\n'                             > "$STUBS/eza"
  chmod +x "$STUBS"/*
}

# A float session name, computed the way float.sh computes it.
sname() { "$FLOAT" name "$1" "$2"; }

# --- state accessors on the server under test ------------------------------
fopt()        { FT show -gqv "$1" 2>/dev/null; }
float_client(){ fopt @float-client; }
client_size() { FT list-clients -F '#{client_name} #{client_width} #{client_height}' 2>/dev/null \
                  | awk -v n="$1" '$1 == n { print $2, $3; exit }'; }
host_size()   { client_size "$HOST"; }
# The popup box is the inner client plus the border we always draw.
box_size()    { local w h; read -r w h <<<"$(client_size "$(float_client)")" || return 1
                [ -n "${w:-}" ] || return 1; printf '%s %s\n' "$((w+2))" "$((h+2))"; }
float_is_open(){ local c; c=$(float_client); [ -n "$c" ] && \
                 FT list-clients -F '#{client_name}' 2>/dev/null | grep -qxF "$c"; }
float_closed() { ! float_is_open; }
float_session(){ FT list-clients -F '#{client_name} #{session_name}' 2>/dev/null \
                  | awk -v n="$(float_client)" '$1 == n { print $2; exit }'; }
float_on()     { [ "$(float_session)" = "$1" ]; }
# The popup's title as actually rendered: the outer pane is the host client's
# terminal, so a capture of it includes the popup tmux drew on top. The top
# border row is the one carrying the rounded top-left corner.
float_title()  { OT capture-pane -t o.0 -p 2>/dev/null \
                  | grep -m1 '╭' | grep -o 'CLAUDE\|MISC-SHELL' | head -1; }
float_titled() { [ "$(float_title)" = "$1" ]; }

# Fire the ^A/^S code path the way the key binding does.
press() { # <kind>
  FT run-shell -b "$FLOAT key $1 $HOST"
}

# Write an SGR mouse report into the host client's terminal.
mouse() { # <button-code> <col-1based> <row-1based> <M|m>
  local seq hex=() i c
  seq=$(printf '\033[<%d;%d;%d%s' "$1" "$2" "$3" "$4")
  for (( i = 0; i < ${#seq}; i++ )); do printf -v c '%02x' "'${seq:i:1}"; hex+=("$c"); done
  OT send-keys -t o.0 -H "${hex[@]}"
}

# ⌥ + right-drag from (x1,y1) to (x2,y2): tmux's popup resize gesture.
meta_right_drag() { # <x1> <y1> <x2> <y2>
  mouse 10 "$1" "$2" M; sleep 0.15
  mouse 42 "$(( $1 - 1 ))" "$2" M; sleep 0.15
  mouse 42 "$3" "$4" M; sleep 0.15
  mouse 10 "$3" "$4" m; sleep 0.4
}

start_servers() { # <host_w> <host_h>
  OT kill-server 2>/dev/null; FT kill-server 2>/dev/null; sleep 0.3

  # Server under test. The stub PATH is inherited by popups and hook children.
  env PATH="$STUBS:$PATH" tmux -L "$INNER_SOCKET" -f /dev/null \
    new-session -d -s work -x 80 -y 24 'sleep 3600'
  FT set -g prefix ^A                    # mirrors the real tmux.conf
  FT set -g mouse on
  FT set -g status off
  FT set -g detach-on-destroy off        # mirrors the real tmux.conf
  FT source-file "$FRAGMENT"

  # Outer server: the controllable "terminal" the float lives in.
  OT -f /dev/null new-session -d -s o -x "$1" -y "$2" \
    "exec tmux -L $INNER_SOCKET attach -t work"
  OT set -g status off
  OT set -g window-size manual
  OT resize-window -t o -x "$1" -y "$2"
  wait_until 30 test -n "$(FT list-clients -F '#{client_name}' 2>/dev/null)"
  sleep 0.4
  HOST=$(FT list-clients -F '#{client_name}' | head -1)
}

resize_host() { # <w> <h>
  OT resize-window -t o -x "$1" -y "$2"
  sleep 0.6   # client-resized -> debounce -> rebuild
}

fake_float_session() { # <name>
  FT has-session -t "=$1" 2>/dev/null && return 0
  FT new-session -d -s "$1" -x 80 -y 24 'sleep 3600'
  FT set-option -t "=$1:" status off
}

# ---------------------------------------------------------------------------
# tests
# ---------------------------------------------------------------------------

test_geom_unit() {
  printf '\n\033[1mgeometry (pure)\033[0m\n'
  check "92%/85% of 164x40"          "151 34" "$("$FLOAT" geom 164 40 920 850)"
  check "92%/85% of 100x24"          "92 20"  "$("$FLOAT" geom 100 24 920 850)"
  check "92%/85% of 220x60"          "202 51" "$("$FLOAT" geom 220 60 920 850)"
  check "never exceeds a tiny host"  "10 4"   "$("$FLOAT" geom 10 4 920 850)"
  check "honours a custom ratio"     "82 20"  "$("$FLOAT" geom 164 40 500 500)"
}

test_classify_unit() {
  printf '\n\033[1mresize classification (pure)\033[0m\n'
  check "size we asked for is ours"     auto   "$("$FLOAT" classify 150 34 150 34 164 40)"
  check "tmux clamping is not manual"   auto   "$("$FLOAT" classify 100 24 150 34 100 24)"
  check "anything else is the user"     manual "$("$FLOAT" classify 132 26 150 34 164 40)"
  check "partial clamp is not manual"   auto   "$("$FLOAT" classify 100 34 150 34 100 40)"
}

test_open_and_pick() {
  printf '\n\033[1mopening the float\033[0m\n'
  start_servers 164 40
  printf '%s' "$DIR_A" > "$PICKFILE"
  press claude
  if ! wait_until 50 float_is_open; then bad "float opens on ^A" "no popup client appeared"; return; fi
  ok "float opens on ^A"

  local want got
  want=$("$FLOAT" geom 164 40 920 850)
  got=$(box_size)
  check "float is 92%x85% of the host" "$want" "$got"
  check "float shows the picked session" "$(sname claude "$DIR_A")" "$(float_session)"
  check "float is labelled CLAUDE"       "CLAUDE"  "$(float_title)"
  check "host client is recorded"        "$HOST" "$(fopt @float-host)"
  check "kind is recorded"               "claude" "$(fopt @float-kind)"
}

test_resize_host() {
  printf '\n\033[1mre-proportioning on terminal resize / font zoom\033[0m\n'
  # Zoom in: fewer cells. tmux on its own would clamp the float to the full
  # screen (no margin at all); we want it to stay at 92%x85%.
  resize_host 100 24
  if ! wait_until 40 float_is_open; then bad "float survives a shrink" "popup gone"; return; fi
  check "shrink keeps the proportion" "$("$FLOAT" geom 100 24 920 850)" "$(box_size)"

  # Zoom out: more cells. tmux on its own would leave the float at its old
  # absolute size (a small box in a big terminal).
  resize_host 220 60
  check "grow keeps the proportion"   "$("$FLOAT" geom 220 60 920 850)" "$(box_size)"

  resize_host 164 40
  check "back to the original size"   "$("$FLOAT" geom 164 40 920 850)" "$(box_size)"
  check "still the same session"      "$(sname claude "$DIR_A")" "$(float_session)"
}

test_mouse_resize() {
  printf '\n\033[1mmouse resize, and whether it survives a zoom\033[0m\n'
  local before after pw ph hw hh bw bh
  before=$(box_size)
  # ⌥ + right-drag inside the float; the pointer becomes the bottom-right corner.
  meta_right_drag 100 30 120 34
  after=$(box_size)
  if [ "$before" = "$after" ]; then
    bad "⌥+right-drag resizes the float" "box unchanged at $before"
    return
  fi
  ok "⌥+right-drag resizes the float"

  read -r bw bh <<<"$after"
  read -r hw hh <<<"$(host_size)"
  pw=$(fopt @float-pw); ph=$(fopt @float-ph)
  check "new width is remembered as a proportion"  "$(( bw * 1000 / hw ))" "$pw"
  check "new height is remembered as a proportion" "$(( bh * 1000 / hh ))" "$ph"

  # ...and the manual size must survive a zoom.
  resize_host 200 50
  check "manual proportion survives a zoom" "$("$FLOAT" geom 200 50 "$pw" "$ph")" "$(box_size)"
  resize_host 164 40
}

test_hop_on_exit() {
  printf '\n\033[1monly float sessions are ever displayed\033[0m\n'
  local a b
  a=$(sname claude "$DIR_A")
  b=$(sname misc "$DIR_B")
  fake_float_session "$b"
  sleep 0.3

  # Killing the session in the float must hand the float to the most recently
  # used remaining float session — never to `work`.
  FT kill-session -t "=$a"
  if ! wait_until 40 float_on "$b"; then
    bad "float hops to the next float session" "landed on [$(float_session)] instead of [$b]"
  else
    ok "float hops to the next float session"
  fi
  check "float never shows a normal session" "1" "$( [ "$(float_session)" != work ] && echo 1 || echo 0 )"

  # The popup was opened as CLAUDE; it is now showing a misc-shell session, so
  # its title and border must have followed the session across.
  wait_until 30 float_titled MISC-SHELL
  check "label follows the hop to misc" "MISC-SHELL" "$(float_title)"
  check "remembered kind follows too"   "misc"       "$(fopt @float-kind)"

  # ...and a rebuild (terminal resize) must not put the old label back.
  resize_host 150 36
  check "label survives a resize rebuild" "MISC-SHELL" "$(float_title)"
  resize_host 164 40
}

test_close_when_empty() {
  local b; b=$(sname misc "$DIR_B")
  FT kill-session -t "=$b"
  if wait_until 40 float_closed; then ok "float closes when no float sessions remain"
  else bad "float closes when no float sessions remain" "still open on [$(float_session)]"; fi
}

test_guard_rejects_normal_session() {
  printf '\n\033[1mguard: a stray switch-client is corrected\033[0m\n'
  local a b fc
  a=$(sname claude "$DIR_A"); b=$(sname misc "$DIR_B")
  fake_float_session "$a"; fake_float_session "$b"
  printf '%s' "$DIR_A" > "$PICKFILE"
  press claude
  if ! wait_until 50 float_is_open; then bad "float reopens" "no popup"; return; fi
  wait_until 30 float_on "$a"

  # Force the float onto a normal session behind the supervisor's back.
  fc=$(float_client)
  FT switch-client -c "$fc" -t "=work"
  sleep 0.8
  if [ "$(float_session)" = work ]; then
    bad "guard pulls the float off a normal session" "still on work"
  else
    ok "guard pulls the float off a normal session"
  fi
  check "guard lands on a float session" "1" \
    "$( printf '%s\n' "$(float_session)" | grep -qE '^(claude|misc)-' && echo 1 || echo 0 )"
}

test_closes_after_guard_when_empty() {
  FT kill-session -t "=$(sname claude "$DIR_A")" 2>/dev/null
  FT kill-session -t "=$(sname misc "$DIR_B")" 2>/dev/null
  sleep 0.5
  if wait_until 40 float_closed; then ok "float closes once its last session is killed"
  else bad "float closes once its last session is killed" "open on [$(float_session)]"; fi
}

test_deliberate_detach_closes() {
  printf '\n\033[1mdeliberate detach closes the float (does not hop)\033[0m\n'
  local a b fc
  a=$(sname claude "$DIR_A"); b=$(sname misc "$DIR_B")
  fake_float_session "$a"; fake_float_session "$b"
  printf '%s' "$DIR_A" > "$PICKFILE"
  press claude
  if ! wait_until 50 float_is_open; then bad "float reopens" "no popup"; return; fi
  wait_until 30 float_on "$a"

  fc=$(float_client)
  FT detach-client -t "$fc"
  if wait_until 40 float_closed; then ok "detaching closes the float"
  else bad "detaching closes the float" "hopped to [$(float_session)] instead"; fi
}

test_no_nesting() {
  printf '\n\033[1manti-nesting\033[0m\n'
  local a before
  a=$(sname claude "$DIR_A")
  printf '%s' "$DIR_A" > "$PICKFILE"
  press claude
  if ! wait_until 50 float_is_open; then bad "float reopens" "no popup"; return; fi
  wait_until 30 float_on "$a"
  before=$(float_client)

  # Press ^S from *inside* the float: it must retarget this popup through the
  # misc picker, not stack a second popup on top.
  printf '%s' "$DIR_B" > "$PICKFILE"
  FT run-shell -b "$FLOAT key misc $before"
  wait_until 40 float_on "$(sname misc "$DIR_B")"
  check "no second popup client"  "2" "$(FT list-clients -F x | wc -l | tr -d ' ')"
  check "same popup client reused" "$before" "$(float_client)"
  check "retargeted at the misc session" "$(sname misc "$DIR_B")" "$(float_session)"
  wait_until 30 float_titled MISC-SHELL
  check "label follows the retarget"     "MISC-SHELL" "$(float_title)"
}

test_label_returns() {
  printf '\n\033[1mlabel changes back\033[0m\n'
  local a; a=$(sname claude "$DIR_A")
  fake_float_session "$a"
  FT kill-session -t "=$(sname misc "$DIR_B")" 2>/dev/null
  if ! wait_until 40 float_on "$a"; then
    bad "float hops back to a claude session" "on [$(float_session)]"; return
  fi
  ok "float hops back to a claude session"
  wait_until 30 float_titled CLAUDE
  check "label changes back to CLAUDE" "CLAUDE" "$(float_title)"
  check "remembered kind changes back" "claude" "$(fopt @float-kind)"
}

test_real_keybinding() {
  printf '\n\033[1mthe real ^A binding\033[0m\n'
  FT kill-session -t misc-picker 2>/dev/null
  FT display-popup -C -c "$HOST" 2>/dev/null
  wait_until 30 float_closed
  printf '%s' "$DIR_B" > "$PICKFILE"
  # prefix (^A) then ^A, injected as real key input to the host client.
  OT send-keys -t o.0 C-a C-a
  if wait_until 60 float_is_open; then ok "^A ^A opens the float"
  else bad "^A ^A opens the float" "no popup appeared"; fi
  check "opens on the picked dir" "$(sname claude "$DIR_B")" "$(float_session)"
}

# ---------------------------------------------------------------------------

printf '\033[1mfloat.sh test suite\033[0m  (tmux %s)\n' "$(tmux -V | cut -d' ' -f2)"
make_stubs
test_geom_unit
test_classify_unit
test_open_and_pick
test_resize_host
test_mouse_resize
test_hop_on_exit
test_close_when_empty
test_guard_rejects_normal_session
test_closes_after_guard_when_empty
test_deliberate_detach_closes
test_no_nesting
test_label_returns
test_real_keybinding

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'failed:\n'; printf '  - %s\n' "${FAILED_NAMES[@]}"
  exit 1
fi
