# ADR-001: Short-polling mode for Cloudflare Tunnel / reverse proxy environments

**Status:** Implemented  
**Date:** 2026-03-24 (code), 2026-04-19 (committed)

## Context

PouchDB's `changes({ live: true })` holds a persistent HTTP connection to CouchDB's `_changes` endpoint. Cloudflare Tunnel silently kills idle connections after ~100s. PouchDB doesn't detect the disconnect — the bridge stops receiving updates without error.

The Obsidian plugin solved this with "Use timeouts instead of heartbeats" (obsidian-livesync#627). The bridge had no equivalent.

## Decision

Add a raw HTTP polling loop in `PeerCouchDB.ts` that replaces `beginWatch()`:

- `POST _changes?feed=normal` every 5 seconds via Deno `fetch()`
- Each request completes immediately — no long-lived connection
- Chunk retry logic (3×2s) for docs arriving before their leaf chunks
- Hardcoded ON in this deploy branch; configurable in `pr/cloudflare-short-poll`

## Consequences

- Sync latency increases from near-instant to 5-10 seconds (acceptable)
- CouchDB load: ~36 req/min at 3 users × 5s interval (negligible)
- Original `beginWatch()` path preserved behind `_useShortPolling` flag
