# Complete a review through the clipboard atomically

**Status:** Blocked by 002, 003

## Outcome

A reviewer completes the whole active session through one confirmed system-clipboard handoff. No partial or invalid session is removed.

## Acceptance

- Completion always targets every finding in the session; path arguments are unsupported.
- Session must contain at least one finding; repository sessions must also be available on their bound branch or commit.
- Every finding must be fresh and conflict-free.
- Session freezes during completion.
- Source identity is verified immediately before delivery.
- Success in either system clipboard adapter completes delivery.
- Clipboard failure keeps the complete session unchanged.
- Success removes the complete session atomically.
- Headless stdout cannot complete a review.
- Existing destructive export becomes a compatibility alias only when invoked as whole-session interactive completion.

## Seam

- `Complete Review` command
- Clipboard destination adapter
- Persisted session before and after completion

## Tests

- Validation failures preserve session.
- Clipboard failure preserves session.
- Confirmed clipboard write removes all findings.
- Source change during freeze aborts completion.
