#!/usr/bin/env bash
# float.sh — the persistent floating window for Claude (^A) and misc shells (^S).
#
# The floating window is a tmux popup whose command is a *supervisor loop*: the
# popup itself is a disposable viewport, the thing you are looking at is always a
# persistent, per-directory tmux session (claude-<slug> or misc-<slug>). Because
# the content lives in a session and not in the popup, the popup can be closed and
# rebuilt at any moment without losing anything — that is what makes resizing on
# terminal zoom possible, and what lets the viewport hop to another session when
# the one it is showing exits.
#
# Three invariants this script maintains:
#   1. The float is resizable/movable with the mouse (tmux 3.7 does this natively;
#      see GESTURES below) and a manual resize is remembered as a proportion.
#   2. The float keeps that proportion when the host terminal is resized or the
#      font is zoomed (tmux only clamps popups, it never re-proportions them).
#   3. Only claude-* / misc-* sessions are ever displayed in the float. When the
#      session in the float exits, the float hops to the most recently used
#      remaining float session, or closes if there are none.
#
# GESTURES (native tmux 3.7 popup handling, requires `mouse on`):
#   ⌥ + drag             move the float   ⌥ alone, not ⌥⇧/⌥⌃ — this is the
#   ⌥ + right-drag       resize it        reliable pair; the pointer becomes the
#                                         bottom-right corner when resizing
#   drag a border        also moves it. Right-dragging the right/bottom border
#                        also resizes, but only reliably inwards, and not at all
#                        while the app inside is in all-motion mouse mode — so
#                        prefer ⌥.
#   right-click a border popup menu (Close / Fill Space / Centre / To pane)
#
# STATE (global tmux user options; `tmux show -g | grep @float` to inspect):
#   @float-client    client name of the nested client inside the popup.
#                    THE float-is-open PREDICATE: open iff this names a live client.
#   @float-instance  unique token for the current popup command, so a dying popup
#                    never clears state belonging to the popup that replaced it.
#   @float-host      client name of the client the popup is drawn on.
#   @float-kind      claude | misc — the kind of the session on show, which is
#                    not necessarily the kind the float was opened with.
#   @float-session   session currently displayed in the float.
#   @float-pw/-ph    wanted size as a permille of the host client (920 = 92.0%).
#   @float-want-w/-h popup box size in cells we last asked for, used to tell our
#                    own resizes apart from a manual mouse resize.
#   @float-serial    debounce token for coalescing bursts of resize events.
#
# Subcommands: key | run | pick | resized | guard | name | geom | classify | __list | __kill
set -eu

self="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"

# Roots to scan for projects in addition to zoxide's frecent list.
ROOTS=("$HOME/Code" "$HOME")

# Session-name prefixes that are allowed in the float. Single source of truth:
# everything else (the regex, the "is this a float session" test) derives from it.
FLOAT_PREFIXES=(claude- misc-)

DEFAULT_PW=920   # 92.0% of the host client's width
DEFAULT_PH=850   # 85.0% of the host client's height
MIN_W=24         # never build a popup box smaller than this (cells)
MIN_H=8
DEBOUNCE=0.12    # seconds to coalesce a burst of resize events

# ---------------------------------------------------------------------------
# tmux plumbing
# ---------------------------------------------------------------------------

# Always talk to the server that invoked us, never to whatever `tmux` would pick.
# $TMUX is "<socket>,<pid>,<session>" and is set for popups, run-shell children
# and session panes alike, so this works in production and under the test harness
# (which drives a private server) with no extra plumbing.
if [ -n "${TMUX:-}" ]; then
  _tmux_args=(-S "${TMUX%%,*}")
else
  _tmux_args=()
fi
tm() { command tmux "${_tmux_args[@]}" "$@"; }

opt()   { tm show -gqv "$1" 2>/dev/null || true; }
setopt_() { tm set -g "$1" "$2" 2>/dev/null || true; }
unsetopt_() { tm set -gu "$1" 2>/dev/null || true; }

