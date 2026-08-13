# Publish a session as a GitHub PR review

**Status:** Blocked by 004, 006, 007, 008

Repository sessions only; standalone-document sessions cannot use this destination.

## Outcome

A reviewer completes a local session by publishing every finding as one submitted GitHub pull request review.

## Acceptance

- Destination validates repository, reviewed branch, PR head, permissions, and every diff location before freezing.
- Reviewer explicitly selects comment, approve, or request changes from supported outcomes.
- Review summary becomes the PR review body.
- Every finding becomes an inline comment without degrading its range.
- Existing pending GitHub review blocks publication.
- Creating remote draft comments does not complete the session.
- Only confirmed review submission completes and removes the local session.
- Partial or ambiguous failure keeps the local session with a pending-publication marker.
- Retry reconciles remote state and cannot duplicate publication.

## Seam

- GitHub review destination adapter
- `Complete Review` destination selection
- Local and remote state after success, failure, and timeout

## Tests

- Capability validation blocks before remote mutation.
- Successful submission removes local session.
- Ambiguous submission preserves recoverable state.
- Retry is idempotent.
