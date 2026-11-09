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
  # PICKFILE means the user pressed Esc, and @wait means they are still choosing
  # (the picker stays up until something kills it).
  cat > "$STUBS/fzf" <<EOF
#!/usr/bin/env bash
want=\$(cat "$PICKFILE" 2>/dev/null)
[ "\$want" = @wait ] && exec sleep 3600
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
picker_gone()  { ! FT has-session -t "=$1" 2>/dev/null; }

# Everything run-shell has reported since the last call. When a `run-shell -b`
# command (our key bindings, our hooks) exits non-zero, tmux prints
# "'<command>' returned <n>" into view mode on whichever pane it considers
# current — in real use, usually the one on show in the float, which is then
# hidden until a key is pressed. A rebuild can scroll that line out of sight and
# leave what looks like a blank screen, so any pane in view mode counts, and the
# capture includes history. Each pane is dismissed so the next call starts clean.
shell_errors() {
  local p
  for p in $(FT list-panes -a -F '#{pane_id} #{pane_mode}' 2>/dev/null | awk '$2 == "view-mode" { print $1 }'); do
    printf '%s: %s\n' "$p" "$(FT capture-pane -M -p -S - -t "$p" 2>/dev/null | awk 'NF' | tr '\n' ' ')"
    FT copy-mode -q -t "$p" 2>/dev/null
  done
}

check_no_shell_errors() { # <name>
  local e
  sleep 0.3   # let any job that just finished get its report in
  e=$(shell_errors)
  if [ -z "$e" ]; then ok "$1"; else bad "$1" "$e"; fi
}

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

# The float is up, registered, and the size its remembered proportion gives for
# a <w>x<h> host — i.e. any rebuild has finished.
float_settled() { # <host_w> <host_h>
  [ "$(box_size)" = "$("$FLOAT" geom "$1" "$2" "$(fopt @float-pw)" "$(fopt @float-ph)")" ]
}

resize_host() { # <w> <h>
  OT resize-window -t o -x "$1" -y "$2"
  # client-resized -> debounce -> rebuild. Wait for the float to come back at the
  # size its remembered proportion gives (the checks then say whether that
  # proportion is right) rather than guessing how long a rebuild takes: a fixed
  # 0.6s sleep was about the median rebuild time, which made the suite flaky.
  sleep 0.2
  wait_until 40 float_settled "$1" "$2"
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
  # Each rebuild closes the popup that a ^A (or the previous rebuild) is still
  # blocked on; that must not surface as an error over the float.
  check_no_shell_errors "rebuilding reports no errors"
}

test_resize_burst() {
  printf '\n\033[1ma burst of resizes leaves the proportion alone\033[0m\n'
  # Each resize lands as soon as the previous rebuild is up, while the hooks it
  # set off are still running — what holding cmd-+ or dragging the window edge
  # does. tmux clamping the float in the middle of that must never be taken for
  # a mouse resize and remembered as the new proportion.
  local pw ph i sz
  pw=$(fopt @float-pw); ph=$(fopt @float-ph)
  for i in 1 2 3; do
    for sz in "100 24" "220 60" "164 40"; do
      OT resize-window -t o -x "${sz% *}" -y "${sz#* }"
      wait_until 40 float_settled "${sz% *}" "${sz#* }"
    done
  done
  check "proportion survives a burst of resizes" "$pw $ph" "$(fopt @float-pw) $(fopt @float-ph)"
  check "float ends the burst the right size" "$("$FLOAT" geom 164 40 "$pw" "$ph")" "$(box_size)"
  check_no_shell_errors "a burst of resizes reports no errors"
}

