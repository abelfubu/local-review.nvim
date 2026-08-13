# Reject overlapping review findings

**Status:** Ready

## Outcome

A reviewer cannot create or retarget a finding whose source range intersects another finding in the same file.

## Acceptance

- Creating a disjoint or adjacent range succeeds.
- Creating a partially contained, containing, or boundary-overlapping range fails.
- The existing finding remains unchanged.
- The UI identifies every conflicting range.
- Editing a finding body from inside its own range remains supported.
- Reconciliation that causes ranges to overlap marks both findings conflicted and blocks completion.

These rules apply to both repository and standalone-document review targets.

## Seam

- Finding creation/edit command
- Finding list state after source reconciliation

## Tests

- User-visible creation rejection through `local_review.comments`.
- Reconciliation fixture proving both collided findings become conflicted.
