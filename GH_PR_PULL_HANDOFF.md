# Handoff: Pull GitHub PR review comments into local-review.nvim

## Goal

Add a read-only GitHub synchronization command that fetches unresolved inline PR review threads and displays them beside the relevant code.

Primary workflow:

```text
GitHub reviewer → LocalReviewGhPull → inline code comments → LocalReviewExport → coding agent
```

## Starting point

- Current prerequisite PR: https://github.com/abelfubu/local-review.nvim/pull/4
- PR #4 fixes GitHub submission, repository selection, PR-head handling, selective cleanup, and split editor placement.
- Start this feature from `main` after PR #4 merges, or explicitly branch from `fix/gh-review-and-split-editor` while it remains open.
- Do not add this feature to PR #4.

## MVP scope

Add:

```vim
:LocalReviewGhPull [path]
```

The command should:

1. Resolve the Git repository from the optional path, using the same repository-root rules as GitHub submission.
2. Resolve the PR associated with the current branch.
3. Fetch unresolved inline review threads for that PR.
4. Normalize each thread into an explicit remote-comment model.
5. Synchronize by stable GitHub IDs without creating duplicates.
6. Render fetched threads at their file and line/range.
7. Clearly distinguish GitHub feedback from local draft comments.
8. Mark comments as outdated/stale when they cannot safely map to the working tree.
9. Make fetched feedback available to `LocalReviewExport` without allowing it to be submitted as a new GitHub review.

## Non-goals for the first PR

- Replying to threads
- Resolving threads
- Editing or deleting GitHub comments
- Automatic background polling
- Importing general PR conversation or issue comments
- Importing resolved threads by default

Keep synchronization explicit and read-only.

## Required domain boundary

Fetched feedback must never be treated as a local review draft.

Suggested model:

```lua
---@class LocalReviewOrigin
---@field kind "local"|"github"

---@class GitHubReviewMetadata
---@field repository string
---@field pull_number integer
---@field thread_id string
---@field comment_id string
---@field review_id string?
---@field author string
---@field url string
---@field commit_id string?
---@field resolved boolean
---@field outdated boolean
```

A persisted comment could carry:

```lua
origin = "github",
remote = {
  repository = "owner/repo",
  pull_number = 123,
  thread_id = "...",
  comment_id = "...",
  author = "reviewer",
  url = "https://github.com/...",
  resolved = false,
  outdated = false,
}
```

Before choosing this representation, inspect assumptions in:

- `lua/local_review/comment_store.lua`
- `lua/local_review/comments.lua`
- `lua/local_review/ui.lua`
- `lua/local_review/markers.lua`
- `lua/local_review/export.lua`
- `lua/local_review/gh_pr.lua`

Important: local editing, deletion, and `LocalReviewGh` submission must filter out `origin == "github"`. A fetched comment must not be editable through the local draft editor or cleared as a submitted local draft.

## API recommendation

Prefer GitHub GraphQL because review threads and resolution state are first-class there. Use `gh api graphql` through argument arrays and `vim.system`, with `cwd` set to the resolved repository root.

Fetch enough data to identify and render:

- Repository and PR number
- Thread ID
- Resolution/outdated state
- File path
- Current/original line and range information
- Diff side
- Comment ID, body, author, URL and commit/review identity

Verify the live GraphQL schema before finalizing field names. Do not infer resolved state from the flat REST comments endpoint.

Create a dedicated adapter, for example:

```text
lua/local_review/gh_pr_comments.lua
```

Keep API transport and normalization there. Keep rendering and persistence independent of raw GitHub response shapes.

## Synchronization rules

Use `(repository, pull_number, thread_id, comment_id)` as remote identity.

On every explicit pull:

1. Load the latest stored state.
2. Upsert fetched remote comments by remote identity.
3. Preserve all local comments.
4. Preserve GitHub comments belonging to other PRs.
5. Remove or mark remote comments from this PR that are now resolved or absent, according to a documented policy.
6. Never overwrite local comment bodies.
7. Persist only after a complete successful fetch; API failure must leave existing state unchanged.

Avoid path-wide clearing. Concurrently created local comments must survive synchronization.

## Positioning and stale behavior

GitHub line numbers refer to a PR commit/diff, not necessarily the current working tree.

Safe mapping order:

1. Use GitHub path and current line/range when they match the checked-out PR head.
2. Capture textual context/diff context as anchors.
3. Reuse the existing positioning resolver to reconcile against the working tree.
4. If mapping is ambiguous or missing, mark the remote comment stale/outdated.
5. Never silently guess a different line.

Display stale/outdated GitHub feedback, but make the state obvious.

## UI guidance

Suggested title:

```text
GitHub Review · @author
```

Suggested distinctions:

- Separate highlight/sign group from `LocalReviewMarker`
- Include `[outdated]` or `[stale]` in the title
- Include a GitHub URL in list/export output
- Add an action to open the URL in the browser only if it remains small and read-only

Investigate multiple local/remote threads on the same line. The current lookup/rendering model may assume one editable comment covers a line; do not silently collapse threads.

## Export format

Remote feedback should be agent-readable and clearly attributed, for example:

```text
lua/example.lua:20 [github @reviewer]
   Please handle the nil case.
   https://github.com/owner/repo/pull/123#discussion_r...
```

Exporting must not delete remote comments. Existing local export/delete semantics must remain unchanged unless explicitly requested.

## Tests

Use TDD through public seams. Suggested behavioral coverage:

1. Cancelled/failed GitHub fetch leaves stored comments unchanged.
2. Explicit path runs GitHub commands in that repository.
3. Only unresolved threads are imported.
4. Repeated pulls do not duplicate threads/comments.
5. A resolved/removed remote thread follows the documented sync policy.
6. Local comments survive remote synchronization.
7. Remote comments cannot be submitted by `LocalReviewGh`.
8. Remote comments cannot be edited/deleted as local drafts.
9. Remote comments are not cleared by local submission/export cleanup.
10. Outdated or unmappable comments are marked, not guessed onto a line.
11. Multiple threads on one line remain distinct.
12. Export identifies GitHub origin, author and URL.

Mock only system boundaries (`gh` process/API). Avoid tests coupled to private helper functions.

Run:

```bash
./scripts/test.sh
./scripts/typecheck.sh
stylua --check lua/ tests/
```

Add a headless Neovim smoke test if marker/UI behavior cannot be covered by Busted.

## Acceptance criteria

- `:LocalReviewGhPull` fetches and displays unresolved inline PR feedback.
- Re-running it is idempotent.
- Repository and PR identity are explicit and correct.
- Local comments remain editable and safe.
- GitHub comments remain read-only.
- `LocalReviewGh` never resubmits imported feedback.
- Failed synchronization causes no local data loss.
- Ambiguous positions are stale/outdated rather than guessed.
- Exported feedback is useful to a coding agent.
- Tests, typecheck and formatting pass.

## Delivery guidance

Keep the first PR narrow. If supporting multiple comments per line requires a substantial storage/rendering redesign, split that foundation into its own PR before adding GitHub synchronization.
