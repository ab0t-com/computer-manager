#!/usr/bin/env sh
# =============================================================================
# computer-manager bootstrap — install AND run as a managed service
# =============================================================================
#
# install.sh only INSTALLS the binary. This wrapper adds the platform glue so
# the manager comes up and stays up, configured from the environment:
#   1. installs the binary via install.sh (public GitHub; verified sha256)
#   2. writes a root-only env-file from the metadata env vars below
#   3. installs a service (systemd if present, else a nohup supervisor loop)
#   4. starts it and smoke-tests GET /ping
#
# It is environment-agnostic: EC2 user-data, a plain VM, a container, or a
# laptop. The ONLY thing it needs that is not public is the per-instance
# METADATA, passed as environment variables (the universal contract):
#
#   MANAGER_API_TOKEN              (required) bearer token the manager enforces.
#                                  If unset, a strong one is generated + printed.
#   MANAGER_API_PORT              (default 1337) main API port.
#   WORKSPACE_DIR                (default /workspace)
#   ENABLE_FILE_SERVER           (default true) second listener on :8081.
#   DISPLAY                      (optional) X display for GUI/RPA verbs.
#   RESOURCE_SERVICE_CALLBACK_URL   (optional) phone-home target; the manager
#   RESOURCE_SERVICE_CALLBACK_TOKEN  registers itself here in-process on boot.
#   CONTROLLER_API_KEY           (optional) proxy-controller self-register key.
#   ALLOCATION_ID                (optional) id used in phone-home/registration.
#   REF / PREFIX / REPO          (optional) passed through to install.sh.
#
# Usage:
#   # laptop / VM (interactive):
#   curl -fsSL https://raw.githubusercontent.com/ab0t-com/computer-manager/main/bootstrap.sh \
#     | MANAGER_API_TOKEN=$(openssl rand -hex 32) sh
#
#   # EC2 user-data / automation: export the metadata env then pipe to sh.
#
# Properties: POSIX sh; HTTPS-only; reuses install.sh's mandatory sha256 verify;
# idempotent (re-run upgrades the binary + restarts the service); no telemetry.
# =============================================================================

set -eu

REPO="${REPO:-ab0t-com/computer-manager}"
REF="${REF:-main}"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/${REF}"
PREFIX="${PREFIX:-/usr/local}"
BIN="${PREFIX}/bin/computer-manager"
ENV_FILE="${ENV_FILE:-/etc/computer-manager.env}"

MANAGER_API_PORT="${MANAGER_API_PORT:-1337}"
WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
ENABLE_FILE_SERVER="${ENABLE_FILE_SERVER:-true}"

log()  { printf '[bootstrap] %s\n' "$*"; }
die()  { printf '[bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }

# Need root to install a service + write /etc.
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "must run as root (or have sudo)"
    SUDO="sudo"
fi

# ----- 1. install the binary (public, sha256-verified by install.sh) ---------
log "installing computer-manager binary via install.sh (${REPO}@${REF})"
REPO="$REPO" REF="$REF" PREFIX="$PREFIX" \
    sh -c "curl -fsSL '${RAW_BASE}/install.sh' | sh" \
    || die "install.sh failed"
[ -x "$BIN" ] || die "binary not found at $BIN after install"

# ----- 2. resolve / generate the token, write the env-file -------------------
if [ -z "${MANAGER_API_TOKEN:-}" ]; then
    if command -v openssl >/dev/null 2>&1; then
        MANAGER_API_TOKEN="$(openssl rand -hex 32)"
    else
        MANAGER_API_TOKEN="$(head -c32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    fi
    log "no MANAGER_API_TOKEN supplied — generated one:"
    log "  MANAGER_API_TOKEN=${MANAGER_API_TOKEN}"
fi

log "writing ${ENV_FILE} (root-only)"
TMP_ENV="$(mktemp)"
{
    printf 'MANAGER_API_TOKEN=%s\n' "$MANAGER_API_TOKEN"
    printf 'MANAGER_API_PORT=%s\n' "$MANAGER_API_PORT"
    printf 'WORKSPACE_DIR=%s\n' "$WORKSPACE_DIR"
    printf 'ENABLE_FILE_SERVER=%s\n' "$ENABLE_FILE_SERVER"
    [ -n "${DISPLAY:-}" ]                         && printf 'DISPLAY=%s\n' "$DISPLAY"
    [ -n "${ALLOCATION_ID:-}" ]                   && printf 'ALLOCATION_ID=%s\n' "$ALLOCATION_ID"
    [ -n "${RESOURCE_SERVICE_CALLBACK_URL:-}" ]   && printf 'RESOURCE_SERVICE_CALLBACK_URL=%s\n' "$RESOURCE_SERVICE_CALLBACK_URL"
    [ -n "${RESOURCE_SERVICE_CALLBACK_TOKEN:-}" ] && printf 'RESOURCE_SERVICE_CALLBACK_TOKEN=%s\n' "$RESOURCE_SERVICE_CALLBACK_TOKEN"
    [ -n "${CONTROLLER_API_KEY:-}" ]              && printf 'CONTROLLER_API_KEY=%s\n' "$CONTROLLER_API_KEY"
} > "$TMP_ENV"
$SUDO install -m 0600 "$TMP_ENV" "$ENV_FILE"
rm -f "$TMP_ENV"

$SUDO mkdir -p "$WORKSPACE_DIR" 2>/dev/null || true

# ----- 3 + 4. install a service, start it, smoke-test ------------------------
start_systemd() {
    log "installing systemd unit computer-manager.service"
    UNIT="$(mktemp)"
    cat > "$UNIT" <<EOF
[Unit]
Description=computer-manager control surface
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=${ENV_FILE}
ExecStart=${BIN}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
    $SUDO install -m 0644 "$UNIT" /etc/systemd/system/computer-manager.service
    rm -f "$UNIT"
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable computer-manager >/dev/null 2>&1 || true
    $SUDO systemctl restart computer-manager
}

start_nohup() {
    log "no systemd — starting a nohup supervisor loop"
    LOOP="${PREFIX}/bin/computer-manager-run"
    RUN="$(mktemp)"
    cat > "$RUN" <<EOF
#!/bin/sh
set -a; . ${ENV_FILE}; set +a
while true; do ${BIN}; sleep 2; done
EOF
    $SUDO install -m 0755 "$RUN" "$LOOP"; rm -f "$RUN"
    $SUDO sh -c "setsid '$LOOP' >/var/log/computer-manager.log 2>&1 &" || \
        $SUDO sh -c "nohup '$LOOP' >/var/log/computer-manager.log 2>&1 &"
}

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    start_systemd
else
    start_nohup
fi

log "waiting for the manager to answer /ping on :${MANAGER_API_PORT}"
i=0
while [ "$i" -lt 30 ]; do
    if curl -fsS --max-time 2 "http://127.0.0.1:${MANAGER_API_PORT}/ping" >/dev/null 2>&1; then
        log "computer-manager is up on :${MANAGER_API_PORT} ✓"
        exit 0
    fi
    i=$((i + 1)); sleep 1
done
die "manager did not answer /ping within 30s — check: journalctl -u computer-manager  OR  /var/log/computer-manager.log"
