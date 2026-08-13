# Copy findings without completing the review

**Status:** Blocked by 002

## Outcome

A reviewer or agent can copy some or all findings for inspection without changing the active review session.

## Acceptance

- `Copy Findings` supports repository, directory, and file selections.
- Clipboard and headless stdout copies are always non-destructive.
- Payload identifies the target: reviewed branch or detached commit for repository sessions, or document path for standalone sessions.
- Payload identifies unavailable repository sessions and stale or conflicted findings; branch availability does not apply to standalone documents.
- Findings use deterministic path/range order.
- Existing preserve-export command remains as a compatibility alias.
- Existing destructive headless export no longer clears findings.

## Seam

- Neovim copy command
- Headless agent invocation
- Persisted session after copying

## Tests

- Headless copy output plus unchanged persisted session.
- Copy from wrong branch clearly labels unavailability.
