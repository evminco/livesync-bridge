#!/usr/bin/env bash
set -euo pipefail

LOG="/home/azure/livesync-bridge/watchdog/watchdog.log"
VAULT="/home/azure/.openclaw/workspace/memory/obsidian"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CANARY_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
CANARY_REL="03 Resources/800 - Tech/200 - OpenClaw/canaries/livesync-bridge-canary-${CANARY_STAMP}.txt"
CANARY="$VAULT/$CANARY_REL"
SINCE="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

mkdir -p "$(dirname "$LOG")" "$(dirname "$CANARY")"

cleanup() {
  rm -f -- "$CANARY"
}
trap cleanup EXIT

log() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" >> "$LOG"
}

fail() {
  log "FAIL: $*"
  exit 1
}

if ! systemctl --user is-active --quiet livesync-bridge.service; then
  fail "livesync-bridge.service is not active under user systemd"
fi

cat > "$CANARY" <<EOF
LiveSync Bridge Canary
Updated: $NOW_ISO
Purpose: temporary sync-health canary maintained by livesync-bridge watchdog.
EOF

for _ in $(seq 1 12); do
  if journalctl --user -u livesync-bridge.service --since "$SINCE" --no-pager | grep -Fq "PUT: DONE: $CANARY_REL"; then
    log "OK: Canary upload observed — user service active and local→remote sync healthy"
    exit 0
  fi
  if journalctl --user -u livesync-bridge.service --since "$SINCE" --no-pager | grep -Eq 'error: Uncaught|Main process exited|Failed with result'; then
    fail "bridge emitted crash/failure logs after watchdog canary write"
  fi
  sleep 5
done

fail "canary upload not observed within 60s: $CANARY_REL"
