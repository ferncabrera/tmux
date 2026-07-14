#!/usr/bin/env bash
# Pick a working directory with fzf, then connect to (or create) a per-directory
# persistent floating "misc-shell" session. Invoked from the Ctrl-S tmux popup
# binding. Mirrors claude-popup.sh, but each session runs an interactive shell
# (fastfetch + zsh) instead of Claude.
#
# Modes:
#   attach  (default) — popup opened fresh from a normal session; attach the popup
#                       client to the chosen session.
#   switch            — we're already inside a popup; the binding parked us in the
#                       throwaway "misc-picker" session, so retarget the popup
#                       client with switch-client instead of stacking a nested popup.
set -eu

# Roots to scan for projects in addition to zoxide's frecent list.
ROOTS=("$HOME/Code" "$HOME")

# Visual identity so it's obvious at a glance which picker is open (blue = misc-shell).
accent='#7e9cd8'
border_label=' MISC-SHELL '

# Absolute path to this script so the fzf binds below can re-invoke our sub-modes
# (fzf runs each bind command in a separate process, not inside this shell).
self="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"

# emit_list: build the picker list. Runs for the initial fzf load and again on every
# `reload` (after an alt-bspace / ctrl-x kill) so a killed session stops showing as live.
emit_list() {
  # Existing tmux sessions, ordered most-recently-attached first and joined with the
  # ASCII field separator (\034) so names with spaces survive. Used to flag dirs that
  # already have a live misc-shell session and to order those dirs by most recent use.
  # `session_last_attached` is the epoch of the last attach; sort -rn floats the
  # session you opened most recently to the top, then cut keeps just the name.
  local sessions
  sessions=$(
    tmux list-sessions -F '#{session_last_attached} #{session_name}' 2>/dev/null \
      | sort -rn -k1,1 \
      | cut -d' ' -f2- \
      | grep -vx 'misc-picker' \
      | tr '\n' '\034' || true
  )

# Build the picker list:
#  - zoxide frecency + a shallow fd scan of ROOTS
#  - strip trailing slashes (fd adds them, zoxide doesn't) so both sources dedupe
#  - drop duplicates, preserving first-seen order
#  - compute each dir's session name; list dirs with a live session first, tagged
#    with a "" marker. Each line is "<marker>\t<dir>"; fzf searches/previews the
#    path (field 2) and we recover it after selection.
  {
    _ZO_DOCTOR=0 zoxide query -l 2>/dev/null || true
    fd --type d --max-depth 1 --hidden --exclude .git . "${ROOTS[@]}" 2>/dev/null || true
  } | awk -v sessions="$sessions" '
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
        sname = "misc-" slug
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

# Sub-modes invoked by the fzf binds below (run as separate processes by fzf):
# __list rebuilds the picker list (used by `reload` after a kill); __kill <name>
# terminates a live session. <name> is field {3}; empty = harmless no-op.
if [ "${1:-}" = __list ]; then emit_list; exit 0; fi
if [ "${1:-}" = __kill ]; then
  if [ -n "${2:-}" ]; then tmux kill-session -t "=$2" 2>/dev/null || true; fi
  exit 0
fi

mode="${1:-attach}"

choice=$(
  emit_list | fzf \
      --ansi \
      --delimiter '\t' \
      --with-nth 1,2 \
      --nth 2 \
      --scheme path \
      --prompt 'shell dir> ' \
      --header '󱘖 live shell' \
      --height 100% \
      --layout reverse \
      --border \
      --border-label "$border_label" \
      --border-label-pos 3 \
      --color "border:$accent,label:$accent:reverse:bold,prompt:$accent,pointer:$accent,marker:$accent,info:$accent,spinner:$accent,header:$accent" \
      --info inline \
      --preview-window 'right,60%,border-left' \
      --bind "alt-bspace,ctrl-x:execute-silent($self __kill {3})+reload($self __list)" \
      --preview '
        name={3}; dir={2}
        if [ -n "$name" ] && tmux has-session -t "=$name" 2>/dev/null; then
          tmux capture-pane -ep -t "$name"           # live shell: show its screen
        else
          eza -la --color=always --icons --group-directories-first --git "$dir" 2>/dev/null | head -200
        fi'
) || choice=""

# Recover the directory (2nd tab-separated field) from the selected line.
dir=$(printf '%s\n' "$choice" | awk -F'\t' '{print $2}')
if [ -z "${dir:-}" ]; then
  # Cancelled (Esc). In switch mode the popup is currently showing the throwaway
  # misc-picker session; hop back to the previous session so that picker
  # self-destructing doesn't strand the popup on some unrelated session.
  [ "$mode" = switch ] && exec tmux switch-client -l
  exit 0
fi

# Session name from the FULL path so dirs sharing their last components don't
# collide, e.g. /Users/you/Code/open_ims -> misc-_Users_you_Code_open_ims.
# Must match the awk slug logic above (same character class).
name="misc-$(printf '%s' "$dir" | tr -c '[:alnum:]_-' '_')"

# Create the per-directory session if needed, then connect to it: switch mode
# retargets the current popup client (no nesting), attach mode wires up this popup.
if ! tmux has-session -t "=$name" 2>/dev/null; then
  tmux new-session -d -s "$name" -c "$dir" -n shell \
    "tmux set-option -t '$name' status off; fastfetch; exec zsh"
fi

if [ "$mode" = switch ]; then
  exec tmux switch-client -t "=$name"
else
  exec tmux attach-session -t "=$name"
fi
