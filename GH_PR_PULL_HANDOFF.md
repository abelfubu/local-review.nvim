# Handoff: Pull GitHub PR review comments into local-review.nvim

## Goal

Add a read-only GitHub synchronization command that fetches unresolved inline PR review threads and displays them beside the relevant code.

Primary workflow:

```text
GitHub reviewer → LocalReviewGhPull → inline code comments → LocalReviewExport → coding agent
```

## Current status (read this first)

**Done — foundation is in place on `main`:**

1. **Domain model** — `LocalReviewComment` has `origin ("local"|"github")` and `remote (ReviewMetadata?)`
   fields in `comment_store.lua`. `ReviewMetadata`: repository, pull_number, thread_id, comment_id,
   review_id?, author, url, commit_id?, resolved, outdated. (Generic name on purpose — provider-agnostic.)
2. **Guards** — `comment_store.is_remote` / `is_editable` / `submittable` exist and are wired:
   - `upsert_comment` refuses to update a remote comment → `nil, nil, "Remote comments are read-only"`
   - `remove_comment` refuses remote comments
   - `gh_pr.lua` submits only `submittable()` comments; post-submit cleanup uses ids of submitted ones
   - `export.lua` exports only `get_exportable_comments()` (local only, for now — see Phase 5)
   - `storage.remove_comments_for_path` / `remove_comments_by_ids` always keep remote comments
3. **Layer refactor** — see `ARCHITECTURE.md`. Key facts: `storage` is the comment repository
   (`comments_for_path`, `remove_*`), matching rules are pure functions in `comment_store`
   (`matching_path`, `partition_path`, `partition_ids`), `comments.lua` is buffer workflows only.
   Requires must point downward per the layer map.
4. **No backfill** — single user, storage wiped fresh. Old-shape comments do not exist.
   If that changes, reintroduce defaults-on-load in `storage.load_scope`.

**Test/gate setup:** `./scripts/test.sh` (busted), `./scripts/typecheck.sh` (lua-language-server),
`stylua --check lua/ tests/`. All must pass before every commit. Mock only system boundaries
(`vim.system`, `package.preload` of infra modules — see `tests/gh_pr_spec.lua` for the pattern).

## Next: Phase 3 — GraphQL adapter

Create `lua/local_review/gh_pr_comments.lua` — vim-free except a thin `fetch`:

```lua
local M = {}

M.QUERY = [[ ...const GraphQL string... ]]  -- reviewThreads: id, isResolved, isOutdated, path,
                                            -- line/originalLine, startLine/originalStartLine,
                                            -- diffSide, diffHunk; comments: id, databaseId, body,
                                            -- author{login}, url, commit{oid}, pullRequestReview{id}

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

- `absolute_path` = `scope_root .. "/" .. thread.path`
- Anchors: `anchor.line_number = thread.originalLine`, `anchor.line_text` = last hunk line for
  that line from `diffHunk` (strip leading `+`/context marker); ranges use originalStartLine/originalLine
- `remote` table filled from thread + comment node; `resolved = thread.isResolved`, `outdated = thread.isOutdated`
- `id` = `"gh:" .. comment_node.id` (stable, namespaced)

## Phase 4 — Sync + `:LocalReviewGhPull [path]`

Sync rules (upsert into storage):

- Remote identity = `(repository, pull_number, thread_id, comment_id)`
- Re-pulling upserts; bodies edited on GitHub update in place; never touch `origin == "local"` comments
- Threads now resolved/absent → mark `remote.resolved`/`stale`, **never delete** during sync
- Persist only after a complete successful fetch (atomic: temp file + rename)
- Backoff on 403/429; no caching of fetch results
- Remote comments are persisted in the same scope file as locals (same PR branch = same scope_root)

Command wiring in `init.lua`: resolve repo root via `context`, PR via existing `gh_pr.lua` helpers
(extract `get_pr_info` for reuse), call adapter `fetch`, merge into scope, `markers.refresh`.

## Phase 5 — UI + export

- Separate highlight group (`LocalReviewGhMarker`), title `GitHub Review · @author`, `[outdated]` suffix
- Export includes remote comments WITH attribution (change `get_exportable_comments` policy):

  ```text
  lua/example.lua:20 [github @reviewer]
     Please handle the nil case.
     https://github.com/owner/repo/pull/123#discussion_r...
  ```

- Multiple threads on one line must stay distinct — investigate `find_comment_at_line` returning
  only the first match; if it collapses threads, fix lookup before shipping
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
