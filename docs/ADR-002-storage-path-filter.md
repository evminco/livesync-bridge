# ADR-002: Storage peer path exclusion filter

**Status:** Implemented  
**Date:** 2026-04-19

## Context

When git is initialized inside the vault directory (for audit/versioning), the storage peer's file watcher detects `.git/` changes and syncs them to CouchDB. This pollutes the vault database with hundreds of git objects and metadata files that are not vault content.

The upstream bridge has no ignore/exclude mechanism for the storage peer.

## Decision

Add a path filter in `PeerStorage.ts` at the `dispatch()` and `dispatchDeleted()` chokepoints — the single path through which all watched file events reach CouchDB.

Excluded path segments: `.git`, `.obsidian`, `.trash`, `.DS_Store`

```typescript
private _ignoredPatterns = [".git", ".obsidian", ".trash", ".DS_Store"];

private _shouldIgnore(relativePath: string): boolean {
    const segments = relativePath.split("/");
    return segments.some(s => this._ignoredPatterns.includes(s));
}
```

Filtering at `dispatch()`/`dispatchDeleted()` rather than at the watcher level covers all three code paths: chokidar, Deno.watchFs, and offline scan.

## Consequences

- `.git/` objects never reach CouchDB (verified: 0 docs)
- Watcher still logs detection events at verbose level (cosmetic, no functional impact)
- `.gitignore` (root file, not inside `.git/`) passes through — harmless
- Filter is not configurable (hardcoded patterns) — sufficient for our deployment
