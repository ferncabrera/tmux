# Floating window for Claude (^A) and misc shells (^S). All behaviour lives in
# scripts/float.sh; this file is only the wiring, and tests/float_test.sh sources
# this exact file so the tests exercise the real bindings and hooks.
#
# Mouse gestures on the float (tmux 3.7 handles these natively, needs `mouse on`):
#   ⌥ + drag             move the float   (⌥ alone, not ⌥⇧/⌥⌃)
#   ⌥ + right-drag       resize it        (pointer = the bottom-right corner)
#   drag a border        also moves it; right-dragging the right/bottom border
#                        also resizes, but only reliably inwards — prefer ⌥.
#   right-click a border popup menu: Close / Fill Space / Centre / To pane

# ^A claude, ^S misc-shell. run-shell expands #{client_name} against the client
# that pressed the key, which is how float.sh knows whether the press came from
# inside the float (retarget it) or from a normal session (draw it).
bind ^A run-shell -b "~/.config/tmux/scripts/float.sh key claude #{client_name}"
bind ^S run-shell -b "~/.config/tmux/scripts/float.sh key misc #{client_name}"

# Terminal resized or font zoomed -> rebuild the float at the same proportion;
# float mouse-resized -> remember the new proportion. tmux only ever clamps an
# open popup and no command can resize one in place, so re-proportioning means
# rebuilding — which is free here, because the float's contents live in a session.
# The if-shell gate keeps unrelated clients from forking a shell on every resize.
# #{hook_client} is the client the event happened to (#{client_tty} would resolve
# against whichever client tmux considers current, which is not the same thing).
set-hook -g client-resized 'if -F "#{||:#{==:#{hook_client},#{@float-host}},#{==:#{hook_client},#{@float-client}}}" "run-shell -b \"~/.config/tmux/scripts/float.sh resized #{hook_client}\""'

# Whatever happens, only claude-*/misc-* sessions are ever shown in the float.
set-hook -g client-session-changed 'if -F "#{==:#{hook_client},#{@float-client}}" "run-shell -b \"~/.config/tmux/scripts/float.sh guard #{hook_client}\""'
