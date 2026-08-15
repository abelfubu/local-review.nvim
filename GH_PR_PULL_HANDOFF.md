# Handoff: Pull GitHub PR review comments into local-review.nvim

## Goal

Add a read-only GitHub synchronization command that fetches unresolved inline PR review threads and displays them beside the relevant code.

Primary workflow:

```text
GitHub reviewer → LocalReviewGhPull → inline code comments → LocalReviewExport → coding agent
```

## Starting point

- Prerequisite PR #4 is merged (`fix/gh-review-and-split-editor`). Branch this feature from `main`.

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

Suggested model (named `ReviewMetadata`, provider-agnostic so GitLab/Azure can reuse it later; `origin` grows new values per provider):

```lua
---@alias LocalReviewOrigin "local"|"github"

---@class ReviewMetadata
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
- Resolution/outdated state (`isResolved`, `isOutdated`)
- File path
- Current/original line and range (`line`/`originalLine`, `startLine`/`originalStartLine`)
- Diff side
- Diff hunk (`diffHunk`) — this is the textual anchor; review comments carry no blob SHA
- Comment ID, body, author, URL and commit/review identity

Keep the GraphQL query as a single const string in the adapter module, and validate required fields at runtime, aborting with a clear error if any are missing (schema drift guard).

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
5. Mark remote comments from this PR that are now resolved or absent from the fetch as resolved/stale. Never delete remote comments during sync — an unresolved-only query cannot distinguish resolved from deleted or moved-off-diff. An explicit purge command may be added later.
6. Never overwrite local comment bodies. Remote comment bodies edited on GitHub should be updated in place.
7. Persist only after a complete successful fetch; API failure must leave existing state unchanged. Write to a temp file and atomically rename (`storage.lua` currently does a plain `writefile`).
8. On HTTP 403/429 or rate-limit errors, retry with exponential backoff and surface a clear error. Do not cache fetch results — caching would make freshly resolved threads appear unresolved.
9. Namespace persisted remote comments by `(repository, pull_number)` so preserving other PRs' comments is structural, not just a filter.

Avoid path-wide clearing. Concurrently created local comments must survive synchronization.

## Positioning and stale behavior

GitHub line numbers refer to a PR commit/diff, not necessarily the current working tree.

Safe mapping order:

1. Use GitHub path and current line/range when they match the checked-out PR head.
2. Capture the `diffHunk` and original line/range as anchors.
3. Reuse the existing dual-anchor resolver (`comment_store.reconcile_dual_anchor_comment`) to reconcile against the working tree.
4. Trust GitHub's `isOutdated` flag rather than recomputing drift. If mapping is additionally ambiguous or missing locally, mark the remote comment stale.
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
