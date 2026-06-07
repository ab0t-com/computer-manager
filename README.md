# computer-manager

A single static Go binary that turns any Linux machine — a GUI desktop, a
headless sandbox, a container, a cloud VM — into a **remotely controllable
computer**. It runs *on* the machine and exposes a token-authenticated HTTP
control surface (`:1337`): run commands, move files, take screenshots, perform
GUI/RPA actions, report system state. Think of it as an advanced agent in the
spirit of a cloud SSM agent, built for AI-driven control.

It is the **server half** of a pair. The client half is
[`computer-agent`](https://github.com/ab0t-com/computer-agent):

```
  computer-agent (controller, runs anywhere)
        │  HTTP + bearer token
        ▼
  computer-manager (:1337, runs ON the target machine)
        ├── terminal (exec, sessions)         — works headless
        ├── filesystem (upload/download)      — works headless
        ├── system (ping/health/info/metrics) — works headless
        ├── GUI/RPA (screenshot, click, type, OCR) — needs an X display
        └── desktop (sidecar CLI)             — perception: catalog/query/await/watch
```

The install also ships **`desktop`**, a small sidecar CLI for *perception* —
"what windows exist?", "where is the OK button?", "block until X happens",
"what changed?" — over X11 + AT-SPI. Agents call it through the manager
(`computer-agent exec "desktop -mode catalog -json"`); acting stays with the
manager's RPA surface. It's optional: skip it with `SKIP_DESKTOP=1` on install.

**Headless or desktop — same binary.** On a box with no GUI you still get the
full terminal/filesystem/system surface; point it at an X display (real or
Xvfb) and the GUI/RPA verbs light up too.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/ab0t-com/computer-manager/main/install.sh | sh
```

POSIX sh, HTTPS-only, verifies the published sha256 before installing, keeps
the previous binary for rollback, idempotent. Pin a version or change location:

```sh
REF=v0.1.0 curl -fsSL https://raw.githubusercontent.com/ab0t-com/computer-manager/main/install.sh | sh
PREFIX=$HOME/.local curl -fsSL .../install.sh | sh
```

Or grab the binary from [`release/`](release/) (a static `linux-amd64` build,
no runtime deps) and verify it against [`release/checksums.txt`](release/checksums.txt).

## Quickstart

```sh
# on the machine you want controlled
MANAGER_API_TOKEN=$(openssl rand -hex 32) computer-manager
# note the token — every request must present it

# headless box, but you want GUI/RPA verbs too? give it a display
DISPLAY=:1 MANAGER_API_TOKEN=... computer-manager
```

Then, from anywhere:

```sh
# raw HTTP
curl -H "Authorization: Bearer <token>" http://<host>:1337/ping

# or the computer-agent CLI (recommended)
computer-agent sandboxes add mybox http://<host>:1337 <token>
computer-agent sandboxes use mybox
computer-agent exec "uptime"
computer-agent screenshot -o screen.png
```

See [`docs/USAGE.md`](docs/USAGE.md) for the control surface, environment
variables, and GUI/RPA prerequisites.

## Security model

- **One bearer token** (`MANAGER_API_TOKEN`) guards the entire surface —
  generate it strong, transport it carefully, rotate it by restarting with a
  new value. No token, no boot.
- This binary **executes commands and writes files by design**. Only run it on
  machines you intend to hand over to a controller, and only expose `:1337` to
  networks you trust (firewall it; front it with a TLS proxy for the open
  internet).

## Repository layout

```
computer-manager/
├── install.sh      # POSIX, checksum-verified installer (curl | sh)
├── release/        # computer-manager + desktop sidecar + checksums.txt + VERSION
└── docs/           # USAGE — control surface, env vars, prereqs
```

## License

MIT — see [`LICENSE`](LICENSE).
