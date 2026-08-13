# Retarget stale findings

**Status:** Blocked by 002

## Outcome

A reviewer can recover a stale finding by attaching it to a new, confidently identified source range.

## Acceptance

- Missing files and missing range boundaries make findings stale.
- Stale findings remain visible and copyable.
- Completion rejects stale findings.
- Reviewer can retarget a stale finding to a real text-file range.
- Replacement range cannot overlap another finding.
- Successful retarget makes the finding fresh.
- Unambiguous Git file rename plus range reconciliation follows automatically for repository targets.
- Ambiguous repository rename remains stale at the old path; standalone documents do not infer move continuity.

## Seam

- Source reconciliation
- Retarget command
- Completion validation

## Tests

- Deleted file transitions finding to stale.
- Retarget restores freshness.
- Overlapping retarget is rejected.
- Unambiguous rename retains finding identity.
