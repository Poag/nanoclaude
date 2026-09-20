#!/bin/sh
# Restarts the container if podman reports it unhealthy. Dockhand starts,
# stops, and redeploys the stack itself — this only intervenes on health,
# so it's safe to run alongside Dockhand rather than instead of it.
set -eu

CONTAINER="${1:-nanoclaude}"

status=$(podman inspect --format '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo "missing")

if [ "$status" = "unhealthy" ]; then
    echo "$(date -Is) $CONTAINER is unhealthy, restarting"
    podman restart "$CONTAINER"
fi
