# nanoclaude

A minimal, persistent [Claude Code](https://www.npmjs.com/package/@anthropic-ai/claude-code)
container built to run under `podman` on ARM single-board computers, sized
for a **Raspberry Pi Zero 2 W** (quad-core Cortex-A53, 512MB RAM).

- **Base image:** `node:22-alpine` (Claude Code requires Node >= 22)
- **Persistent:** Claude Code runs inside a `tmux` session supervised by a
  restart loop, so a crashed or exited session comes back automatically and
  you can detach/reattach without losing it.
- **Self-healing:** a `HEALTHCHECK` verifies the supervisor is alive; wired
  up with podman's `--health-on-failure=kill` + a `Restart=always` systemd
  unit, an unhealthy container is killed and restarted automatically.
- **Multi-arch:** CI publishes `linux/amd64` and `linux/arm64` images to
  `ghcr.io/poag/nanoclaude`. There's no `linux/arm/v7` (32-bit) build — see
  [Why no 32-bit image](#why-no-32-bit-image) below — so this targets
  64-bit Raspberry Pi OS, which is recommended on the Zero 2 W anyway (see
  [Tuning](#tuning-for-a-pi-zero-2-512mb-ram) below).

## Layout

```
Dockerfile              image definition
docker/entrypoint.sh    PID 1: starts tmux, then idles
docker/claude-loop.sh   runs inside tmux, restarts `claude` if it exits
docker/healthcheck.sh   HEALTHCHECK command
docker-compose.yml      for local testing (podman-compose or docker compose)
systemd/nanoclaude.service   production unit for the Pi (native health-restart)
```

## Building

On the Pi itself (slow but simplest):

```sh
podman build -t nanoclaude:local .
```

Elsewhere, build on arm64 hardware directly (Apple Silicon, an arm64 CI
runner, another Pi) — don't cross-build `linux/arm64` under QEMU from an
amd64 host, see below for why:

```sh
docker buildx build --platform linux/arm64 -t nanoclaude:local .
```

`.github/workflows/docker-publish.yml` builds `linux/amd64` and
`linux/arm64` on GitHub's respective native runners (`ubuntu-latest` and
`ubuntu-24.04-arm`) and merges them into one multi-arch manifest, so no
QEMU is involved on the amd64 image either.

### Why no 32-bit image

Claude Code ships a prebuilt native binary per platform (via
`optionalDependencies`, e.g. `@anthropic-ai/claude-code-linux-arm64-musl`)
and runs it from its `postinstall` script. Under QEMU's usermode CPU
emulation that binary reliably crashes with `qemu: uncaught target signal
4 (Illegal instruction)` — a known fragility of emulating modern
Rust/Go-style static binaries with QEMU's TCG, not a bug in this
Dockerfile. Building on real arm64 silicon (GitHub's `ubuntu-24.04-arm`
runner, or an arm64 machine) sidesteps it entirely. There's no equivalent
hosted 32-bit ARM runner, so `linux/arm/v7` isn't built; run 64-bit
Raspberry Pi OS on the Zero 2 W instead.

## Running (quick test)

```sh
podman run -d --name nanoclaude \
  --health-on-failure=kill --restart=always \
  --memory=384m --memory-swap=512m \
  -v nanoclaude-config:/home/claude/.claude \
  -v ./workspace:/workspace:Z \
  -e ANTHROPIC_API_KEY=sk-ant-... \
  ghcr.io/poag/nanoclaude:latest
```

`--health-on-failure=kill` (podman >= 4.3) makes podman stop the container
the moment `HEALTHCHECK` reports unhealthy; combined with `--restart=always`
podman brings it straight back up. If your podman is new enough to support
the `restart` action (>= 4.6) you can use `--health-on-failure=restart`
instead and drop `--restart`.

Attach to the live Claude Code session:

```sh
podman exec -it nanoclaude tmux attach -t claude
```

Detach with `Ctrl-b d` — Claude Code keeps running.

### First-time auth

Claude Code needs to authenticate once. Attach as above and follow the
`/login` flow, or set `ANTHROPIC_API_KEY` on the container. Either way,
credentials are written under `/home/claude/.claude`, which is a named
volume (`nanoclaude-config`) — they persist across container restarts and
image upgrades.

Put the code you want Claude Code to work on in the `/workspace` volume
mount (`./workspace` in the examples above).

## Running as a persistent service on the Pi

`docker-compose.yml`'s `restart: unless-stopped` only restarts the
container if the process itself dies — compose has no concept of
restarting on an *unhealthy* status. For real self-healing on the Pi, use
the provided systemd unit instead:

```sh
sudo mkdir -p /var/lib/nanoclaude/workspace /etc/nanoclaude
sudo sh -c 'echo "ANTHROPIC_API_KEY=sk-ant-..." > /etc/nanoclaude/nanoclaude.env'
sudo cp systemd/nanoclaude.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now nanoclaude.service
```

This runs `podman run` in the foreground under systemd. `Restart=always`
brings the unit back whenever the container exits — including when
`--health-on-failure=kill` kills it for being unhealthy — so the container
comes back on a crash, an OOM kill, or a wedged tmux session, and also
starts on boot.

Check status and logs:

```sh
systemctl status nanoclaude.service
journalctl -u nanoclaude.service -f
podman inspect --format '{{.State.Health.Status}}' nanoclaude
```

## Tuning for a Pi Zero 2 (512MB RAM)

- `NODE_OPTIONS=--max-old-space-size=256` is set in the image to keep V8
  from over-committing memory.
- The examples above cap the container at 384MB, leaving headroom for the
  OS; adjust `--memory`/`--memory-swap` to taste.
- Make sure the Pi has swap enabled (`/etc/dphys-swapfile`) — 512MB is
  tight for `npm install`-heavy workflows even though the image itself
  doesn't run npm installs at runtime.
- Prefer 64-bit Raspberry Pi OS Lite (`linux/arm64`) if you can — it has
  a smaller memory overhead than 32-bit userland for Node workloads and
  matches the `linux/arm64` image variant.
