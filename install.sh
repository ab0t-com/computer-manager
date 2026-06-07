#!/usr/bin/env sh
# =============================================================================
# computer-manager installer (public GitHub release)
# =============================================================================
#
# Downloads the `computer-manager` binary from this GitHub repo's raw content
# and installs it, verifying the published sha256 before touching anything.
#
# computer-manager is the SERVER half of the computer-agent pair: it runs ON
# the machine you want controlled (GUI desktop or headless sandbox) and
# exposes the HTTP control surface that the `computer-agent` CLI drives.
#
# What it does:
#   1. Detects host OS + arch. (Only linux-amd64 is published today; it fails
#      clearly on anything else rather than installing the wrong thing.)
#   2. Downloads release/checksums.txt, then release/computer-manager, over HTTPS.
#   3. Verifies the binary against the published sha256 — mandatory.
#   4. Atomically installs to $PREFIX/bin/computer-manager
#      (default /usr/local/bin), keeping the prior binary as `.previous`.
#   5. Confirms with `computer-manager --version`.
#   6. Best-effort: installs the `desktop` perception sidecar the same way
#      (observe/find/wait/diff over X11 + AT-SPI — the documented
#      `computer-agent exec "desktop ..."` surface). Verified against the
#      same checksums.txt; a missing sidecar is a warn + skip, never a fail.
#      Skip it entirely with SKIP_DESKTOP=1.
#
# Properties (compliance):
#   - POSIX sh; runs under /bin/sh on Linux/macOS/busybox.
#   - HTTPS only — TLS verification ALWAYS on (`-k`/`--insecure` never used).
#   - sha256 verification is mandatory; refuses to install on mismatch or a
#     missing checksums.txt.
#   - No destructive operations: never `rm -rf`, never deletes user data,
#     only writes the install dir + a temp dir it creates and cleans up.
#   - Atomic install via `install`/`mv` of a fully-verified tempfile.
#   - Idempotent: re-running upgrades/downgrades; same version = no-op exit 0.
#   - Rollback: keeps one `.previous`. No telemetry, no analytics.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ab0t-com/computer-manager/main/install.sh | sh
#
# Pin a git ref (tag/branch/sha) or version, change install dir, or point at a
# fork:
#   REF=v0.1.0   curl -fsSL .../install.sh | sh
#   PREFIX=$HOME/.local curl -fsSL .../install.sh | sh
#   REPO=myfork/computer-manager curl -fsSL .../install.sh | sh
#
# After install (minimal run — see docs/USAGE.md for the full picture):
#   MANAGER_API_TOKEN=$(openssl rand -hex 32) computer-manager
#
# Exit codes: 0 installed/up-to-date · 1 user error · 2 internal error.
# =============================================================================

set -eu

# ----- knobs ----------------------------------------------------------------
NAME="computer-manager"
# GitHub "owner/repo". The org is `ab0t-com`. Override REPO=... for a fork.
REPO="${REPO:-ab0t-com/computer-manager}"
REF="${REF:-main}"                       # git ref the raw content is served from
BASE_URL="${BASE_URL:-https://raw.githubusercontent.com/${REPO}/${REF}}"
PREFIX="${PREFIX:-/usr/local}"
INSTALL_PATH="${INSTALL_PATH:-${PREFIX}/bin/${NAME}}"

# ----- pretty print ---------------------------------------------------------
RED=""; GREEN=""; YELLOW=""; BOLD=""; RESET=""
if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
    if [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
        RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"
        BOLD="$(tput bold)"; RESET="$(tput sgr0)"
    fi
fi
info() { printf "%s→%s %s\n" "$BOLD" "$RESET" "$*"; }
ok()   { printf "%s✓%s %s\n" "$GREEN" "$RESET" "$*"; }
warn() { printf "%s!%s %s\n" "$YELLOW" "$RESET" "$*" >&2; }
fail() { printf "%s✗%s %s\n" "$RED"   "$RESET" "$*" >&2; exit 1; }

# ----- prerequisites --------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || fail "required tool missing: $1"; }
need uname
need curl
need mktemp
if   command -v sha256sum >/dev/null 2>&1; then SHA256_CMD="sha256sum"
elif command -v shasum    >/dev/null 2>&1; then SHA256_CMD="shasum -a 256"
elif command -v openssl   >/dev/null 2>&1; then SHA256_CMD="openssl_sha256"
else fail "no sha256 tool found (need one of: sha256sum, shasum, openssl)"
fi
sha256_of() {
    case "$SHA256_CMD" in
        openssl_sha256) openssl dgst -sha256 "$1" | awk '{print $NF}' ;;
        *)              $SHA256_CMD "$1" | awk '{print $1}' ;;
    esac
}

