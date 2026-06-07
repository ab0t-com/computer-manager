# computer-manager — complete endpoint catalog

Every registered route, by group. `*` = required field. The live
`/openapi.json` on your instance is authoritative for system/terminal/
files/RPA/workflow; the awareness/window/desktop groups are registered in
the server but may be missing from the static spec (known gap) — they are
listed here from source.

All routes require `Authorization: Bearer <token>`.

## Contents

- [system & ops](#system--ops)
- [terminal](#terminal)
- [files](#files)
- [RPA — act](#rpa--act)
- [awareness — observe](#awareness--observe)
- [window management](#window-management)
- [virtual desktops](#virtual-desktops)
- [workflows](#workflows)

## system & ops

| Method | Route | Notes |
|---|---|---|
| GET | `/ping` | liveness |
| GET | `/health` | detailed health |
| GET | `/metrics` | runtime metrics |
| GET | `/manager/version` | running version string |
| GET | `/manager/logs` | recent manager logs |
| POST | `/manager/update` | self-update: `?target_version=latest` — downloads, sha-verifies, atomic-renames, exits for supervisor respawn |
| POST | `/manager/cleanup` | housekeeping |
| GET | `/skills` | list skills bundled on the manager |
| GET | `/skills/{skill_name}` | download one |
| GET | `/openapi.json` | machine-readable spec (see gap note above) |
| GET | `/llm.txt` / `/llm-cli.txt` | agent orientation files |

## terminal

| Method | Route | Body / params |
|---|---|---|
| POST | `/execute` | `{command*, cwd, timeout, session_id, environment{k:v}}` — with `session_id`, shell state (env, cwd) persists across calls |
| GET | `/sessions` | list persistent sessions |
| DELETE | `/sessions/{session_id}` | terminate one |

## files

Also served standalone on port **8081** (file server), same shapes.

| Method | Route | Body / params |
|---|---|---|
| POST | `/files/upload` | query `path`, `overwrite`; body `multipart/form-data` field `file` |
| GET | `/files/download` | query `path*` — streams the file |
| GET | `/files/list` | query `path` |

## RPA — act

All POST bodies are `application/json`.

| Route | Body |
|---|---|
| `/rpa/click` | `{x*, y*, button: left\|right\|middle, clicks}` |
| `/rpa/doubleclick` | `{x*, y*}` |
| `/rpa/rightclick` | `{x*, y*}` |
| `/rpa/move` | `{x*, y*}` |
| `/rpa/drag` | `{...}` start/end coordinates |
| `/rpa/scroll` | direction + amount |
| `/rpa/type` | `{text*, interval}` (seconds between keystrokes) |
| `/rpa/key` | single key press |
| `/rpa/hotkey` | key combination |
| `/rpa/screenshot` | POST, returns PNG |
| `/rpa/ocr` | `{region, lang}` — tesseract text extraction |
| `/rpa/find-image` | `{template, confidence, grayscale}` — locate template on screen |
| `/rpa/wait-for-image` | template + timeout — block until visible |
| `/rpa/computer-use` | `{action*, coordinate, start_coordinate, text, scroll_direction, scroll_amount, duration, region}` — Anthropic computer-use tool schema passthrough |
| `/rpa/agent` | `{task*, model, max_steps, system_prompt}` — server-side screenshot→model→action loop; needs an Anthropic key supplied per-run |
| GET `/rpa/clipboard` | read clipboard |
| POST `/rpa/clipboard` | set clipboard |
| GET `/rpa/mouse-position` | current pointer |
| GET `/rpa/screen-size` | display geometry |
| GET `/rpa/health` | RPA tooling availability (xdotool/scrot/etc.) |

`/rpa/health` is the first call to make when act verbs misbehave — it
reports which underlying tools are missing.

## awareness — observe

| Method | Route | Notes |
|---|---|---|
| GET | `/awareness/snapshot` | full desktop state now |
| GET | `/awareness/diff?since=<ref>` | changes since a snapshot |
| GET | `/awareness/digest` | compact rolling digest |
| GET | `/awareness/watch` | change stream |
| GET | `/awareness/windows` | window list |
| GET | `/awareness/window-catalog` | per-window detail (class/title/geometry) |
| GET | `/awareness/pointer` | pointer position/state |
| GET | `/awareness/regions` | screen regions |
| POST | `/awareness/fs/watch` | `{paths:[...]}` — start watching paths |
| GET | `/awareness/fs/list` | active watches |
| GET | `/awareness/fs/state` | accumulated fs changes |
| GET | `/awareness/ring/dump` | event ring buffer dump |

Workflow steps can call these natively:
`{"verb":"call","method":"GET","path":"/awareness/snapshot","save_as":"snap"}`.

## window management

| Method | Route | Notes |
|---|---|---|
| POST | `/window/focus` | target by handle/title |
| POST | `/window/raise` | raise without focus |
| POST | `/window/move` | reposition |
| POST | `/window/resize` | resize |
| POST | `/window/tile` | tile to a geometry |
| POST | `/window/tile-preset` | named layout presets |
| POST | `/window/move-to-desktop` | send to a virtual desktop |
| POST | `/window/close` | close window |
| POST | `/window/screenshot` | capture ONE window (vs `/rpa/screenshot` = whole screen) |

## virtual desktops

| Method | Route |
|---|---|
| GET | `/desktop/count` |
| GET | `/desktop/current` |
| POST | `/desktop/next` |
| POST | `/desktop/prev` |
| POST | `/desktop/set` |

## workflows

| Method | Route | Notes |
|---|---|---|
| POST | `/workflow/execute` | `{workflow_id OR workflow (inline), variables{k:v}, async_execution, timeout, encrypted}` |
| GET | `/workflow/status/{workflow_id}` | definition status |
| GET | `/workflow/executions/{execution_id}` | run status |
| GET | `/workflow/executions/{execution_id}/logs` | run logs |
| POST | `/workflow/executions/{execution_id}/cancel` | stop a run |
| GET | `/workflow/history` | past runs |
| GET | `/workflow/health` | engine health |

Runs execute on the manager and survive caller disconnects — re-attach
via `/workflow/history` → `/workflow/executions/{id}`.
