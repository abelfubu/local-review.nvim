# Recover sessions across repository movement

**Status:** Blocked by 001

## Outcome

A review session remains associated with its Git worktree after safe branch or directory continuity changes, without mixing separate worktrees.

## Acceptance

- Each Git worktree has an independent session.
- Persisted identity includes enough Git common-directory/worktree information for recovery.
- Moving a worktree can recover its session when continuity is unambiguous.
- Branch rename preserves the session when findings reconcile.
- Detached session may adopt a branch containing its commit when findings reconcile.
- Arbitrary branch rebinding is rejected.
- Files outside Git worktrees are excluded; issue 009 handles standalone documents without repository identity.

## Seam

- Repository/session identity resolver
- Session load after filesystem and Git transitions

## Tests

- Two worktrees keep separate sessions.
- Worktree move recovers one session.
- Detached commit to containing branch succeeds.
- Unrelated branch adoption fails.
