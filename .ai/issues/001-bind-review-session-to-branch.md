# Bind a review session to its branch

**Status:** Done

## Outcome

A review session starts with the first finding and remains bound to that Git branch. On another branch, findings remain readable but cannot be changed.

## Acceptance

- First finding persists the current branch binding.
- Reopening on that branch reports the session available.
- Switching branches reports it unavailable.
- Create, edit, and delete are blocked while unavailable.
- Error identifies the reviewed branch.
- Detached-commit binding remains a follow-up within repository-continuity work.

## Seam

- `local_review.session`
- `local_review.comments`
- Neovim command behavior

## Tests

- `tests/session_spec.lua`
- `tests/session_branch_smoke.lua`
