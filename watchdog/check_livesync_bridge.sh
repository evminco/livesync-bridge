#!/usr/bin/env bash
set -euo pipefail

LOG="/home/azure/livesync-bridge/watchdog/watchdog.log"
VAULT="/home/azure/.openclaw/workspace/memory/obsidian"
STATE_DIR="/home/azure/livesync-bridge/watchdog/state"
PENDING_FILE="$STATE_DIR/pending-canaries.txt"
QUARANTINE_FILE="$STATE_DIR/quarantined-canaries.txt"
LOCK_FILE="$STATE_DIR/watchdog.lock"
CANARY_DIR_REL="03 Resources/800 - Tech/200 - OpenClaw/canaries"
UPLOAD_TIMEOUT_SECONDS=60
DELETE_TIMEOUT_SECONDS=60
SETTLE_SECONDS=10
ACTIVE_CANARY=""
BRIDGE_RESTART_USED=false

mkdir -p "$(dirname "$LOG")" "$STATE_DIR" "$VAULT/$CANARY_DIR_REL"
touch "$PENDING_FILE" "$QUARANTINE_FILE"

log() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" >> "$LOG"
}

fail() {
  log "FAIL: $*"
  exit 1
}

cleanup_local() {
  if [[ -n "$ACTIVE_CANARY" ]]; then
    rm -f -- "$ACTIVE_CANARY"
  fi
}
trap cleanup_local EXIT

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  fail "another watchdog invocation is already running"
fi

if ! systemctl --user is-active --quiet livesync-bridge.service; then
  fail "livesync-bridge.service is not active under user systemd"
fi

# A quarantine is a circuit breaker. Do not create more canaries while a prior
# lifecycle failure still requires operator acknowledgement and cleanup.
if grep -q '[^[:space:]]' "$QUARANTINE_FILE"; then
  fail "unresolved quarantined canary exists; manual acknowledgement/cleanup required before a new canary"
fi

is_safe_canary_path() {
  local path="$1"
  [[ "$path" == "$CANARY_DIR_REL"/livesync-bridge-canary-*.txt ]]
}

journal_has_since() {
  local since="$1"
  local message="$2"
  journalctl --user -u livesync-bridge.service --since "$since" --no-pager \
    | grep -Fq -- "$message"
}

wait_for_journal() {
  local since="$1"
  local message="$2"
  local timeout_seconds="$3"
  local deadline=$((SECONDS + timeout_seconds))

  while (( SECONDS < deadline )); do
    if journal_has_since "$since" "$message"; then
      return 0
    fi
    if journal_has_since "$since" "Main process exited" \
      || journal_has_since "$since" "Failed with result" \
      || journal_has_since "$since" "error: Uncaught"; then
      return 1
    fi
    sleep 5
  done
  return 1
}

mark_pending() {
  local path="$1"
  if ! grep -Fxq -- "$path" "$PENDING_FILE"; then
    printf '%s\n' "$path" >> "$PENDING_FILE"
  fi
}

quarantine_pending() {
  local path="$1"
  local reason="$2"
  if ! grep -Fq -- $'\t'"$path"$'\t' "$QUARANTINE_FILE"; then
    printf '%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$path" "$reason" >> "$QUARANTINE_FILE"
  fi
  clear_pending "$path"
}

clear_pending() {
  local path="$1"
  local tmp="$PENDING_FILE.tmp"
  grep -Fvx -- "$path" "$PENDING_FILE" > "$tmp" || true
  mv "$tmp" "$PENDING_FILE"
}

write_canary() {
  local path="$1"
  local absolute_path="$VAULT/$path"
  local now_iso
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  mkdir -p "$(dirname "$absolute_path")"
  cat > "$absolute_path" <<EOF
LiveSync Bridge Canary
Updated: $now_iso
Purpose: temporary sync-health canary maintained by livesync-bridge watchdog.
EOF
}

run_round_trip() {
  local path="$1"
  local absolute_path="$VAULT/$path"
  local put_since delete_since

  ACTIVE_CANARY="$absolute_path"
  rm -f -- "$absolute_path"

  put_since="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  write_canary "$path"
  if ! wait_for_journal "$put_since" "PUT: DONE: $path" "$UPLOAD_TIMEOUT_SECONDS"; then
    rm -f -- "$absolute_path"
    return 1
  fi

  delete_since="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  rm -f -- "$absolute_path"
  if ! wait_for_journal "$delete_since" "DELETE: DONE: $path" "$DELETE_TIMEOUT_SECONDS"; then
    return 1
  fi

  # A delayed remote echo can briefly recreate the path after DELETE: DONE.
  # Require a quiet local state before considering cleanup complete.
  sleep "$SETTLE_SECONDS"
  if [[ -e "$absolute_path" ]]; then
    rm -f -- "$absolute_path"
    return 1
  fi

  ACTIVE_CANARY=""
  return 0
}

restart_bridge_once() {
  if [[ "$BRIDGE_RESTART_USED" == true ]]; then
    return 1
  fi

  BRIDGE_RESTART_USED=true
  log "WARN: Restarting livesync-bridge.service once to clear a stalled canary operation"
  if ! systemctl --user restart livesync-bridge.service; then
    return 1
  fi

  for _ in $(seq 1 12); do
    if systemctl --user is-active --quiet livesync-bridge.service; then
      sleep 3
      return 0
    fi
    sleep 1
  done
  return 1
}

reconcile_canary() {
  local path="$1"

  if ! is_safe_canary_path "$path"; then
    fail "refusing unsafe pending canary path: $path"
  fi

  mark_pending "$path"
  if run_round_trip "$path"; then
    clear_pending "$path"
    return 0
  fi

  log "WARN: Canary round trip incomplete; pending state retained: $path"
  if restart_bridge_once && run_round_trip "$path"; then
    clear_pending "$path"
    return 0
  fi

  quarantine_pending "$path" "cleanup not confirmed after one bounded bridge restart"
  log "FAIL: canary quarantined after bounded retry; it will not be recreated automatically: $path"
  return 1
}

# Recover paths left pending by a timeout, process crash, bridge restart, or
# delayed remote echo before creating another canary.
mapfile -t pending_paths < <(grep -v '^[[:space:]]*$' "$PENDING_FILE" || true)
for pending_path in "${pending_paths[@]}"; do
  if ! reconcile_canary "$pending_path"; then
    exit 1
  fi
done

CANARY_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
CANARY_REL="$CANARY_DIR_REL/livesync-bridge-canary-${CANARY_STAMP}.txt"
reconcile_canary "$CANARY_REL"

log "OK: Canary upload and cleanup observed — user service active and local↔remote lifecycle healthy"
