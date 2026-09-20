#!/bin/sh
# Starts (or restarts) a tmux session running the Claude Code respawn loop,
# then parks PID 1 so the container stays up. Any CMD arguments are passed
# straight through to `claude`.
set -eu

SESSION="${TMUX_SESSION:-claude}"

tmux kill-server 2>/dev/null || true
tmux new-session -d -s "$SESSION" -n main -- /usr/local/bin/claude-loop.sh "$@"

echo "[nanoclaude] tmux session '$SESSION' started."
echo "[nanoclaude] attach with: podman exec -it <container> tmux attach -t $SESSION"

exec tail -f /dev/null
