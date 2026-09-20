FROM node:22-alpine

LABEL org.opencontainers.image.description="Persistent Claude Code container, sized to run under podman on ARM boards such as a Raspberry Pi Zero 2 W"

# tini      - reaps zombies as PID 1
# tmux      - keeps an interactive Claude Code session alive so it can be
#             attached/detached without killing the process
# git/openssh-client/ca-certificates - needed by Claude Code to work with repos
# procps    - provides pgrep, used by the health check
# bash      - used by the helper scripts
RUN apk add --no-cache tini tmux git openssh-client ca-certificates procps bash

ARG CLAUDE_CODE_VERSION=latest
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
    && npm cache clean --force

RUN addgroup -g 1000 claude \
    && adduser -D -u 1000 -G claude -h /home/claude -s /bin/bash claude

COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=755 docker/claude-loop.sh /usr/local/bin/claude-loop.sh
COPY --chmod=755 docker/healthcheck.sh /usr/local/bin/healthcheck.sh

RUN mkdir -p /workspace /home/claude/.claude \
    && chown -R claude:claude /workspace /home/claude

USER claude
WORKDIR /workspace

ENV HOME=/home/claude \
    NODE_OPTIONS=--max-old-space-size=256 \
    TMUX_SESSION=claude

# /home/claude/.claude holds auth/session state, /workspace holds the code
# Claude Code operates on - both should be backed by persistent volumes.
VOLUME ["/home/claude/.claude", "/workspace"]

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
