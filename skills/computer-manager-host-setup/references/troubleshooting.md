# computer-manager — troubleshooting

Failure modes by symptom. Work top to bottom inside a section; each fix
is ordered most-likely-first.

## Contents

- [Connection refused / timeout on :1337](#connection-refused--timeout-on-1337)
- [401 Unauthorized](#401-unauthorized)
- [Manager exits immediately on start](#manager-exits-immediately-on-start)
- [GUI verbs return empty / zero-byte screenshot](#gui-verbs-return-empty--zero-byte-screenshot)
- [OCR / find-image / clipboard verbs fail](#ocr--find-image--clipboard-verbs-fail)
- [`desktop` sidecar: command not found](#desktop-sidecar-command-not-found)
- [Installer failures](#installer-failures)
- [Bad update — rolling back](#bad-update--rolling-back)

## Connection refused / timeout on :1337

1. Is it running? `pgrep -af computer-manager` (binary may also show as
   `manager`). Not running → see [Manager exits immediately](#manager-exits-immediately-on-start).
2. Listening? `ss -tlnp | grep 1337`. Bound to `127.0.0.1` only → a proxy
   is expected in front; hit the proxy, or rebind.
3. Firewall: `iptables -L -n | grep 1337` / cloud security-group rules.
   The controller's source IP must be allowed.
4. Timeout (vs refused) usually = firewall drop or wrong host/IP, not the
   manager.

## 401 Unauthorized

1. Header shape must be exactly `Authorization: Bearer <token>`.
2. Token mismatch after a restart — the service may have regenerated or
   loaded a different env file. Compare the token the process actually
   has: `cat /proc/$(pgrep -f computer-manager | head -1)/environ | tr '\0' '\n' | grep MANAGER_API_TOKEN`.
3. Controller side: `SANDBOX_TOKEN` env overrides alias-stored tokens in
   computer-agent — unset it or pass `--token` explicitly.

## Manager exits immediately on start

1. **No token.** `MANAGER_API_TOKEN` is mandatory — no token, no boot.
   Run it foreground once to see the message.
2. **Port taken.** Another manager (or anything) on 1337:
   `ss -tlnp | grep 1337`, kill the squatter or move one of them.
3. **systemd loop-crashing:** `journalctl -u computer-manager -n 50` —
   usually a missing/garbled `/etc/computer-manager.env` (must be
   `MANAGER_API_TOKEN=<value>`, no quotes needed, file mode 600).

## GUI verbs return empty / zero-byte screenshot

Terminal verbs work, GUI verbs don't = the manager has no usable display.

1. Was it started with `DISPLAY` set? Check the process env (see 401 §2,
   grep `DISPLAY`). No → restart with `DISPLAY=:0` (real desktop) or
   `DISPLAY=:1` (Xvfb).
2. Is the X server actually up? `xdpyinfo -display :1 >/dev/null && echo OK`.
   For headless: `Xvfb :1 -screen 0 1920x1080x24 &` must be running and
   must survive reboots (add to the same systemd unit or supervisor).
3. `scrot` installed? Screenshot shells out to it — `command -v scrot`.
4. Permission: the manager must run as the user owning the X session
   (or have xhost access).

## OCR / find-image / clipboard verbs fail

Missing RPA tooling. The verbs shell out:

| Verb family | Needs |
|---|---|
| screenshot | `scrot` |
| mouse/keyboard | `xdotool` |
| clipboard | `xclip` |
| OCR | `tesseract` (package `tesseract-ocr`) |

`apt install -y xdotool scrot xclip tesseract-ocr` (alpine: `apk add`;
rhel: `dnf install`). Then retry — no manager restart needed.

## `desktop` sidecar: command not found

`computer-agent exec "desktop -mode catalog"` fails by name:

1. Installed at all? Installer may have skipped it (`SKIP_DESKTOP=1`, or
   download failure → it warns and continues). Check
   `ls -la /usr/local/bin/desktop ~/.local/bin/desktop 2>/dev/null`.
2. Installed but not on the EXEC path — `exec` runs a non-login shell
   whose PATH may exclude `~/.local/bin`. Fix with a symlink into a
   universal dir: `ln -s ~/.local/bin/desktop /usr/local/bin/desktop`.
3. Reinstall just the sidecar: re-run the installer (idempotent; manager
   untouched if same version).

## Installer failures

| Message | Meaning / fix |
|---|---|
| `checksum mismatch — … Aborting` | Download corrupted or release tampered. Re-run once (transient network); persists → STOP and verify the repo/ref you're pulling from. Never bypass. |
| `no checksum entry for computer-manager` | You're pointing at a ref without release files — set `REF=` to a real tag or `main`. |
| `unsupported architecture` | Only linux-amd64 is published today. Build from source or run an amd64 host. |
| `cannot create … and sudo is unavailable` | Use `PREFIX=$HOME/.local` for a user-level install. |
| `desktop sidecar not downloadable — skipping` | Non-fatal by design; manager is fine. Install the sidecar later if needed. |

## Bad update — rolling back

The installer keeps exactly one previous version beside each binary:

```sh
mv -f /usr/local/bin/computer-manager.previous /usr/local/bin/computer-manager
mv -f /usr/local/bin/desktop.previous /usr/local/bin/desktop   # if needed
systemctl restart computer-manager    # or kill the PID; supervisor respawns
computer-manager --version            # confirm the rolled-back version
```

Then pin the known-good tag on future installs: `REF=v<good> curl … | sh`.
