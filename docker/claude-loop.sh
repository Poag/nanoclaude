#!/bin/sh
# Runs inside the tmux pane. Keeps Claude Code running: if it exits (crash,
# `/exit`, network blip) it's restarted after a short delay so the container
# stays useful without manual intervention.
set -u

cd /workspace

echo "[nanoclaude] starting claude code loop (args: $*)"

while true; do
    claude "$@"
    status=$?
    echo "[nanoclaude] claude exited with status $status, restarting in 3s..."
    echo "[nanoclaude] (Ctrl-C now to drop to a shell instead)"
    sleep 3
done
