# Surface concurrent finding conflicts

**Status:** Blocked by 002, 005

## Outcome

Concurrent edits never silently overwrite or resurrect review findings. The reviewer resolves divergent intent explicitly.

## Acceptance

- Independent finding additions merge automatically.
- Same-base edits to one finding create a conflict.
- Edit versus discard creates a conflict.
- Concurrent summary edits create a conflict.
- Repository-session conflicts survive restart and are visible in lists and copies; standalone-document conflicts last only for the current editor process.
- Completion is blocked while any conflict exists.
- Reviewer can choose one version or combine content.
- Timestamp alone never resolves a conflict.

## Seam

- Two Neovim instances sharing storage
- Conflict listing/resolution commands
- Completion validation

## Tests

- Two-process edit/edit scenario.
- Two-process edit/discard scenario.
- Explicit resolution produces one active finding.
