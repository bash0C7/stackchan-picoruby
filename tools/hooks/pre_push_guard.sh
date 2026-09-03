#!/bin/sh
# PreToolUse hook: run the dependency guard before Claude pushes anything.
#
# It hangs off the bare `Bash` matcher rather than a command pattern. A hook's
# `if` field takes permission-rule syntax, which prefix-matches the command, and
# the pushes that matter here do not start with `git push`: they are
# `git -C vendor/R2P2-ESP32 push`, and an absolute `/opt/homebrew/bin/git push`
# whenever PATH is broken. Both were measured slipping past `Bash(git push*)`.
# So every Bash call reaches this script and it decides for itself, with shell
# parameter expansion only — nothing is spawned on the path that exits early.
#
# The match is deliberately loose: it wants a `git ` invocation with a later
# ` push`, so `git commit -m "... push ..."` runs the check too. A needless run
# costs three seconds; a missed push costs a tree that builds on one disk only.
#
# To push the branch that publishes a pin, put STACKCHAN_DEPS_GUARD=off in front
# of the command: that push is the cure, and the guard would otherwise block it.
payload=$(cat)

case "$payload" in
  *'"tool_name":"Bash"'*) ;;
  *) exit 0 ;;
esac

# tool_input.command, taken between its own key and the next key. When there is
# no description the tail is kept, which only ever over-matches.
rest=${payload#*'"command":"'}
cmd=${rest%%'","description":"'*}

case "$cmd" in
  *STACKCHAN_DEPS_GUARD=off*) exit 0 ;;
  *"git "*" push"*|*"git push"*) ;;
  *) exit 0 ;;
esac

# A blocked tool call shows the hook's stderr and nothing else, so the reason the
# push was refused has to arrive there — on the way through, not as an exit code.
report=$("$(dirname "$0")/../check_deps_pushed.sh" --pins-only 2>&1) && exit 0
printf '%s\n' "$report" | grep -v ' ok$' >&2
exit 2
