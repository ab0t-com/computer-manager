---
name: computer-manager-api
description: Drive a computer-manager instance directly over its HTTP API — advanced control beyond the computer-agent CLI verbs. Use when calling endpoints from code or curl (execute/sessions, files upload/download, RPA mouse/keyboard/clipboard/OCR/find-image, Anthropic computer-use passthrough, server-side agent loop), when using the awareness layer (snapshot/diff/digest/watch, fs-watch, window-catalog, pointer, regions), when managing windows (focus/move/resize/tile/close/screenshot) or virtual desktops, when running multi-step workflows (/workflow/execute, status, logs, cancel), when discovering the live API (/openapi.json, /llm.txt), when scripting the desktop perception CLI (catalog/query/await/digest/diff/atspi-tree, exit codes), or when integrating computer-manager into a custom agent/orchestrator without the CLI.
---

# computer-manager — direct API & advanced control

Everything the manager can do, addressable three ways. Prefer them in order:

1. **`computer-agent` CLI** — friendly verbs over this API. Install:
   `curl -fsSL https://raw.githubusercontent.com/ab0t-com/computer-cli/main/install.sh | sh`
   (its own skills: `computer-agent-driver`, `computer-agent-usage`).
2. **Raw HTTP** (this skill) — full surface, including routes the CLI
   doesn't wrap.
3. **`desktop` CLI on the box** — perception primitives, called via
   `/execute` or a local shell. Full reference: [desktop-cli.md](references/desktop-cli.md).

## Discovery first — the live instance is the source of truth

A running manager documents itself. Start every integration here:

```sh
B="http://<host>:1337"; H="Authorization: Bearer $TOKEN"
curl -s -H "$H" $B/openapi.json | python3 -m json.tool   # machine-readable spec
curl -s -H "$H" $B/llm.txt                               # agent-oriented orientation
curl -s -H "$H" $B/llm-cli.txt                           # CLI-oriented orientation
```

**Known gap:** the static spec under-advertises — the awareness (`/awareness/*`),
window-manager (`/window/*`), and virtual-desktop (`/desktop/*`) groups are
live but may be missing from `/openapi.json`. The full route catalog is in
[endpoints.md](references/endpoints.md).

## Auth — one header, everywhere

```sh
curl -H "Authorization: Bearer $TOKEN" http://<host>:1337/ping
```

Every route except nothing: no anonymous endpoints. 401 → token mismatch
(check what the process actually holds — see the host-setup skill's
troubleshooting).

## The seven surface groups

| Group | Routes | Use for |
|---|---|---|
| system | `/ping` `/health` `/metrics` `/skills` `/manager/version` `/manager/logs` `/manager/update` `/manager/cleanup` | liveness, ops, self-update |
| terminal | `/execute` `/sessions` | run commands, persistent shells |
| files | `/files/upload` `/files/download` `/files/list` | move artifacts (also served standalone on :8081) |
| RPA | `/rpa/*` — 20 routes | act: mouse, keyboard, clipboard, screenshot, OCR, image-match, computer-use, agent loop |
| awareness | `/awareness/*` — 12 routes | observe: snapshot/diff/digest/watch, fs-watch, pointer, regions, window-catalog |
| window mgmt | `/window/*` — 9 routes | focus/move/resize/tile/raise/close/screenshot a window |
| workflows | `/workflow/*` — 7 routes | multi-step DAGs that survive controller disconnects |

Per-route methods, params, and JSON schemas: [endpoints.md](references/endpoints.md).

## Core recipes

**Execute, with a persistent session** (state survives across calls):

```sh
curl -s -H "$H" -H 'Content-Type: application/json' -X POST $B/execute \
  -d '{"command":"export FOO=bar && cd /tmp","session_id":"build-1"}'
curl -s -H "$H" -H 'Content-Type: application/json' -X POST $B/execute \
  -d '{"command":"echo $FOO && pwd","session_id":"build-1"}'   # bar, /tmp
# fields: command* | cwd | timeout (s) | session_id | environment {k:v}
curl -s -H "$H" $B/sessions                       # list
curl -s -H "$H" -X DELETE $B/sessions/build-1     # kill
```

