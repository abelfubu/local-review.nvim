# Domain gap analysis

Comparison of the current implementation with [CONTEXT.md](../CONTEXT.md) and [ADR 0001](./adr/0001-single-branch-atomic-review-sessions.md).

## Priority gaps

| Priority | Domain rule | Current behavior | Required change |
|---|---|---|---|
| P0 | One durable review session bound to a branch (detached commit deferred) | Branch binding is persisted and enforced; sessions on other branches are visible but unavailable. Detached-commit binding is not yet implemented. | Implement detached-commit binding in repository-continuity work. |
| P0 | Completion is whole-session, validated, and atomic | Destructive export accepts a file or directory, includes stale findings, and clears only that subset. | Add whole-session clipboard completion with reconcile, validation, freeze, source recheck, delivery confirmation, and atomic removal. |
| P0 | Source ranges never overlap | Creation checks only whether the new start line is inside one existing range. Reconciliation does not detect collisions. | Validate complete intervals on create/retarget and mark post-reconciliation overlaps as conflicts. |
| P0 | Headless output is a non-destructive finding copy | Headless export treats stdout as successful delivery and clears findings. | Separate finding copy from completion. Never complete from stdout alone. |
| P1 | Concurrent edits and discards become conflicts | Storage silently prefers the current saver for duplicate IDs; stale writers can resurrect discarded findings. | Add revisions and discard records. Materialize divergent same-base changes as conflicts. |
| P1 | Findings require explicit discard; session discard requires confirmation | Blank edits delete findings. Clear deletes arbitrary path subsets without confirmation. | Reject blank edits to existing findings. Add discard-with-undo and confirmed whole-session discard. |
| P2 | Files outside Git are standalone document targets (deferred to issue 009) | PR1 retains legacy durable scopes for non-Git files without crashing. | Implement transient, document-bound sessions in issue 009; keep legacy persisted scopes only for read-and-retire compatibility. |
| P1 | Missing/renamed files become stale or follow unambiguous Git renames | File-level reconciliation, rename following, and retargeting do not exist. | Reconcile file identity and add explicit retargeting with overlap checks. |
| P1 | Finding copies identify session state | Preserve export labels stale findings only. | Include reviewed branch/commit, availability, stale state, and conflicts. |
| P2 | Session supports summary, destinations, and PR outcomes | Export has a fixed heading; no session metadata or GitHub adapter exists. | Add summary and clipboard destination first. Defer GitHub publishing until session semantics are stable. |

## Existing foundations

- Dual text-and-context anchors with independent range boundaries.
- Partial range loss marks a finding stale.
- Deterministic path/range ordering.
- Non-destructive preserve export.
- Clipboard writes occur before deletion.
- Git worktrees naturally resolve to different top-level paths.

## First milestone

### Branch-bound clipboard review sessions

1. Persist one session per repository/worktree with branch binding (detached commit deferred), optional summary, findings, revisions, and conflicts.
2. Migrate existing stored comments into a session on first load.
3. Enforce non-empty findings and exclusive ranges on create, edit, and retarget.
4. Reconcile targets and expose fresh, stale, conflicted, and unavailable states.
5. Make finding copy always non-destructive and state-aware.
6. Replace destructive path export with whole-session clipboard completion.
7. Add individual discard with short-lived undo and confirmed whole-session discard.
8. Update commands, help, README, and agent skills while preserving compatibility aliases where practical.

Transient standalone-document sessions and GitHub PR publication are later milestones.
