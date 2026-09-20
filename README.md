# nanoclaude

A minimal, persistent [Claude Code](https://www.npmjs.com/package/@anthropic-ai/claude-code)
container built to run under `podman` on ARM single-board computers, sized
for a **Raspberry Pi Zero 2 W** (quad-core Cortex-A53, 512MB RAM).

- **Base image:** `node:22-alpine` (Claude Code requires Node >= 22)
- **Persistent:** Claude Code runs inside a `tmux` session supervised by a
  restart loop, so a crashed or exited session comes back automatically and
  you can detach/reattach without losing it.
- **Self-healing:** a `HEALTHCHECK` verifies the supervisor is alive. How an
  unhealthy container actually gets restarted depends on how you're running
  it — see [Deploying](#deploying) below, there are three options.
- **Multi-arch:** CI publishes `linux/amd64` and `linux/arm64` images to
  `ghcr.io/poag/nanoclaude`. There's no `linux/arm/v7` (32-bit) build — see
  [Why no 32-bit image](#why-no-32-bit-image) below — so this targets
  64-bit Raspberry Pi OS, which is recommended on the Zero 2 W anyway (see
  [Tuning](#tuning-for-a-pi-zero-2) below).

## Layout

```
Dockerfile                          image definition
docker/entrypoint.sh                PID 1: starts tmux, then idles
docker/claude-loop.sh               runs inside tmux, restarts `claude` if it exits
docker/healthcheck.sh               HEALTHCHECK command
compose.yaml                        Compose Specification — Dockhand-deployable, pulls the published image
systemd/nanoclaude-standalone.service   solo-host unit: podman run + native health-restart (no Dockhand)
systemd/nanoclaude-watchdog.{service,timer}  Dockhand-fleet fallback: restarts on unhealthy, doesn't own start/stop
systemd/nanoclaude-watchdog.sh      the watchdog's actual check + restart logic
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

## Quick manual test

```sh
podman run -d --name nanoclaude \
  --health-on-failure=kill --restart=always \
  --memory=224m --memory-swap=448m \
  -e NODE_OPTIONS=--max-old-space-size=128 \
  -v nanoclaude-config:/home/claude/.claude \
  -v ./workspace:/workspace:Z \
  -e ANTHROPIC_API_KEY=sk-ant-... \
  ghcr.io/poag/nanoclaude:latest
```

`--health-on-failure=kill` (podman >= 4.3) makes podman stop the container
the moment `HEALTHCHECK` reports unhealthy; combined with `--restart=always`
podman brings it straight back up. If your podman is new enough to support
the `restart` action (>= 4.6) you can use `--health-on-failure=restart`
instead and drop `--restart`. See [Tuning](#tuning-for-a-pi-zero-2) for
where the memory numbers come from.

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

## Deploying

There are three ways to run this long-term, depending on whether Dockhand
manages the host.

### 1. Standalone systemd (no Dockhand)

For a Pi that isn't part of the Dockhand fleet. `podman run` runs in the
foreground under systemd; `Restart=always` brings the unit back whenever
the container exits — including when `--health-on-failure=kill` kills it
for being unhealthy — so it comes back on a crash, an OOM kill, or a
wedged tmux session, and also starts on boot.

```sh
sudo mkdir -p /var/lib/nanoclaude/workspace /etc/nanoclaude
sudo sh -c 'echo "ANTHROPIC_API_KEY=sk-ant-..." > /etc/nanoclaude/nanoclaude.env'
sudo cp systemd/nanoclaude-standalone.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now nanoclaude-standalone.service
```

Check status and logs:

```sh
systemctl status nanoclaude-standalone.service
journalctl -u nanoclaude-standalone.service -f
podman inspect --format '{{.State.Health.Status}}' nanoclaude
```

### 2. Dockhand fleet deployment

`compose.yaml` at the repo root is a plain [Compose Specification](https://docs.docker.com/compose/compose-file/)
stack — no `build:`, it pulls the published multi-arch image, matching how
this fleet's other Dockhand stacks are set up (see e.g. the `discordweb`
repo). Point Dockhand at this repo with `compose_path: compose.yaml`.

Before first deploy, on the target host:

```sh
sudo mkdir -p /srv/nanoclaude/workspace
```

(or set `NANOCLAUDE_WORKSPACE` to wherever you want the code Claude Code
operates on to live — it's a host bind mount, deliberately outside
wherever Dockhand checks this repo out, so it survives independently of
the stack definition.) Set `ANTHROPIC_API_KEY` as an environment variable
on the stack in Dockhand, or leave it unset and authenticate interactively
after first deploy (see [First-time auth](#first-time-auth)) — either way,
credentials persist in the `claude-config` named volume.

`restart: unless-stopped` in `compose.yaml` handles crash-exit restarts.
Whether Dockhand itself watches container health and redeploys on
`unhealthy` isn't confirmed — if it doesn't, install the watchdog pair
below, which only intervenes on health and doesn't compete with Dockhand
for ownership of starting/stopping the stack:

```sh
sudo cp systemd/nanoclaude-watchdog.sh /usr/local/bin/
sudo chmod 755 /usr/local/bin/nanoclaude-watchdog.sh
sudo cp systemd/nanoclaude-watchdog.service systemd/nanoclaude-watchdog.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now nanoclaude-watchdog.timer
```

It checks every minute (`podman inspect --format '{{.State.Health.Status}}'
nanoclaude`) and runs `podman restart nanoclaude` if unhealthy. If Dockhand
turns out to already handle this, the timer is harmless to leave running —
it just never finds anything to do — but you can disable it
(`systemctl disable --now nanoclaude-watchdog.timer`) once confirmed.

### 3. Manual, no systemd

Just the [Quick manual test](#quick-manual-test) command above, left
running. Fine for trying it out; use one of the above for anything you
want to survive a reboot or a crash unattended.

## Tuning for a Pi Zero 2

The 224MB/128MB numbers in this repo (image default is looser: see the
Dockerfile's `NODE_OPTIONS`) come from a real Pi Zero 2 W already running
other services under podman (Hawser, among others):

```
$ vcgencmd get_mem gpu
gpu=16M
$ free -m
               total        used        free      shared  buff/cache   available
Mem:             463         194         103           2         221         268
Swap:            462           0         462
```

With ~194MB already used by the OS and other containers before nanoclaude
even starts, and only ~268MB "available" (the kernel's estimate including
reclaimable cache), a 384MB cap — fine for a Pi running only this — would
leave the host with no margin. So:

- `NODE_OPTIONS=--max-old-space-size=128` (down from the image's default
  256) caps V8's heap, leaving headroom under the container's own memory
  limit for Node's baseline RSS and child processes (git, ripgrep, bash).
- `mem_limit: 224m` / `memswap_limit: 448m` in `compose.yaml` (same
  `--memory`/`--memory-swap` values in the systemd units): a 224MB hard
  RAM cap, with up to 224MB more of swap allowed above it. The point of
  the swap headroom is that a transient spike swaps (slow on SD/USB
  storage, but survivable) rather than getting OOM-killed outright — worth
  it here since this Pi's swap is otherwise sitting completely unused.
- Re-check `free -m` after deploying and adjust these numbers to your
  host's actual headroom, especially if other services' footprints
  change — these aren't universal constants, they're sized against the
  numbers above.
- Make sure swap is actually enabled (`/etc/dphys-swapfile`) if you
  haven't already — it clearly is on the host these numbers came from.
- Prefer 64-bit Raspberry Pi OS Lite (`linux/arm64`) if you can — it has
  a smaller memory overhead than 32-bit userland for Node workloads and
  matches the `linux/arm64` image variant.
