# desktop — the perception sidecar CLI, in full

Standalone control surface over X11 + AT-SPI, installed next to the
manager as `desktop`. It answers OBSERVE questions; acting belongs to the
manager's `/rpa/*` endpoints. The agent loop it serves:

```
observe → find → wait → act → diff
catalog    query   await   (RPA)   diff/digest/watch
```

Invocation: `desktop -mode <mode> [flags]` — locally on the box, or
remotely via the manager: `computer-agent exec "desktop -mode ... -json"`
(or `POST /execute`).

## Contract (script against this, not prose)

- **Exit codes:** `0` ok · `2` bad-input/no-mode · `3` no-display ·
  `4` not-built-with-atspi · `5` no-match/timeout. **Branch on `$?`,
  never parse stderr text.**
- **Errors:** single-line `{"error":"...","kind":"..."}` JSON envelope on
  stderr; stdout stays clean JSON on success.
- Display: `-display :N` flag or `DISPLAY` env. Modes marked *atspi*
  need the AT-SPI build (exit 4 otherwise).

## The 8 modes

### catalog — "what windows exist right now?"

Lists handle/class/title + active desktop + focused window.

```sh
desktop -mode catalog -json | jq '.windows[].title'
```
Flags: `-display`, `-json`.

### watch — "what is changing? (raw firehose)"

Streams every Change as JSON lines until `-timeout`. Prefer `await` when
you know WHAT you're waiting for.

```sh
desktop -mode watch -timeout 15s
```
Flags: `-display`, `-timeout`.

### await — "block until X happens, then return"

Predicate from `-kind/-title/-class/-handle/-pid/-path`; emits matching
Change(s); exit 0 on match, 5 on timeout. Replaces poll-and-parse loops.

```sh
# a "Save As" dialog appears:
desktop -mode await -kind window_created -title "Save As" -timeout 30s
# burst trigger — ≥3 fs changes within 10s (busy build):
desktop -mode await -kind fs_changed -burst 3/10s -timeout 60s
# ordered sequence:
desktop -mode await -seq "window_created;title_changed:Saved" -timeout 30s
```
Flags: `-kind`, `-title`, `-class`, `-handle`, `-pid`, `-path`,
`-timeout`, `-seq`, `-burst`.

### query — "where is the element? (click-ready bbox)" *(atspi)*

Finds a11y-tree nodes without dumping the whole tree. Output
`[]QueryResult{path,node}`, node carries bbox. Exit 5 on zero matches.

```sh
# the Save button's bbox → click its center via /rpa/click:
desktop -mode query -handle gedit -role push-button -name Save --json
# everything clickable in a window:
desktop -mode query -handle firefox -interactable --json
```
Flags: `-handle`, `-role`, `-name`, `-interactable`, `-first`, `--json`.

### digest — "rolling state file on MY clock"

Detached sink writes a compact CatalogDigest JSON to `-out` atomically
every `-interval` — the universal watch-queue. An agent reads the file
across many short execs without holding a stream open. Runs until killed
(`-timeout 0` = forever).

```sh
desktop -mode digest -out /tmp/desk.json -interval 2s -timeout 5m &
# later, on your own cadence:
cat /tmp/desk.json
```
Flags: `-display`, `-out`, `-interval`, `-timeout`.

### diff — "did my action change anything?"

Snapshots now, waits `-since`, emits only the `[]Change` delta. With
`-handle` *(atspi)* diffs the a11y TREE instead
(`{added,removed,modified,bbox_only}` + summary).

```sh
desktop -mode diff -since 3s                       # window-level delta
desktop -mode diff -handle gedit -since 2s --json  # UI-tree delta
```
Flags: `-display`, `-since`, `-handle`, `-json`.

### screenshot — "what does the screen look like?"

Raw PNG to stdout.

```sh
desktop -mode screenshot > /tmp/screen.png
computer-agent exec "desktop -mode screenshot" > /tmp/screen.png
```
Flags: `-display`.

### atspi-tree — "the accessible UI structure of an app" *(atspi)*

Dumps the AT-SPI tree for the `-handle` window. Use compression flags to
keep big trees (browsers) agent-consumable.

```sh
desktop -mode atspi-tree -handle gedit
# bound a huge browser tree: 8 levels, 20 KiB, drop unnamed chrome:
desktop -mode atspi-tree -handle firefox -max-depth 8 -max-bytes 20000 -drop-decorative --json
```
Flags: `-display`, `-handle`, `-json`, `-bbox`, `-subscribe`,
`-max-depth`, `-max-bytes`, `-drop-decorative`.

## Patterns

**Find → act → verify** (the core advanced-control loop):

```sh
BBOX=$(desktop -mode query -handle gedit -name Save -first --json)   # observe
# compute center from bbox, then act via the manager:
curl -s -H "$H" -X POST $B/rpa/click -d "{\"x\":$CX,\"y\":$CY}"
desktop -mode diff -handle gedit -since 2s --json                    # verify
```

**Act → await-effect → act** (no sleep-and-hope):

```sh
curl -s -H "$H" -X POST $B/rpa/hotkey -d '{"keys":["ctrl","shift","s"]}'
desktop -mode await -kind window_created -title "Save As" -timeout 10s || exit 1
```

**Long-running observation without a stream** — `digest` to a file,
read it between actions; survives across separate `/execute` calls.

## Gotchas

- `exec "desktop ..."` not found → the binary isn't on the exec PATH;
  symlink it into `/usr/local/bin` (see the host-setup skill).
- Exit 3 → no display: set `-display`/`DISPLAY`, confirm X/Xvfb is up.
- Exit 4 → this build lacks AT-SPI; `query`/`atspi-tree`/tree-diff
  unavailable. Window-level modes still work.
- Qt/GTK apps can expose empty trees if AT-SPI registry isn't running on
  the session — window-level awareness (`catalog`/`await`) still works.
