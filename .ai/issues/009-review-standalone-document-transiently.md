# Review a standalone document transiently

**Status:** Blocked by 002, 003, 004, 005, 007

## Outcome

A reviewer can annotate and hand off a real text file outside Git, such as a temporary implementation plan, without treating its directory as a repository or persisting the session beyond the current editor process.

## Acceptance

- A file outside every Git worktree starts one transient session bound to that document.
- The session survives window and buffer closure but not editor exit.
- No repository, branch, or working-directory identity is assigned.
- Source-range, overlap, stale-finding, copy, completion, and discard rules match repository sessions where applicable.
- Deleting the document makes its findings stale.
- Existing persisted non-Git scopes remain readable through compatibility behavior, but completing or discarding them does not recreate durable state.

## Seam

- Review-target resolver
- In-memory session store
- Commands shared with repository sessions
- Legacy non-Git storage compatibility

## Tests

- Temporary document session survives buffer closure in one editor process.
- A new editor process does not recover the transient session.
- Deleted document findings become stale and remain copyable.
- Legacy persisted non-Git findings can be read and retired without new persistence.
