---
name: computer-manager-host-setup
description: Install, run, secure, verify, and troubleshoot computer-manager (the server half of the computer-agent pair) plus its desktop perception sidecar on a target Linux machine — GUI desktop, headless sandbox, container, or cloud VM. Use when setting up a machine so computer-agent can control it, installing or updating the computer-manager binary, generating/rotating MANAGER_API_TOKEN, wiring systemd or a supervisor loop, enabling GUI/RPA on a headless box (Xvfb), debugging 401s, empty screenshots, "connection refused" on :1337, or rolling back a bad update. Covers the checksum-verified curl|sh installer (REF/PREFIX/SKIP_DESKTOP knobs), air-gapped install from bundled assets/, the security model (token, firewall, TLS proxy), and the desktop sidecar (catalog/query/await/watch/diff).
---

# computer-manager — host setup & operations

`computer-manager` runs ON the machine to be controlled and serves a
token-authenticated HTTP control surface on `:1337`. The controller is
the `computer-agent` CLI (separate repo/skill: `computer-agent-driver`).
This skill is the server side: get a box from blank to controllable,
keep it healthy, fix it when it isn't.

## Quick start (machine with internet)

```sh
curl -fsSL https://raw.githubusercontent.com/ab0t-com/computer-manager/main/install.sh | sh
MANAGER_API_TOKEN=$(openssl rand -hex 32) computer-manager   # note the token!
```

Verify from the controller side:

```sh
curl -H "Authorization: Bearer $TOKEN" http://<host>:1337/ping
# or: computer-agent --url http://<host>:1337 --token $TOKEN ping
```

Installer knobs (env vars, composable):

| Knob | Effect |
|---|---|
| `REF=v0.1.0` | pin a tag/branch/sha instead of `main` |
| `PREFIX=$HOME/.local` | install without sudo (default `/usr/local`) |
| `SKIP_DESKTOP=1` | skip the perception sidecar |
| `REPO=fork/computer-manager` | install from a fork |

The installer is sha256-mandatory: it refuses to install anything that
doesn't match `release/checksums.txt`. Same-version re-run is a no-op.

## Air-gapped / no-internet target

This skill bundles both binaries in `assets/`. Upload and install by hand:

```sh
computer-agent upload assets/computer-manager /usr/local/bin/computer-manager   # if a manager already runs
# or scp/any transport, then on the target:
chmod 0755 /usr/local/bin/computer-manager
sha256sum /usr/local/bin/computer-manager   # MUST match release/checksums.txt
```

Same for `assets/desktop` → `/usr/local/bin/desktop`. Never skip the
checksum comparison.

## Decide the run shape

| Target | Do |
|---|---|
| Headless sandbox, terminal/files only | run with no `DISPLAY`; GUI verbs report unavailable — that's correct |
| Headless but GUI/RPA needed | `Xvfb :1 -screen 0 1920x1080x24 &` then `DISPLAY=:1` |
| Machine with a real desktop | `DISPLAY=:0` (or whatever the session uses) |
| Container | run as the container's foreground process or under its init (s6 etc.) |

## Keep it running

systemd (preferred on hosts) — keep the token OUT of the unit file:

```sh
install -m 600 /dev/null /etc/computer-manager.env
echo "MANAGER_API_TOKEN=$(openssl rand -hex 32)" > /etc/computer-manager.env
cat > /etc/systemd/system/computer-manager.service <<'EOF'
[Unit]
Description=computer-manager control surface
After=network.target
[Service]
EnvironmentFile=/etc/computer-manager.env
ExecStart=/usr/local/bin/computer-manager
Restart=always
RestartSec=1
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable --now computer-manager
```

No systemd (container/minimal box) — supervisor loop:

```sh
while true; do MANAGER_API_TOKEN=... computer-manager; sleep 1; done &
```

## Security checklist (do ALL of these)

1. **Token**: `openssl rand -hex 32` minimum. The manager refuses to boot
   without one. Rotation = restart with a new value (and update the
   controller's stored alias: `computer-agent sandboxes add <alias> <url> <new-token>`).
2. **Firewall `:1337`** to the controller's address(es) only. The manager
   executes commands by design — an open port is a remote shell.
3. **TLS**: plain HTTP on trusted networks only. Crossing the internet →
   front with a TLS-terminating proxy (nginx/caddy) and keep :1337 bound
   to localhost behind it.
4. **Token storage**: `chmod 600` env files; never in unit files, shell
   history you keep, or git.

## Verify (always, after any install/update)

```sh
curl -sf -H "Authorization: Bearer $TOKEN" http://localhost:1337/ping     # liveness
curl -sf -H "Authorization: Bearer $TOKEN" http://localhost:1337/health   # detail
computer-manager --version                                                # "manager <version>"
```

Then the GUI smoke that catches the classic silent failure — a manager
without a working display serves terminal verbs fine while GUI verbs
return empty:

```sh
computer-agent --url http://<host>:1337 --token $TOKEN screenshot -o /tmp/smoke.png
# zero-byte or error → no usable DISPLAY; see references/troubleshooting.md
```

## GUI/RPA prerequisites

RPA verbs shell out to X tooling. On the target:

```sh
# debian/ubuntu          # alpine                    # rhel-family
apt install -y xdotool scrot xclip tesseract-ocr
```

The curl|sh installer installs these when it can; on manual/air-gapped
installs do it yourself.

## The desktop sidecar (perception)

Installed next to the manager as `desktop`. It answers *observe* questions;
*acting* stays with the manager's RPA endpoints. Called through exec:

```sh
computer-agent exec "desktop -mode catalog -json"    # what windows exist?
computer-agent exec "desktop -mode query ..."        # where is element X?
computer-agent exec "desktop -mode await ..."        # block until X happens
computer-agent exec "desktop -mode watch -timeout 10s"  # change firehose
```

`desktop --help` lists every mode. Needs a display, like the GUI verbs.
If `exec "desktop ..."` says command not found, the binary isn't on the
exec PATH — symlink it: `ln -s <install-dir>/desktop /usr/local/bin/desktop`.

## Update & rollback

```sh
# update: re-run the installer (idempotent, verified)
curl -fsSL https://raw.githubusercontent.com/ab0t-com/computer-manager/main/install.sh | sh

# rollback: the previous binary is kept beside the new one
mv -f /usr/local/bin/computer-manager.previous /usr/local/bin/computer-manager
systemctl restart computer-manager   # or kill the process; the loop respawns it
```

Pin a known-good version explicitly with `REF=v<tag>`.

## Reference files

- **[troubleshooting.md](references/troubleshooting.md)** — read when any
  verification step fails: connection refused, 401, empty screenshots,
  sidecar not found, checksum mismatch, port conflicts, rollback paths.

## Bundled assets

- `assets/computer-manager` — the manager binary (static linux-amd64)
- `assets/desktop` — the perception sidecar (static linux-amd64)

Both must hash-match the repo's `release/checksums.txt` before use.
