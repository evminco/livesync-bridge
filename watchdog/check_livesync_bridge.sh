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
# Retry a valid quarantined canary after a bounded 30 minute cooldown.
QUARANTINE_COOLDOWN_SECONDS=1800
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

is_safe_canary_path() {
  local path="$1"
  local leaf

  [[ "$path" == "$CANARY_DIR_REL/"* ]] || return 1
  leaf="${path#"$CANARY_DIR_REL/"}"
  [[ "$leaf" =~ ^livesync-bridge-canary-[0-9]{8}T[0-9]{6}Z[.]txt$ ]]
}

path_in_list() {
  local needle="$1"
  shift
  local candidate

  for candidate in "$@"; do
    if [[ "$candidate" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

parse_quarantine_record() {
  local record="$1"
  local extra=""
  local epoch

  QUARANTINE_TS=""
  QUARANTINE_PATH=""
  QUARANTINE_REASON=""
  QUARANTINE_EPOCH=""

  IFS=$'\t' read -r QUARANTINE_TS QUARANTINE_PATH QUARANTINE_REASON extra <<< "$record"

  if [[ -n "$extra" || -z "$QUARANTINE_TS" || -z "$QUARANTINE_PATH" || -z "$QUARANTINE_REASON" ]]; then
    return 1
  fi
  if ! [[ "$QUARANTINE_TS" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    return 1
  fi
  if ! epoch="$(date -u -d "$QUARANTINE_TS" +%s 2>/dev/null)"; then
    return 1
  fi
  if ! is_safe_canary_path "$QUARANTINE_PATH"; then
    return 2
  fi

  QUARANTINE_EPOCH="$epoch"
  return 0
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
  local tmp

  if grep -Fxq -- "$path" "$PENDING_FILE"; then
    return 0
  fi

  tmp="$(mktemp "$STATE_DIR/pending-canaries.XXXXXX")"
  cat "$PENDING_FILE" > "$tmp"
  printf '%s\n' "$path" >> "$tmp"
  mv "$tmp" "$PENDING_FILE"
}

clear_pending() {
  local path="$1"
  local tmp
  tmp="$(mktemp "$STATE_DIR/pending-canaries.XXXXXX")"
  grep -Fvx -- "$path" "$PENDING_FILE" > "$tmp" || true
  mv "$tmp" "$PENDING_FILE"
}

quarantine_path_exists() {
  local path="$1"
  local record

  while IFS= read -r record || [[ -n "$record" ]]; do
    if [[ "$record" =~ [^[:space:]] ]] \
      && parse_quarantine_record "$record" \
      && [[ "$QUARANTINE_PATH" == "$path" ]]; then
      return 0
    fi
  done < "$QUARANTINE_FILE"
  return 1
}

quarantine_pending() {
  local path="$1"
  local reason="$2"
  local tmp

  if ! quarantine_path_exists "$path"; then
    tmp="$(mktemp "$STATE_DIR/quarantined-canaries.XXXXXX")"
    cat "$QUARANTINE_FILE" > "$tmp"
    printf '%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$path" "$reason" >> "$tmp"
    mv "$tmp" "$QUARANTINE_FILE"
  fi
  clear_pending "$path"
}

clear_quarantine_path() {
  local path="$1"
  local tmp record removed=false

  tmp="$(mktemp "$STATE_DIR/quarantined-canaries.XXXXXX")"
  while IFS= read -r record || [[ -n "$record" ]]; do
    if [[ "$record" =~ [^[:space:]] ]] \
      && parse_quarantine_record "$record" \
      && [[ "$QUARANTINE_PATH" == "$path" ]]; then
      removed=true
      continue
    fi
    printf '%s\n' "$record" >> "$tmp"
  done < "$QUARANTINE_FILE"

  if [[ "$removed" != true ]]; then
    rm -f -- "$tmp"
    return 1
  fi

  mv "$tmp" "$QUARANTINE_FILE"
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
  log "FAIL: canary quarantined after bounded retry; automatic retry deferred until cooldown expires: $path"
  return 1
}

process_quarantines() {
  local now_epoch record status age_seconds remaining_seconds quarantined_path
  local quarantine_records=()
  local eligible_paths=()

  mapfile -t quarantine_records < <(grep -v '^[[:space:]]*$' "$QUARANTINE_FILE" || true)
  if (( ${#quarantine_records[@]} == 0 )); then
    return 0
  fi

  now_epoch="$(date -u +%s)"
  for record in "${quarantine_records[@]}"; do
    status=0
    parse_quarantine_record "$record" || status=$?
    case "$status" in
      0) ;;
      1) fail "malformed quarantined canary record; leaving quarantine unchanged" ;;
      2) fail "unsafe quarantined canary path; leaving quarantine unchanged: $QUARANTINE_PATH" ;;
      *) fail "could not parse quarantined canary record; leaving quarantine unchanged" ;;
    esac

    age_seconds=$((now_epoch - QUARANTINE_EPOCH))
    if (( age_seconds < QUARANTINE_COOLDOWN_SECONDS )); then
      remaining_seconds=$((QUARANTINE_COOLDOWN_SECONDS - age_seconds))
      fail "quarantined canary cooldown active (${remaining_seconds}s remaining); no new canary created: $QUARANTINE_PATH"
    fi

    if ! path_in_list "$QUARANTINE_PATH" "${eligible_paths[@]}"; then
      eligible_paths+=("$QUARANTINE_PATH")
    fi
  done

  if ! systemctl --user is-active --quiet livesync-bridge.service; then
    fail "livesync-bridge.service is not active under user systemd"
  fi

  for quarantined_path in "${eligible_paths[@]}"; do
    # Stage as pending before clearing quarantine so an interruption resumes the
    # same path instead of losing cleanup state.
    mark_pending "$quarantined_path"
    if ! clear_quarantine_path "$quarantined_path"; then
      fail "failed to atomically clear quarantined canary path; leaving run failed: $quarantined_path"
    fi
    log "WARN: Rechecking eligible quarantined canary after cooldown: $quarantined_path"
    if ! reconcile_canary "$quarantined_path"; then
      exit 1
    fi
  done
}

# A quarantine remains a circuit breaker, but an old, valid record is retried
# after a bounded cooldown so transient remote cleanup failures self-recover.
process_quarantines

if ! systemctl --user is-active --quiet livesync-bridge.service; then
  fail "livesync-bridge.service is not active under user systemd"
fi

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