**Files** (multipart up, query-param down):

```sh
curl -s -H "$H" -X POST "$B/files/upload?path=/tmp/in.bin&overwrite=true" \
  -F file=@local.bin
curl -s -H "$H" "$B/files/download?path=/tmp/out.bin" -o out.bin
curl -s -H "$H" "$B/files/list?path=/tmp"
```

**Act (RPA), the three you'll use most:**

```sh
curl -s -H "$H" -H 'Content-Type: application/json' -X POST $B/rpa/click \
  -d '{"x":640,"y":360,"button":"left","clicks":1}'
curl -s -H "$H" -H 'Content-Type: application/json' -X POST $B/rpa/type \
  -d '{"text":"hello","interval":0.02}'
curl -s -H "$H" -X POST $B/rpa/screenshot -o screen.png
```

**Anthropic computer-use passthrough** — send tool-use actions verbatim;
the manager translates to X:

```sh
curl -s -H "$H" -H 'Content-Type: application/json' -X POST $B/rpa/computer-use \
  -d '{"action":"left_click","coordinate":[640,360]}'
# actions take: coordinate, start_coordinate, text, scroll_direction,
# scroll_amount, duration, region — mirror the Anthropic tool schema.
```

**Server-side agent loop** (screenshot→model→action runs ON the manager):

```sh
curl -s -H "$H" -H 'Content-Type: application/json' -X POST $B/rpa/agent \
  -d '{"task":"Open the text editor and type hello","max_steps":10}'
# fields: task* | model | max_steps | system_prompt
# Needs an Anthropic key available to the run — the computer-agent CLI
# forwards ANTHROPIC_API_KEY as a header; do the same, never store it on the box.
```

## Observe before you act — the awareness layer

The act/observe split is the architecture: `/rpa/*` acts, `/awareness/*`
and the `desktop` sidecar observe. The canonical loop:

```sh
curl -s -H "$H" $B/awareness/snapshot          # full state now (note the snapshot id/time)
# ... act ...
curl -s -H "$H" "$B/awareness/diff?since=<snap>"   # what changed since
curl -s -H "$H" $B/awareness/windows           # window list
curl -s -H "$H" $B/awareness/window-catalog    # richer per-window detail
curl -s -H "$H" $B/awareness/pointer           # where is the mouse
curl -s -H "$H" $B/awareness/regions           # screen regions
```

Filesystem watching (poll-free file awareness):

```sh
curl -s -H "$H" -H 'Content-Type: application/json' -X POST $B/awareness/fs/watch \
  -d '{"paths":["/tmp/build"]}'
curl -s -H "$H" $B/awareness/fs/state          # accumulated changes
```

## Window & virtual-desktop management

```sh
curl -s -H "$H" -H 'Content-Type: application/json' -X POST $B/window/focus  -d '{"handle":"gedit"}'
curl -s -H "$H" -H 'Content-Type: application/json' -X POST $B/window/tile   -d '{...}'   # see endpoints.md
curl -s -H "$H" -X POST $B/window/screenshot   # one window, not the screen
curl -s -H "$H" $B/desktop/current             # virtual desktop index
curl -s -H "$H" -X POST $B/desktop/next        # switch
```

## Workflows — runs that outlive the connection

```sh
curl -s -H "$H" -H 'Content-Type: application/json' -X POST $B/workflow/execute \
  -d '{"workflow_id":"ff","variables":{"url":"https://example.com"},"async_execution":true}'
curl -s -H "$H" $B/workflow/executions/<id>          # status
curl -s -H "$H" $B/workflow/executions/<id>/logs     # logs
curl -s -H "$H" -X POST $B/workflow/executions/<id>/cancel
curl -s -H "$H" $B/workflow/history
```

If the caller dies mid-run the workflow continues — re-attach via history.

## Reference files

- **[endpoints.md](references/endpoints.md)** — the complete route catalog
  (all 7 groups, methods, params, request schemas), read when you need a
  route not shown above.
- **[desktop-cli.md](references/desktop-cli.md)** — the perception sidecar
  in full: all 8 modes, flags, exit codes, error envelope, agent-loop
  patterns. Read when scripting `desktop` via `/execute`.