# ----- detect OS + arch -----------------------------------------------------
case "$(uname -s)" in
    Linux*)  OS="linux"  ;;
    Darwin*) OS="darwin" ;;
    *) fail "unsupported OS: $(uname -s) — only linux is published today" ;;
esac
case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    *) fail "unsupported architecture: $(uname -m) — only amd64 is published today" ;;
esac
# The public repo currently ships ONLY linux-amd64. Be explicit rather than
# silently install a mismatched binary.
if [ "$OS" != "linux" ] || [ "$ARCH" != "amd64" ]; then
    fail "no published binary for ${OS}-${ARCH} yet"
fi

info "Repo:         ${BOLD}${REPO}${RESET} @ ${REF}"
info "Install path: ${BOLD}${INSTALL_PATH}${RESET}"

# ----- resolve published version -------------------------------------------
PUBLISHED="$(curl --proto '=https' --tlsv1.2 -fsSL --max-time 15 \
    "${BASE_URL}/release/VERSION" 2>/dev/null | tr -d '\r\n[:space:]' || true)"
[ -n "$PUBLISHED" ] && info "Published version: ${BOLD}${PUBLISHED}${RESET}"

# ----- short-circuit if already at the published version --------------------
if [ -n "$PUBLISHED" ] && [ -x "${INSTALL_PATH}" ]; then
    CURRENT="$("${INSTALL_PATH}" --version 2>/dev/null | head -1 | awk '{print $NF}' | tr -d '[:space:]' || true)"
    if [ -n "$CURRENT" ] && [ "$CURRENT" = "$PUBLISHED" ]; then
        ok "${NAME} ${PUBLISHED} already installed at ${INSTALL_PATH} — nothing to do."
        exit 0
    fi
    [ -n "$CURRENT" ] && info "Currently installed: ${CURRENT} → updating to ${PUBLISHED}"
fi

# ----- working dir (we own it — safe to clean up) ---------------------------
WORKDIR="$(mktemp -d 2>/dev/null || mktemp -d -t 'computer-manager-install')"
[ -d "$WORKDIR" ] || fail "could not create temp dir"
cleanup() { rm -rf -- "$WORKDIR"; }
trap cleanup EXIT INT HUP TERM
BIN_TMP="${WORKDIR}/${NAME}"
SUMS_TMP="${WORKDIR}/checksums.txt"

# ----- download checksums first --------------------------------------------
info "Fetching release/checksums.txt"
curl --proto '=https' --tlsv1.2 -fsSL --max-time 60 --output "$SUMS_TMP" \
    "${BASE_URL}/release/checksums.txt" \
    || fail "could not fetch checksums.txt — refusing to install without verification"
[ -s "$SUMS_TMP" ] || fail "checksums.txt is empty — refusing to install"

# The published checksums.txt is a single sha256sum line: "<hash>  computer-manager"
EXPECTED_HASH="$(awk '$2 == "computer-manager" || $2 == "*computer-manager" { print $1; exit }' "$SUMS_TMP" | tr -d '[:space:]')"
[ -n "$EXPECTED_HASH" ] || fail "no checksum entry for computer-manager in checksums.txt"
case "$EXPECTED_HASH" in *[!a-fA-F0-9]*) fail "checksum entry is malformed" ;; esac
[ "${#EXPECTED_HASH}" -eq 64 ] || fail "checksum is not 64 hex chars"

# ----- download the binary --------------------------------------------------
URL="${BASE_URL}/release/computer-manager"
info "Downloading ${URL}"
curl --proto '=https' --tlsv1.2 -fsSL --max-time 300 --output "$BIN_TMP" "$URL" \
    || fail "download failed"
[ -s "$BIN_TMP" ] || fail "downloaded file is empty"

# ----- verify ---------------------------------------------------------------
info "Verifying sha256"
ACTUAL_HASH="$(sha256_of "$BIN_TMP")"
[ "$ACTUAL_HASH" = "$EXPECTED_HASH" ] \
    || fail "checksum mismatch — expected ${EXPECTED_HASH}, got ${ACTUAL_HASH}. Aborting (no install performed)."
ok "Checksum verified"
chmod 0755 "$BIN_TMP"

# ----- install (atomic, with rollback) --------------------------------------
DEST="${INSTALL_PATH}"
DEST_DIR="$(dirname "$DEST")"
PREV="${DEST}.previous"

SUDO=""
if ! mkdir -p "$DEST_DIR" 2>/dev/null; then
    if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; info "Creating ${DEST_DIR} (sudo)"; sudo mkdir -p "$DEST_DIR" || fail "cannot create ${DEST_DIR}"
    else fail "cannot create ${DEST_DIR} and sudo is unavailable"; fi
