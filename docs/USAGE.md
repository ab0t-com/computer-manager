# computer-manager — usage

The manager is a single static binary with no config file. Everything is
environment variables + HTTP.

## Running

```sh
# minimal — binds 0.0.0.0:1337, token from env (mandatory)
MANAGER_API_TOKEN=$(openssl rand -hex 32) computer-manager

# with a display, enabling the GUI/RPA verbs
DISPLAY=:1 MANAGER_API_TOKEN=... computer-manager

# check what you're running
computer-manager --version
```

Keep it alive however your host prefers — systemd unit, s6 service, container
entrypoint, or a plain supervisor loop:

```sh
while true; do MANAGER_API_TOKEN=... computer-manager; sleep 1; done
```

## Environment

| Variable | Required | Meaning |
|---|---|---|
| `MANAGER_API_TOKEN` | **yes** | Bearer token every request must present. Strong + random, please. |
| `DISPLAY` | for GUI verbs | X display to drive (`:0`, `:1`, an Xvfb screen…). Without it, GUI/RPA endpoints report unavailable; terminal/files/system still work. |

## Authentication

Every request:

```sh
curl -H "Authorization: Bearer $TOKEN" http://<host>:1337/ping
```

## Control surface (endpoint groups)

| Group | What | Headless? |
|---|---|---|
| **system** | `/ping`, `/health`, `/manager/version` — liveness, health detail, running version | ✅ |
| **terminal** | `/execute` (run a command, capture output), `/sessions` (persistent shells) | ✅ |
| **files** | upload / download / list — move artifacts on and off the box | ✅ |
| **GUI / RPA** | screenshot, mouse (move/click), keyboard (type/key/hotkey), clipboard, OCR, image-match, computer-use passthrough | needs `DISPLAY` |

The [`computer-agent`](https://github.com/ab0t-com/computer-agent) CLI wraps
this entire surface in friendly verbs (`exec`, `upload`, `screenshot`,
`click`, `ocr`, fleet fan-out across many managers) — use it instead of raw
curl unless you're integrating directly.

## The `desktop` sidecar (perception)

Installed next to the manager by `install.sh` (skip with `SKIP_DESKTOP=1`).
It answers the *observe* half of the agent loop — observe → find → wait →
act → diff — while *act* stays with the manager's RPA endpoints:

| Mode | Question it answers |
|---|---|
| `desktop -mode catalog` | what windows exist right now? (handle/class/title, focus) |
| `desktop -mode query` | where is the «X» element? (AT-SPI find) |
| `desktop -mode await` | block until «X» happens |
| `desktop -mode watch` | what is changing? (JSON-lines firehose, `-timeout`) |
| `desktop -mode diff` / `digest` | what changed since last look? |

Most callers never run it directly on the box — they go through the manager:

```sh
computer-agent exec "desktop -mode catalog -json"
```

Add `-json` for machine-readable output; `desktop --help` lists every mode.
Like the GUI/RPA group, it needs an X display (`-display` flag or `DISPLAY`).

## GUI/RPA prerequisites

The RPA verbs shell out to standard X tooling. On the target machine install:

```
xdotool scrot xclip tesseract-ocr     # apt/apk/yum names vary slightly
```

Headless box that needs a display? `Xvfb :1 -screen 0 1920x1080x24 &` and run
the manager with `DISPLAY=:1`.

## Updating

Re-run the installer — it's idempotent, verifies sha256, and keeps the prior
binary as `computer-manager.previous` for one-step rollback:

```sh
curl -fsSL https://raw.githubusercontent.com/ab0t-com/computer-manager/main/install.sh | sh
```

## Operational notes

- **Expose `:1337` deliberately.** The manager executes commands by design.
  Firewall the port to your controller's address(es); use a TLS-terminating
  proxy if it must cross the open internet.
- **Token rotation** = restart with a new `MANAGER_API_TOKEN`.
- **One manager per machine** is the model; drive fleets from the client side
  (`computer-agent` fleet verbs), not by stacking managers.
