#!/bin/sh
# Healthy means: the tmux session is alive and the supervisor loop that
# respawns `claude` is still running inside it. Exiting non-zero here marks
# the container unhealthy so the restart policy (see README) can recycle it.
set -u

SESSION="${TMUX_SESSION:-claude}"

tmux has-session -t "$SESSION" 2>/dev/null || exit 1
pgrep -f "claude-loop.sh" >/dev/null 2>&1 || exit 1

exit 0
