#!/usr/bin/env bash
# Pick a working directory with fzf, then attach to (or create) a per-directory
# persistent floating Claude session. Invoked from the Ctrl-A tmux popup binding.
set -eu

# Roots to scan for projects in addition to zoxide's frecent list.
ROOTS=("$HOME/Code" "$HOME")

# Existing tmux sessions, joined with the ASCII field separator (\034) so names
# with spaces survive. Used to flag dirs that already have a live Claude session.
sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | tr '\n' '\034' || true)

# Build the picker list:
#  - zoxide frecency + a shallow fd scan of ROOTS
#  - strip trailing slashes (fd adds them, zoxide doesn't) so both sources dedupe
#  - drop duplicates, preserving first-seen order
#  - compute each dir's session name; list dirs with a live session first, tagged
#    with a "●" marker. Each line is "<marker>\t<dir>"; fzf searches/previews the
#    path (field 2) and we recover it after selection.
choice=$(
  {
    _ZO_DOCTOR=0 zoxide query -l 2>/dev/null || true
    fd --type d --max-depth 1 --hidden --exclude .git . "${ROOTS[@]}" 2>/dev/null || true
  } | awk -v sessions="$sessions" '
      BEGIN {
        n = split(sessions, a, "\034")
        for (j = 1; j <= n; j++) if (a[j] != "") live[a[j]] = 1
      }
      { sub(/\/+$/, "") }                  # normalize trailing slash
      !NF || seen[$0]++ { next }           # skip blanks and duplicates
      {
        m = split($0, p, "/")
        slug = (m >= 2) ? p[m-1] "-" p[m] : p[m]
        gsub(/[^[:alnum:]_-]/, "_", slug)
        if (("claude-" slug) in live) active[++na] = $0
        else                             other[++no] = $0
      }
      END {
        for (k = 1; k <= na; k++) printf "\033[32m󱘖\033[0m\t%s\n", active[k]
        for (k = 1; k <= no; k++) printf " \t%s\n", other[k]
      }
    ' |
    fzf \
      --ansi \
      --delimiter '\t' \
      --nth 2 \
      --scheme path \
      --prompt 'claude dir> ' \
      --header '󱘖 live session' \
      --height 100% \
      --layout reverse \
      --border \
      --info inline \
      --preview 'eza -la --color=always --icons --group-directories-first --git {2} 2>/dev/null | head -200'
) || exit 0

# Recover the directory (2nd tab-separated field) from the selected line.
dir=$(printf '%s\n' "$choice" | awk -F'\t' '{print $2}')
[ -z "${dir:-}" ] && exit 0

# Session name from the last two path components, e.g. ~/Code/open_ims -> claude-Code-open_ims
slug=$(printf '%s' "$dir" | awk -F/ '{ if (NF>=2) print $(NF-1)"-"$NF; else print $NF }')
name="claude-$(printf '%s' "$slug" | tr -c '[:alnum:]_-' '_')"

if tmux has-session -t "=$name" 2>/dev/null; then
  exec tmux attach-session -t "=$name"
else
  exec tmux new-session -s "$name" -c "$dir" -n claude \
    "tmux set-option -t '$name' status off; claude"
fi