elif [ ! -w "$DEST_DIR" ]; then
    if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; info "Installing to ${DEST_DIR} requires sudo"
    else fail "${DEST_DIR} is not writable and sudo is unavailable"; fi
fi

# Snapshot the current binary for one-step rollback. We never delete it.
if [ -e "$DEST" ]; then
    info "Saving current binary as ${PREV}"
    $SUDO mv -f "$DEST" "$PREV" || fail "could not snapshot existing binary"
fi

info "Installing ${NAME} → ${DEST}"
if command -v install >/dev/null 2>&1; then
    $SUDO install -m 0755 "$BIN_TMP" "$DEST" || fail "install failed"
else
    $SUDO mv -f "$BIN_TMP" "$DEST" || fail "install failed"
    $SUDO chmod 0755 "$DEST"
fi

# ----- post-install sanity --------------------------------------------------
if "$DEST" --version >/dev/null 2>&1; then
    ok "Installed: $("$DEST" --version 2>/dev/null | head -1)"
else
    warn "Installed binary did not respond to --version. Roll back with:"
    warn "  ${SUDO} mv -f \"${PREV}\" \"${DEST}\""
fi

# ----- desktop sidecar (best-effort, never fatal) ----------------------------
# The `desktop` CLI is the perception half of the surface: catalog/query/
# await/watch/diff over X11 + AT-SPI. Agents call it by name via
# `computer-agent exec "desktop -mode catalog"`, so it installs next to the
# manager. Optional: a headless box with no X may not want it, and an absent
# published sidecar must never block a manager install.
if [ "${SKIP_DESKTOP:-0}" != "1" ]; then
    DD_EXPECTED="$(awk '$2 == "desktop" || $2 == "*desktop" { print $1; exit }' "$SUMS_TMP" | tr -d '[:space:]')"
    if [ -z "$DD_EXPECTED" ]; then
        warn "no checksum entry for the desktop sidecar — skipping it (manager installed fine)"
    else
        DD_TMP="${WORKDIR}/desktop"
        DD_DEST="${DEST_DIR}/desktop"
        DD_PREV="${DD_DEST}.previous"
        info "Downloading ${BASE_URL}/release/desktop (perception sidecar)"
        if curl --proto '=https' --tlsv1.2 -fsSL --max-time 300 --output "$DD_TMP" \
                "${BASE_URL}/release/desktop" && [ -s "$DD_TMP" ]; then
            DD_ACTUAL="$(sha256_of "$DD_TMP")"
            if [ "$DD_ACTUAL" = "$DD_EXPECTED" ]; then
                ok "Sidecar checksum verified"
                chmod 0755 "$DD_TMP"
                if [ -e "$DD_DEST" ]; then
                    $SUDO mv -f "$DD_DEST" "$DD_PREV" || warn "could not snapshot existing desktop binary"
                fi
                if command -v install >/dev/null 2>&1; then
                    $SUDO install -m 0755 "$DD_TMP" "$DD_DEST" && ok "Installed sidecar: ${DD_DEST}" \
                        || warn "desktop sidecar install failed — manager is unaffected"
                else
                    $SUDO mv -f "$DD_TMP" "$DD_DEST" && $SUDO chmod 0755 "$DD_DEST" \
                        && ok "Installed sidecar: ${DD_DEST}" \
                        || warn "desktop sidecar install failed — manager is unaffected"
                fi
            else
                # A bad sidecar checksum is a hard fail: something is wrong with
                # the release content, and we will not install unverified bits.
                fail "desktop sidecar checksum mismatch — expected ${DD_EXPECTED}, got ${DD_ACTUAL}"
            fi
        else
            warn "desktop sidecar not downloadable — skipping (manager installed fine)"
        fi
    fi
fi

# ----- PATH guidance --------------------------------------------------------
case ":$PATH:" in
    *":${DEST_DIR}:"*) ;;
    *) warn "${DEST_DIR} is not in your \$PATH. Add it:"; warn "  echo 'export PATH=\"${DEST_DIR}:\$PATH\"' >> ~/.profile" ;;
esac

cat <<EOF

${BOLD}Done.${RESET} ${NAME} is installed at ${DEST}.
  Start it:  ${BOLD}MANAGER_API_TOKEN=\$(openssl rand -hex 32) ${NAME}${RESET}
  Then point the ${BOLD}computer-agent${RESET} CLI at http://<this-host>:1337 with that token.
  Update by re-running this installer; the previous binary is kept at
  ${PREV} for rollback:  ${SUDO} mv -f "${PREV}" "${DEST}"
EOF
exit 0