test_resize_drag() {
  printf '\n\033[1mdragging the window edge\033[0m\n'
  # A stream of small steps with no pause for a rebuild. The float's own size
  # lags the host's, so every clamp looks like a mouse resize unless we know the
  # host moved; and a rebuild can land mid-drag, measure the host, and have the
  # popup refused as too large once the host has shrunk again — which used to
  # leave no float at all.
  local pw ph run sz ok_all=1
  pw=$(fopt @float-pw); ph=$(fopt @float-ph)
  for run in 1 2 3; do
    for sz in "158 39" "152 37" "146 36" "140 34" "134 33" "128 31" "122 30" "116 28" "110 27" "104 25" "100 24"; do
      OT resize-window -t o -x "${sz% *}" -y "${sz#* }"; sleep 0.03
    done
    wait_until 40 float_settled 100 24 || ok_all=0
    for sz in "104 25" "110 27" "116 28" "122 30" "128 31" "134 33" "140 34" "146 36" "152 37" "158 39" "164 40"; do
      OT resize-window -t o -x "${sz% *}" -y "${sz#* }"; sleep 0.03
    done
    wait_until 40 float_settled 164 40 || ok_all=0
  done
  check "float survives dragging the edge in and out" 1 "$ok_all"
  check "dragging keeps the proportion" "$pw $ph" "$(fopt @float-pw) $(fopt @float-ph)"
  check_no_shell_errors "dragging reports no errors"
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
  check_no_shell_errors "mouse resize + zoom report no errors"
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
  check_no_shell_errors "hopping + rebuilding report no errors"
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
  check_no_shell_errors "retargeting reports no errors"
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
  # Same as Close on the border menu: the ^A that opened this popup is still
  # blocked on it, and must not report its closing as an error.
  FT display-popup -C -c "$HOST" 2>/dev/null
  wait_until 30 float_closed
  check_no_shell_errors "closing the float from outside reports no error"
  printf '%s' "$DIR_B" > "$PICKFILE"
  # prefix (^A) then ^A, injected as real key input to the host client.
  OT send-keys -t o.0 C-a C-a
  if wait_until 60 float_is_open; then ok "^A ^A opens the float"
  else bad "^A ^A opens the float" "no popup appeared"; fi
  check "opens on the picked dir" "$(sname claude "$DIR_B")" "$(float_session)"
}

test_key_inside_float() {
  printf '\n\033[1m^A inside the float\033[0m\n'
  local fc; fc=$(float_client)
  # Bring the picker up and leave it up, as if still choosing.
  printf '@wait' > "$PICKFILE"
  OT send-keys -t o.0 C-a C-a   # keys go to the popup, i.e. to the float client
  if ! wait_until 40 float_on claude-picker; then
    bad "^A ^A in the float brings up the picker" "on [$(float_session)]"; return
  fi
  ok "^A ^A in the float brings up the picker"

  OT send-keys -t o.0 C-a C-a
  sleep 0.6
  check "^A ^A again leaves the picker up" "claude-picker" "$(float_session)"
  check "...in the same float"             "$fc" "$(float_client)"
  check_no_shell_errors "^A ^A on the open picker reports no error"
}

# The reported bug: a float closed while its picker was up leaves the picker
# session behind, and from then on every ^A ^A inside the float failed with
# "'float.sh key claude …' returned 1".
test_key_past_leftover_picker() {
  printf '\n\033[1m^A inside the float, with a picker left over\033[0m\n'
  local a b
  a=$(sname claude "$DIR_A"); b=$(sname claude "$DIR_B")
  FT detach-client -t "$(float_client)"   # close the float with the picker up
  wait_until 40 float_closed
  # Make sure there is a leftover even if closing ever learns to clean it up.
  FT has-session -t =claude-picker 2>/dev/null ||
    FT new-session -d -s claude-picker 'sleep 3600'

  printf '%s' "$DIR_A" > "$PICKFILE"
  press claude
  if ! wait_until 50 float_on "$a"; then bad "float reopens" "on [$(float_session)]"; return; fi

  printf '%s' "$DIR_B" > "$PICKFILE"
  OT send-keys -t o.0 C-a C-a
  if wait_until 50 float_on "$b"; then ok "^A ^A in the float gets past a leftover picker"
  else bad "^A ^A in the float gets past a leftover picker" "still on [$(float_session)]"; fi
  check_no_shell_errors "...and reports no error"
  wait_until 30 picker_gone claude-picker
  check "no picker left behind once one is used" 1 "$(picker_gone claude-picker && echo 1 || echo 0)"
}

# ---------------------------------------------------------------------------

printf '\033[1mfloat.sh test suite\033[0m  (tmux %s)\n' "$(tmux -V | cut -d' ' -f2)"
make_stubs
test_geom_unit
test_classify_unit
test_open_and_pick
test_resize_host
test_resize_burst
test_resize_drag
test_mouse_resize
test_hop_on_exit
test_close_when_empty
test_guard_rejects_normal_session
test_closes_after_guard_when_empty
test_deliberate_detach_closes
test_no_nesting
test_label_returns
test_real_keybinding
test_key_inside_float
test_key_past_leftover_picker

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'failed:\n'; printf '  - %s\n' "${FAILED_NAMES[@]}"
  exit 1
fi
