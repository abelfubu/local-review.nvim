# Handoff: Pull GitHub PR review comments into local-review.nvim

## Goal

Add a read-only GitHub synchronization command that fetches unresolved inline PR review threads and displays them beside the relevant code.

Primary workflow:

```text
GitHub reviewer → LocalReviewGhPull → inline code comments → LocalReviewExport → coding agent
```

## Current status (read this first)

**Foundation merged in PR #5 — branch from fresh `main`.**

1. **Domain model** — `LocalReviewComment` has `origin ("local"|"github")` and `remote (ReviewMetadata?)`
   fields in `domain/comment_store.lua`. `ReviewMetadata`: repository, pull_number, thread_id, comment_id,
   review_id?, author, url, commit_id?, resolved, outdated. (Generic name on purpose — provider-agnostic.)
2. **Guards** — `comment_store.is_remote` / `is_editable` exist and are wired:
   - `upsert_comment` refuses to update a remote comment → `nil, nil, "Remote comments are read-only"`
   - `remove_comment` refuses remote comments
   - `gh_pr.lua` submits only its own `get_submittable_comments()` filter (policy lives in gh_pr,
     NOT in comment_store — mirrors export's local+remote composition policy)
   - `export.lua` includes remote comments with attribution and URL; it never imports `comments.lua`
     (it composes `storage` locals + `gh_session` remotes via `comment_store` rules)
   - `storage` only ever persists local comments; legacy persisted remotes are filtered out on load
     and during concurrent merge
3. **Layered folders** — `domain/ application/ infrastructure/ presentation/` under `lua/local_review/`.
   See `ARCHITECTURE.md`. `./scripts/layers.sh` mechanically checks all forbidden edges; part of the gate.
4. **Storage** — `save_scope` is atomic (temp + rename) and supports `remove_ids` tombstones so LWW
   merges cannot resurrect removed comments. Single-scope queries: `comments_for_path(scope_root, ...)`.
5. **UI refresh is event-driven** — application fires `User`/`LocalReviewChanged`
   (`data = { scope_root = ... }`) after mutations; `init.lua` subscribes → `markers.refresh_scope`.
   Never import presentation from application.
6. **No backfill** — single user, storage wiped fresh. Old-shape comments do not exist.
   If that changes, reintroduce defaults-on-load in `storage.load_scope`.

Also in PR #5: `LocalReviewGh` can submit a review with zero comments (plain approve /
body-only review).

**Test/gate setup:** `./scripts/test.sh` (busted), `./scripts/typecheck.sh`,
`stylua --check lua/ tests/`, `./scripts/layers.sh`, smoke tests via `nvim --headless -l tests/*_smoke.lua`.
All must pass before every commit. Mock only system boundaries (`vim.system`,
`package.preload` of infra modules — see `tests/gh_pr_spec.lua` for the pattern).

## Next: Phase 3 — GraphQL adapter

Create `lua/local_review/application/gh_pr_comments.lua` — application layer, same as `gh_pr.lua`
which already owns the `gh` CLI boundary. Vim-free except a thin `fetch`:

```lua
local M = {}

M.QUERY = [[ ...const GraphQL string... ]]  -- reviewThreads: id, isResolved, isOutdated, path,
                                            -- subjectType, line/originalLine, startLine/originalStartLine,
                                            -- diffSide, startDiffSide, diffHunk; comments: id, body,
                                            -- author{login}, url, commit{oid}, pullRequestReview{id}
                                            -- (no databaseId — deprecated by GitHub)

-- Pagination is required: reviewThreads(first: 100) caps at 100. Query pageInfo
-- { hasNextPage endCursor } and follow cursors until exhausted; the same applies
-- to the nested comments connection on long threads.

---@param node table raw reviewThread node
---@return string? err  -- nil when valid
function M.validate(node) end

---@param thread table raw reviewThread node
---@param ctx { repository: string, pull_number: integer, scope_root: string }
---@return LocalReviewComment[]
function M.normalize(thread, ctx) end  -- one LocalReviewComment per comment node, origin = "github"

---@param scope_root string
---@param pr_info { number: integer }
---@param callback fun(threads: table[]?, err: string?)
function M.fetch(scope_root, pr_info, callback) end  -- vim.system({"gh","api","graphql",...}, {cwd=scope_root})
```

TDD order:

1. Capture a real fixture: `gh api graphql -f query=... -F owner=abelfubu -F repo=local-review.nvim -F pr=4 > tests/fixtures/pr_threads.json`
2. Tests for `normalize`/`validate` against the fixture (vim-free, plain busted)
3. Implement `QUERY`, `validate`, `normalize`
4. `fetch` last; mock `vim.system` in tests

Normalization decisions:

- Reject non-line threads before normalizing: `subjectType ~= "LINE"` (e.g. FILE-level
  threads) have no line anchor — skip them (log/notify), do not guess a position
- Diff side: `diffSide == "RIGHT"` anchors at `line`; `"LEFT"` anchors at `originalLine`
  and the comment refers to removed code — mark it outdated when it cannot map. Ranges
  resolve `startDiffSide` with `startLine`/`originalStartLine` the same way. When in
  doubt, stale — never guess
- `absolute_path` = `scope_root .. "/" .. thread.path`
- Anchors: `anchor.line_number` from the side-resolved line, `anchor.line_text` = last hunk
  line for that line from `diffHunk` (strip leading `+`/`-`/context marker); ranges use
  the resolved start/end lines
- `remote` table filled from thread + comment node; `resolved = thread.isResolved`, `outdated = thread.isOutdated`
- `id` = `"gh:" .. comment_node.id` (stable, namespaced)

## Phase 4 — Sync + `:LocalReviewGhPull [path]`

Sync rules (replace the in-memory session set):

- Remote comments are session-temporal: each successful `:LocalReviewGhPull`
  wholesale-replaces the per-scope, per-branch in-memory session set managed by
  `application/gh_session.lua`.
- Failed fetches leave any existing session state untouched.
- Session comments are branch-visible: `gh_session.comments_for_path` only returns
  comments whose recorded branch matches the current branch.
- `gh_pr_comments.fetch` performs validation/normalization and may skip
  non-line threads; skipped counts are surfaced to the user but do not affect
  replacement.

Command wiring in `init.lua`: resolve repo root via `context`, PR via existing `gh_pr.lua` helpers
(extract `get_pr_info` for reuse), call adapter `fetch`, then `gh_session.set`. Fire
`User`/`LocalReviewChanged` after a successful sync (never call `markers` directly
— see ARCHITECTURE.md).

## Phase 5 — UI + export

- Separate highlight group (`LocalReviewGhMarker`), title `GitHub Review · @author`, `[outdated]` suffix
- Export includes remote comments with attribution:

  ```text
  lua/example.lua:20 [github @reviewer]
     Please handle the nil case.
     https://github.com/owner/repo/pull/123#discussion_r...
  ```

- Session remotes are returned by `comments.list_comments_in_path` and guarded
  against edits/deletes in `comments.lua`.
- Optional: open-in-browser action for the comment URL (keep it small and read-only)

## Non-goals (first PR)

- Replying to / resolving / editing / deleting GitHub threads
- Background polling
- Importing general PR conversation or issue comments
- Importing resolved threads by default

## Acceptance criteria

- `:LocalReviewGhPull` fetches and displays unresolved inline PR feedback
- Re-running is idempotent
- Local comments remain editable and safe; GitHub comments stay read-only
- `LocalReviewGh` never resubmits imported feedback
- Failed sync causes no local data loss
- Ambiguous positions are stale/outdated, never guessed
- Exported feedback is agent-useful; tests + typecheck + stylua pass