client_exists() {
  [ -n "${1:-}" ] || return 1
  tm list-clients -F '#{client_name}' 2>/dev/null | grep -qxF "$1"
}

# Echo "<width> <height>" for a client, or nothing if it is gone.
client_size() {
  [ -n "${1:-}" ] || return 0
  tm list-clients -F '#{client_name} #{client_width} #{client_height}' 2>/dev/null \
    | awk -v n="$1" '$1 == n { print $2, $3; exit }'
}

float_open() { client_exists "$(opt @float-client)"; }

# Per-kind identity. Sets: prefix accent label prompt header winname runcmd
kind_config() {
  case "${1:-}" in
    claude)
      prefix=claude-; accent='#d27e99'; label=' CLAUDE '
      prompt='claude dir> '; header='󱘖 live session  ·  ⌥drag move  ⌥right-drag resize'
      winname=claude; runcmd='claude' ;;
    misc)
      prefix=misc-; accent='#7e9cd8'; label=' MISC-SHELL '
      prompt='shell dir> '; header='󱘖 live shell  ·  ⌥drag move  ⌥right-drag resize'
      winname=shell; runcmd='fastfetch; exec zsh' ;;
    *)
      printf 'float.sh: unknown kind: %s\n' "${1:-}" >&2; exit 2 ;;
  esac
}

# Session name from the FULL path so dirs sharing their last components don't
# collide, e.g. /Users/you/Code/open_ims -> claude-_Users_you_Code_open_ims.
# Must match the awk slug logic in emit_list (same character class).
session_name_for() { printf '%s%s' "$1" "$(printf '%s' "$2" | tr -c '[:alnum:]_-' '_')"; }

float_session_regex() {
  local p out=
  for p in "${FLOAT_PREFIXES[@]}"; do out="${out}${out:+|}${p%-}"; done
  printf '^(%s)-' "$out"
}

is_float_session() {
  [ -n "${1:-}" ] || return 1
  printf '%s\n' "$1" | grep -qE "$(float_session_regex)"
}

# Which kind a session belongs to, from its name: claude-foo -> claude. The kind
# names and the prefixes are the same list, so this stays in step with
# FLOAT_PREFIXES. Fails for anything that is not a float session.
kind_of_session() {
  local p
  for p in "${FLOAT_PREFIXES[@]}"; do
    case "${1:-}" in "$p"*) printf '%s\n' "${p%-}"; return 0 ;; esac
  done
  return 1
}

# Most recently attached float session, excluding the throwaway *-picker sessions
# and (optionally) one name. Empty when there is nothing left to show.
latest_float_session() {
  local exclude="${1:-}"
  tm list-sessions -F '#{session_last_attached} #{session_name}' 2>/dev/null \
    | sort -rn -k1,1 \
    | cut -d' ' -f2- \
    | grep -E "$(float_session_regex)" \
    | grep -vE -- '-picker$' \
    | { if [ -n "$exclude" ]; then grep -vxF "$exclude"; else cat; fi; } \
    | head -1
}

