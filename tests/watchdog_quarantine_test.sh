#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/repo/watchdog/state" "$tmp/vault/03 Resources/800 - Tech/200 - OpenClaw/canaries"
printf '2026-08-13T00:00:00Z\t03 Resources/800 - Tech/200 - OpenClaw/canaries/livesync-bridge-canary-old.txt\ttest quarantine\n' > "$tmp/repo/watchdog/state/quarantined-canaries.txt"
: > "$tmp/repo/watchdog/state/pending-canaries.txt"
cat > "$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmp/bin/systemctl"
sed \
  -e "s|LOG=\"/home/azure/livesync-bridge/watchdog/watchdog.log\"|LOG=\"$tmp/repo/watchdog/watchdog.log\"|" \
  -e "s|VAULT=\"/home/azure/.openclaw/workspace/memory/obsidian\"|VAULT=\"$tmp/vault\"|" \
  -e "s|STATE_DIR=\"/home/azure/livesync-bridge/watchdog/state\"|STATE_DIR=\"$tmp/repo/watchdog/state\"|" \
  "$repo/watchdog/check_livesync_bridge.sh" > "$tmp/check.sh"
chmod +x "$tmp/check.sh"
if PATH="$tmp/bin:$PATH" "$tmp/check.sh"; then
  echo "watchdog unexpectedly succeeded with unresolved quarantine" >&2
  exit 1
fi
grep -Fq "unresolved quarantined canary exists" "$tmp/repo/watchdog/watchdog.log"
if find "$tmp/vault/03 Resources/800 - Tech/200 - OpenClaw/canaries" -type f | grep -q .; then
  echo "watchdog created a canary despite unresolved quarantine" >&2
  exit 1
fi
[[ "$(wc -l < "$tmp/repo/watchdog/state/quarantined-canaries.txt")" -eq 1 ]]
echo "watchdog quarantine circuit breaker passed"

rm -rf "$tmp/repo" "$tmp/vault"
mkdir -p "$tmp/repo/watchdog/state" "$tmp/vault/03 Resources/800 - Tech/200 - OpenClaw/canaries"
: > "$tmp/repo/watchdog/state/quarantined-canaries.txt"
printf '03 Resources/800 - Tech/200 - OpenClaw/canaries/livesync-bridge-canary-pending.txt\n' > "$tmp/repo/watchdog/state/pending-canaries.txt"
cat > "$tmp/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$tmp/bin/journalctl"
sed \
  -e "s|LOG=\"/home/azure/livesync-bridge/watchdog/watchdog.log\"|LOG=\"$tmp/repo/watchdog/watchdog.log\"|" \
  -e "s|VAULT=\"/home/azure/.openclaw/workspace/memory/obsidian\"|VAULT=\"$tmp/vault\"|" \
  -e "s|STATE_DIR=\"/home/azure/livesync-bridge/watchdog/state\"|STATE_DIR=\"$tmp/repo/watchdog/state\"|" \
  -e 's/UPLOAD_TIMEOUT_SECONDS=60/UPLOAD_TIMEOUT_SECONDS=0/' \
  -e 's/DELETE_TIMEOUT_SECONDS=60/DELETE_TIMEOUT_SECONDS=0/' \
  -e 's/SETTLE_SECONDS=10/SETTLE_SECONDS=0/' \
  "$repo/watchdog/check_livesync_bridge.sh" > "$tmp/check.sh"
chmod +x "$tmp/check.sh"
if PATH="$tmp/bin:$PATH" "$tmp/check.sh"; then
  echo "watchdog unexpectedly succeeded with an unreconciled pending canary" >&2
  exit 1
fi
grep -Fq "canary quarantined after bounded retry" "$tmp/repo/watchdog/watchdog.log"
grep -Fq $'\t03 Resources/800 - Tech/200 - OpenClaw/canaries/livesync-bridge-canary-pending.txt\t' "$tmp/repo/watchdog/state/quarantined-canaries.txt"
if grep -q '[^[:space:]]' "$tmp/repo/watchdog/state/pending-canaries.txt"; then
  echo "pending canary was not cleared after quarantine" >&2
  exit 1
fi
if find "$tmp/vault/03 Resources/800 - Tech/200 - OpenClaw/canaries" -type f | grep -q .; then
  echo "watchdog left local canary files after quarantine" >&2
  exit 1
fi
echo "watchdog pending-to-quarantine bounded retry passed"
