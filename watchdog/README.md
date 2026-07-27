# LiveSync bridge watchdog

The watchdog proves the full lifecycle of a unique temporary canary:

1. Persist the canary path in `watchdog/state/pending-canaries.txt`.
2. Write a `.txt` file under the vault's `OpenClaw/canaries/` directory.
3. Wait for the bridge journal to report `PUT: DONE`.
4. Remove the local file.
5. Wait for `DELETE: DONE` and a short quiet period with the local path absent.
6. Clear the pending path and log success.

The `.txt` extension keeps temporary canaries out of OpenClaw's Markdown memory index.

## Recovery behavior

- A filesystem lock prevents timer and manual invocations from overlapping.
- Pending paths are reconciled before a new canary is created.
- If a round trip stalls, the watchdog restarts `livesync-bridge.service` once and retries the same path.
- There is no restart loop. A second failure exits non-zero and retains the pending path for the next invocation.
- Chokidar event and async-handler errors are caught in `PeerStorage.ts` so a disappearing canary does not become an unhandled watcher failure.

Runtime state and logs are intentionally untracked:

- `watchdog/state/`
- `watchdog/watchdog.log`

## Validation

```bash
bash -n watchdog/check_livesync_bridge.sh
systemctl --user start livesync-bridge-watchdog.timer
systemctl --user is-active livesync-bridge.service
systemctl --user is-active livesync-bridge-watchdog.timer
tail -n 20 watchdog/watchdog.log
```

A successful run logs `OK: Canary upload and cleanup observed`, leaves the pending-state file empty, and leaves no timestamped `.txt` canary in the local vault.