# Create the per-directory session if needed, then make sure it is configured the
# way the float needs it. Both option writes are idempotent, so sessions created
# before this script existed get fixed up the first time they are shown.
#
# detach-on-destroy=on is the load-bearing one: with the global `off`, tmux would
# silently move the popup's client onto some unrelated session when this one dies.
# `on` makes the client exit instead, which hands control back to the supervisor
# loop in cmd_run so it can decide what to show next.
ensure_session() {
  local kind=$1 name=$2 dir=${3:-}
  kind_config "$kind"
  if ! tm has-session -t "=$name" 2>/dev/null; then
    [ -n "$dir" ] || return 1
    tm new-session -d -s "$name" -c "$dir" -n "$winname" "$runcmd"
  fi
  tm set-option -t "=$name:" status off 2>/dev/null || true
  tm set-option -t "=$name:" detach-on-destroy on 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Geometry — pure functions, unit-tested by tests/float_test.sh
# ---------------------------------------------------------------------------

# geom <host_w> <host_h> <permille_w> <permille_h> -> "<box_w> <box_h>"
# The box includes the border, which is what display-popup -w/-h take.
cmd_geom() {
  local hw=$1 hh=$2 pw=$3 ph=$4 w h
  w=$(( (hw * pw + 500) / 1000 ))
  h=$(( (hh * ph + 500) / 1000 ))
  if [ "$w" -lt "$MIN_W" ]; then w=$MIN_W; fi
  if [ "$h" -lt "$MIN_H" ]; then h=$MIN_H; fi
  if [ "$w" -gt "$hw" ]; then w=$hw; fi
  if [ "$h" -gt "$hh" ]; then h=$hh; fi
  printf '%s %s\n' "$w" "$h"
}

# classify <obs_w> <obs_h> <want_w> <want_h> <host_w> <host_h> -> auto | manual
#
# The popup's inner client resizes for two different reasons and we must react to
# only one of them. Either we asked for the size (want), or tmux clamped our size
# to fit a client that just got smaller (min(want, host) — see popup_resize_cb in
# tmux's popup.c, which only ever clamps). Anything else is the user dragging the
# border, and that becomes the new remembered proportion.
cmd_classify() {
  local ow=$1 oh=$2 ww=$3 wh=$4 hw=$5 hh=$6 cw ch
  cw=$(( ww < hw ? ww : hw ))
  ch=$(( wh < hh ? wh : hh ))
  if { [ "$ow" -eq "$ww" ] && [ "$oh" -eq "$wh" ]; } ||
     { [ "$ow" -eq "$cw" ] && [ "$oh" -eq "$ch" ]; }; then
    printf 'auto\n'
  else
    printf 'manual\n'
  fi
}

# ---------------------------------------------------------------------------
# Opening / rebuilding the popup
# ---------------------------------------------------------------------------

# Draw the popup on $client at the size implied by the remembered proportion,
# running the supervisor loop for $kind on $sess ("" = start with the picker).
open_popup() {
  local kind=$1 client=$2 sess=${3:-}
  kind_config "$kind"

  local hw hh pw ph bw bh
  read -r hw hh <<<"$(client_size "$client")" || true
  [ -n "${hw:-}" ] || return 1
  pw=$(opt @float-pw); ph=$(opt @float-ph)
  [ -n "$pw" ] || pw=$DEFAULT_PW
  [ -n "$ph" ] || ph=$DEFAULT_PH
  read -r bw bh <<<"$(cmd_geom "$hw" "$hh" "$pw" "$ph")" || true

  # popup_display refuses a box smaller than 3x3 (silently — cmd-display-menu.c
  # turns the failure into a no-op), so never ask for one.
  if [ "$bw" -lt 3 ] || [ "$bh" -lt 3 ]; then return 1; fi

  # If any popup is already on this client, display-popup would take tmux's
  # "modify the existing popup" path — which ignores -w/-h and returns at once,
  # leaving us with the wrong popup and no supervisor. Start from a clean slate.
  tm display-popup -C -c "$client" 2>/dev/null || true

  setopt_ @float-host "$client"
  setopt_ @float-kind "$kind"
  setopt_ @float-pw "$pw"
  setopt_ @float-ph "$ph"
  setopt_ @float-want-w "$bw"
  setopt_ @float-want-h "$bh"

  # Blocks until the popup closes, which is fine: we are always either a
  # run-shell -b child (key press) or a hook child (rebuild).
  tm display-popup -c "$client" -w "$bw" -h "$bh" -x C -y C \
    -b rounded -S "fg=$accent" -T "$label" \
    -E "'$self' run '$kind' '$sess'"
}

# The float is one window that shows sessions of either kind: a claude session
# can hand over to a misc-shell one when it exits, and ^S retargets a claude
# float at the misc picker. The title and border colour are baked into the popup
# at creation, so they have to be re-applied whenever the session changes, or the
# float keeps claiming to be whatever it was opened as.
#
# display-popup on a client that ALREADY has a popup takes tmux's modify path,
# which changes only the title and styles in place — no resize, no flicker, and
# the nested client is untouched. -b/-B are deliberately not passed: they are the
# one modify argument that can resize the popup on the way through.
apply_style() {
  local sess=$1 kind host
  kind=$(kind_of_session "$sess") || return 0
  host=$(opt @float-host)
  [ -n "$host" ] || return 0
  float_open || return 0                 # no popup to modify; do not create one
  kind_config "$kind"

  # Remembered so a rebuild (on terminal resize) recreates the popup wearing the
  # colours of the session it is showing, not the one it was opened with.
  setopt_ @float-kind "$kind"
  # `-E true` is belt and braces: if the popup vanished between the check above
  # and this command, tmux would create one instead of modifying — and that one
  # exits immediately rather than lingering as a stray shell.
  tm display-popup -c "$host" -T "$label" -S "fg=$accent" -E true 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Subcommand: key — what ^A / ^S do
# ---------------------------------------------------------------------------
cmd_key() {
  local kind=$1 client=$2
  kind_config "$kind"

  if [ "$client" = "$(opt @float-client)" ] && float_open; then
    # Pressed *inside* the float: retarget this popup rather than stacking
    # another one on top. The throwaway picker session runs the same fzf and
    # switch-clients to the choice.
    local picker="${prefix}picker"
    tm new-session -d -A -s "$picker" -n "$winname" "'$self' pick '$kind' switch"
    tm set-option -t "=$picker:" status off 2>/dev/null || true
    tm set-option -t "=$picker:" detach-on-destroy on 2>/dev/null || true
    tm switch-client -c "$client" -t "=$picker"
    return 0
  fi

  # Only ever one float. If one is open on another client (a second terminal
  # window), close it there before drawing ours.
  if float_open; then
    local oldhost; oldhost=$(opt @float-host)
    if [ -n "$oldhost" ] && [ "$oldhost" != "$client" ]; then
      tm display-popup -C -c "$oldhost" 2>/dev/null || true
    fi
  fi
  open_popup "$kind" "$client" ""
}

# ---------------------------------------------------------------------------
# Subcommand: run — the supervisor loop, i.e. the popup's command
# ---------------------------------------------------------------------------
float_cleanup() {
  # Only the instance that currently owns the float may clear the float-is-open
  # state. During a rebuild the outgoing popup can take longer to wind down than
  # the incoming one takes to register, and tmux reuses pty names, so comparing
  # ttys is not enough to tell "me" from "the popup that replaced me".
  [ "$(opt @float-instance)" = "$1" ] || return 0
  unsetopt_ @float-client
  unsetopt_ @float-instance
}

cmd_run() {
  local kind=$1 sess=${2:-}
  kind_config "$kind"

  local me instance
  me=$(tty || true)
  instance="$$-${RANDOM}-${RANDOM}"
  setopt_ @float-client "$me"
  setopt_ @float-instance "$instance"
  # shellcheck disable=SC2064 — we want $instance expanded now, not at trap time.
  trap "float_cleanup '$instance'" EXIT HUP TERM INT

  local cur next fails=0 started
  while :; do
    if [ -z "$sess" ]; then
      local dir
      dir=$(pick_dir "$kind") || dir=""
      [ -n "$dir" ] || return 0          # cancelled -> close the float
      sess=$(session_name_for "$prefix" "$dir")
      ensure_session "$kind" "$sess" "$dir" || return 0
    else
      ensure_session "$kind" "$sess" || { sess=""; continue; }
    fi

    setopt_ @float-session "$sess"
    started=$SECONDS
    tm attach-session -t "=$sess" || true

    # attach-session returned, so this client is no longer attached. Either the
    # session it was on was destroyed (detach-on-destroy on, set above), or the
    # user detached on purpose. @float-session is kept current by the guard hook,
    # so it is correct even if the picker switched us elsewhere in the meantime.
    cur=$(opt @float-session)
    if [ -n "$cur" ] && tm has-session -t "=$cur" 2>/dev/null; then
      return 0                           # deliberate detach -> close the float
    fi

    # Spin guard: a session that dies the instant we attach must not loop forever.
    if [ $(( SECONDS - started )) -lt 1 ]; then
      fails=$(( fails + 1 ))
      [ "$fails" -lt 20 ] || return 0
    else
      fails=0
    fi

    next=$(latest_float_session "$cur") || true
    [ -n "$next" ] || return 0           # nothing left to show -> close the float
    sess="$next"
  done
}

# ---------------------------------------------------------------------------
# Subcommand: guard — client-session-changed hook
# ---------------------------------------------------------------------------
# Belt and braces for invariant 3. detach-on-destroy already routes the common
# case through the supervisor loop; this catches everything else (a stray
# switch-client, a session killed before we could configure it, a restored
# session) and makes "only float sessions are ever displayed" actually hold.
cmd_guard() {
  local client=$1 sess
  [ "$client" = "$(opt @float-client)" ] || return 0

  # Look the session up rather than taking it from the hook, so a session name
  # with a space in it can't split into two arguments.
  sess=$(tm list-clients -F '#{client_name} #{session_name}' 2>/dev/null \
         | awk -v n="$client" '$1 == n { $1 = ""; sub(/^ /, ""); print; exit }')
  [ -n "$sess" ] || return 0
  setopt_ @float-session "$sess"
  apply_style "$sess"
  is_float_session "$sess" && return 0

  local next; next=$(latest_float_session "") || true
  if [ -n "$next" ]; then
    tm switch-client -c "$client" -t "=$next"
  else
    # Nothing legal to show. Detaching lets the supervisor loop see a live
    # session in @float-session, treat it as a deliberate detach and exit,
    # which closes the popup through the normal path.
    tm detach-client -t "$client" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Subcommand: resized — client-resized hook
# ---------------------------------------------------------------------------
cmd_resized() {
  local client=$1
  float_open || return 0
  if [ "$client" = "$(opt @float-client)" ]; then
    track_manual_resize
  elif [ "$client" = "$(opt @float-host)" ]; then
    rebuild_debounced
  fi
}

# The popup's inner client just changed size. If the user did it with the mouse,
# remember the new size as a proportion of the host so it survives a rebuild.
track_manual_resize() {
  local fc host hw hh iw ih bw bh
  fc=$(opt @float-client); host=$(opt @float-host)
  read -r hw hh <<<"$(client_size "$host")" || true
  read -r iw ih <<<"$(client_size "$fc")" || true
  [ -n "${hw:-}" ] && [ -n "${iw:-}" ] || return 0

  bw=$(( iw + 2 )); bh=$(( ih + 2 ))     # +2: we always draw a border
  [ "$(cmd_classify "$bw" "$bh" "$(opt @float-want-w)" "$(opt @float-want-h)" "$hw" "$hh")" = manual ] || return 0

  setopt_ @float-pw "$(( bw * 1000 / hw ))"
  setopt_ @float-ph "$(( bh * 1000 / hh ))"
  setopt_ @float-want-w "$bw"
  setopt_ @float-want-h "$bh"
}

# The host client changed size (font zoom, window resize, fullscreen). tmux only
# ever clamps an open popup — it never re-proportions one, and no command can
# resize a popup in place — so we rebuild it at the right size. The session in the
# float is untouched by this; only the viewport is replaced.
rebuild_debounced() {
  # Coalesce a burst (holding cmd-+ fires one resize per step). Each invocation
  # stakes a unique claim; only the last one standing rebuilds.
  local token="$$-${RANDOM}-${RANDOM}"
  setopt_ @float-serial "$token"
  sleep "$DEBOUNCE"
  [ "$(opt @float-serial)" = "$token" ] || return 0

  float_open || return 0
  local kind sess host fc hw hh iw ih bw bh
  kind=$(opt @float-kind); sess=$(opt @float-session); host=$(opt @float-host)
  fc=$(opt @float-client)
  [ -n "$kind" ] && [ -n "$host" ] || return 0
  client_exists "$host" || return 0

  read -r hw hh <<<"$(client_size "$host")" || true
  read -r iw ih <<<"$(client_size "$fc")" || true
  [ -n "${hw:-}" ] && [ -n "${iw:-}" ] || return 0
  read -r bw bh <<<"$(cmd_geom "$hw" "$hh" "$(opt @float-pw)" "$(opt @float-ph)")" || true

  if [ "$bw" -eq $(( iw + 2 )) ] && [ "$bh" -eq $(( ih + 2 )) ]; then
    setopt_ @float-want-w "$bw"; setopt_ @float-want-h "$bh"
    return 0                             # already the right size, no flicker
  fi
  # A box tmux would refuse to draw: keep the float we have rather than closing
  # it and failing to put anything back.
  if [ "$bw" -lt 3 ] || [ "$bh" -lt 3 ]; then return 0; fi

  open_popup "$kind" "$host" "$sess"
}

# ---------------------------------------------------------------------------
# The picker
# ---------------------------------------------------------------------------

# emit_list: build the picker list. Runs for the initial fzf load and again on
# every `reload` (after an alt-bspace / ctrl-x kill) so a killed session stops
# showing as live.
emit_list() {
  kind_config "$1"
  # Existing tmux sessions, ordered most-recently-attached first and joined with
  # the ASCII field separator (\034) so names with spaces survive. Used to flag
  # dirs that already have a live session and to order those dirs by recency.
  local sessions
  sessions=$(
    tm list-sessions -F '#{session_last_attached} #{session_name}' 2>/dev/null \
      | sort -rn -k1,1 \
      | cut -d' ' -f2- \
      | grep -vx "${prefix}picker" \
      | tr '\n' '\034' || true
  )

# Build the picker list:
#  - zoxide frecency + a shallow fd scan of ROOTS
#  - strip trailing slashes (fd adds them, zoxide doesn't) so both sources dedupe
#  - drop duplicates, preserving first-seen order
#  - compute each dir's session name; list dirs with a live session first, tagged
#    with a marker. Each line is "<marker>\t<dir>\t<session>"; fzf searches and
#    previews the path (field 2) and we recover it after selection.
  {
    _ZO_DOCTOR=0 zoxide query -l 2>/dev/null || true
    fd --type d --max-depth 1 --hidden --exclude .git . "${ROOTS[@]}" 2>/dev/null || true
  } | awk -v sessions="$sessions" -v prefix="$prefix" '
      BEGIN {
        # rank[name] = 1 for the most-recently-attached session, 2 for the next, ...
        n = split(sessions, a, "\034")
        for (j = 1; j <= n; j++) if (a[j] != "") { live[a[j]] = 1; rank[a[j]] = j }
      }
      { sub(/\/+$/, "") }                  # normalize trailing slash
      !NF || seen[$0]++ { next }           # skip blanks and duplicates
      {
        # Derive the session name from the FULL path. Using only the last two
        # components collided when two dirs shared them (e.g.
        # .../open_ims/microservices/ims/client and
        # .../open_ims_2/microservices/ims/client both became "ims-client"),
        # which showed a duplicate live entry and shared one session.
        slug = $0
        gsub(/[^[:alnum:]_-]/, "_", slug)
        sname = prefix slug
        # Emit the live session name as a hidden 3rd field so the fzf preview can
        # capture that pane; empty for dirs that have no live session.
        if (sname in live) { active[++na] = $0; arank[na] = rank[sname]; asess[na] = sname }
        else               other[++no] = $0
      }
      END {
        # Insertion-sort the live dirs by recency so the session you last opened
        # is first. Few sessions, so a simple O(n^2) pass is plenty.
        for (i = 2; i <= na; i++) {
          v = active[i]; vr = arank[i]; vs = asess[i]; k = i - 1
          while (k >= 1 && arank[k] > vr) {
            active[k+1] = active[k]; arank[k+1] = arank[k]; asess[k+1] = asess[k]; k--
          }
          active[k+1] = v; arank[k+1] = vr; asess[k+1] = vs
        }
        for (k = 1; k <= na; k++) printf "\033[32m󱘖\033[0m\t%s\t%s\n", active[k], asess[k]
        for (k = 1; k <= no; k++) printf " \t%s\t\n", other[k]
      }
    '
}

# Run fzf and echo the chosen directory (empty if cancelled).
pick_dir() {
  local kind=$1 choice
  kind_config "$kind"
  choice=$(
    emit_list "$kind" | fzf \
        --ansi \
        --delimiter '\t' \
        --with-nth 1,2 \
        --nth 2 \
        --scheme path \
        --prompt "$prompt" \
        --header "$header" \
        --height 100% \
        --layout reverse \
        --border \
        --border-label "$label" \
        --border-label-pos 3 \
        --color "border:$accent,label:$accent:reverse:bold,prompt:$accent,pointer:$accent,marker:$accent,info:$accent,spinner:$accent,header:$accent" \
        --info inline \
        --preview-window 'right,60%,border-left' \
        --bind "alt-bspace,ctrl-x:execute-silent('$self' __kill {3})+reload('$self' __list $kind)" \
        --preview '
          name={3}; dir={2}
          if [ -n "$name" ] && tmux has-session -t "=$name" 2>/dev/null; then
            tmux capture-pane -ep -t "$name"         # live session: show its screen
          else
            eza -la --color=always --icons --group-directories-first --git "$dir" 2>/dev/null | head -200
          fi'
  ) || choice=""
  printf '%s\n' "$choice" | awk -F'\t' '{print $2}'
}

# `pick <kind> switch` — the body of the throwaway *-picker session. We are
# already inside the popup, so retarget this client instead of nesting.
cmd_pick() {
  local kind=$1 mode=${2:-switch} dir sess
  kind_config "$kind"
  dir=$(pick_dir "$kind") || dir=""
  if [ -z "$dir" ]; then
    # Cancelled: hop back so this picker session self-destructing doesn't strand
    # the popup on some unrelated session.
    [ "$mode" = switch ] && tm switch-client -l
    return 0
  fi
  sess=$(session_name_for "$prefix" "$dir")
  ensure_session "$kind" "$sess" "$dir"
  tm switch-client -t "=$sess"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "${1:-}" in
  key)      cmd_key "$2" "$3" ;;
  run)      cmd_run "$2" "${3:-}" ;;
  pick)     cmd_pick "$2" "${3:-switch}" ;;
  resized)  cmd_resized "$2" ;;
  guard)    cmd_guard "$2" ;;
  name)     kind_config "$2"; session_name_for "$prefix" "$3"; printf '\n' ;;
  geom)     cmd_geom "$2" "$3" "$4" "$5" ;;
  classify) cmd_classify "$2" "$3" "$4" "$5" "$6" "$7" ;;
  __list)   emit_list "$2" ;;
  __kill)   [ -n "${2:-}" ] && tm kill-session -t "=$2" 2>/dev/null; exit 0 ;;
  *)        printf 'usage: float.sh {key|run|pick|resized|guard|name|geom|classify} ...\n' >&2; exit 2 ;;
esac
