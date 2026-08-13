# Discard findings safely

**Status:** Blocked by 002

## Outcome

A reviewer intentionally discards findings without accidental loss from blank edits or broad clear commands.

## Acceptance

- Blank new finding cancels creation.
- Blank edit of an existing finding is rejected.
- Individual discard is explicit.
- Most recently discarded finding can be restored during the editor process.
- Undo need not survive restart; standalone-document session state never survives editor exit.
- Whole-session discard requires confirmation.
- Discarding the final finding ends the session and removes its summary.
- Path-scoped clear is not presented as completion.
- Delete/edit races become conflicts once issue 006 ships.

## Seam

- Finding editor
- Discard and undo commands
- Whole-session discard interaction

## Tests

- Blank edit preserves finding.
- Discard then undo restores finding and range.
- Declined session confirmation preserves everything.
