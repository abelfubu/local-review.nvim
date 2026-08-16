# Architecture

local-review.nvim is organized in four layers. `require` edges must point **downward only** —
a module may depend on its own layer or layers below it, never upward.

```text
lua/local_review/
├── init.lua                     (presentation: keymaps + commands)
├── domain/        comment_store · positioning   (vim-free, busted-tested)
├── application/   comments · export · gh_pr · gh_pr_comments · gh_pr_sync · gh_session
├── infrastructure/ storage · context
└── presentation/  ui · markers · telescope
```

Layer violations are checked mechanically: `./scripts/layers.sh` fails on any
upward require (domain → anything above, infrastructure → application/presentation,
application → presentation). Run it with the commit gate.

## Dependency rules

1. **Downward only.** Presentation → application → infrastructure → domain.
2. **No sideways edges in application.** `export` and `gh_pr` must not import `comments`;
   they compose `context` (path resolution) + `storage` (queries/mutations) + `comment_store` (rules).
   `export` may also compose `gh_session` (the session store is an application-layer source of
   remote comments). `gh_pr_sync` is an allowed exception: it may compose `gh_pr` and
   `gh_pr_comments` to orchestrate the `:LocalReviewGhPull` workflow.
3. **Domain never imports vim-coupled modules.** `comment_store` and `positioning` stay pure Lua
   so they run under busted without a Neovim instance. Domain functions declare preconditions
   (e.g. "paths are absolute and normalized"); infrastructure establishes them.
4. **Infrastructure may import domain** (e.g. `storage` applies `comment_store` rules), never the reverse.
5. **Presentation owns all `vim.api` UI surface**: windows, signs, keymaps, pickers.

## Module responsibilities

### Domain — `domain/comment_store.lua`
The rulebook. Everything that decides *what is true* about comments:

- Comment lifecycle: `upsert_comment`, `remove_comment` (both enforce the remote read-only guard)
- Ownership policy: `is_remote`, `is_editable`, `submittable`
- Path matching: `matching_path`, `partition_path`, `partition_ids` (pure; inputs assumed normalized)
- Anchoring: `apply_anchor`, `reconcile_*`, stale detection, `comment_sorter`
- Data shape: `LocalReviewComment`, `ReviewMetadata` annotations

### Domain — `domain/positioning.lua`
Text-anchor capture and resolution: how a comment finds its line after the file changes.

### Infrastructure — `infrastructure/storage.lua`
The comment repository. The *only* module that knows comments live in per-scope JSON files
(`stdpath("state")/local-review/<sha256(scope_root)>.json`). Hides file layout, hashing,
last-writer-wins merge, and concurrency fingerprints behind a small interface:

- Reads: `load_scope`, `comments_for_path(scope_root, target_path, kind)`
- Writes: `save_scope`, `delete_scope`, `remove_comments_for_path`, `remove_comments_by_ids`

### Infrastructure — `infrastructure/context.lua`
Path and scope resolution: `normalize_path`, `path_kind`, `scope_root` (git root),
`relative_path`, `default_export_root`, `comment_context`. Owns `vim.fs`/`vim.fn.fnamemodify`.

### Application — `application/comments.lua`
Buffer-coupled workflows: `set_line_comment`, `delete_line_comment`, `delete_current_line`,
`comments_for_buffer`, `get_line_state`, `jump`, reconcile-on-load. Notifications for these
flows live here.

### Application — `application/export.lua`
Export policy and format: composes local storage + session remotes, produces
agent-readable text, clipboard write, clear-after-export.

### Application — `application/gh_pr.lua`
GitHub review submission: PR resolution, review prompt flow, `submit_review`,
post-submit cleanup of submitted local comments.

### Application — `application/gh_pr_comments.lua`
GitHub GraphQL adapter: fetches unresolved review threads and normalizes them into
`origin == "github"` `LocalReviewComment` values. Owns the `gh api graphql`
system boundary.

### Application — `application/gh_session.lua`
In-memory session store for remote PR comments and review bodies. Each pull
replaces the whole per-scope set; comments and reviews are queried by branch
and merged with persisted locals in read paths.

- `set(scope_root, comments, reviews, pull_number, branch)` — wholesale replacement
  of the session set for a scope.
- `get(scope_root)` — raw session state for a scope.
- `clear(scope_root)` — drop the session set.
- `comments_for_path(scope_root, target_path, kind)` — branch-filtered query that
  unions session remotes with the current branch; comments from other branches are
  hidden until the matching branch is checked out.
- `reviews_for_scope(scope_root)` — branch-filtered query for PR-level review
  bodies; hidden when the current branch does not match the pulled branch.

### Application — `application/gh_pr_sync.lua`
Read-only sync workflow: fetches via `gh_pr_comments.fetch`, validates the
repository metadata, and delegates wholesale replacement of the in-memory
session set (comments and review bodies) to `gh_session.set`. Failed fetches
leave any existing session state untouched; `pull` fires `LocalReviewChanged`
only after a successful sync and `LocalReviewReviews` when review bodies are
present.

### Presentation
- `init.lua` — keymaps and `:LocalReview*` commands only; no logic beyond argument parsing
- `ui.lua` — the floating comment editor
- `markers.lua` — gutter signs and virtual text
- `telescope.lua` — picker integration

## Invariants

- **Remote comments are session-temporal and read-only.** `origin == "github"` comments
  are never persisted; each `:LocalReviewGhPull` wholesale-replaces the per-scope
  session set for the current pull/branch. They cannot be edited, deleted, submitted,
  or cleared by export/submit cleanup. Enforced in `comment_store` (rules) and
  `comments.lua` (session-remote guards) — not at call sites.
- **`origin` is the single discriminator.** Guards check `origin`, never `remote ~= nil`.
- **Storage normalizes at the boundary and contains only local comments.** Comments are
  created complete by `upsert_comment`; readers trust the shape. Legacy persisted
  remotes are filtered out on `load_scope`. (If the plugin gains external users or the
  schema changes, reintroduce defaults-on-load here.)
- **A comment lives in exactly one scope**: the one whose root contains its `absolute_path`.
  The same `context.scope_root` derivation is used at creation and query time.
- **Data changes reach the UI via events, not imports.** Application modules fire
  `User`/`LocalReviewChanged` (`data = { scope_root = ... }`) after mutations; `init.lua`
  subscribes and calls `markers.refresh_scope`. Application never imports presentation.
- **Session comments are branch-visible.** `gh_session.comments_for_path` shows only
  remotes whose recorded branch matches the current branch, so a stale session set
  from a switched branch does not leak into the current buffer.
- **Session review bodies are branch-visible and read-only.** Like session comments,
  PR-level review bodies live only in memory, are wholesale-replaced on each pull,
  and are hidden when the current branch does not match the pulled branch.
- **`remote.resolved`, `remote.outdated`, and `stale` are independent facts.**
  `remote.resolved` reflects GitHub resolution, `remote.outdated` reflects GitHub
  diff positioning, and `stale` reflects local buffer anchoring. Sync updates the
  first two from GitHub but never overwrites `stale`.

## Testing strategy

- **busted** (`tests/*_spec.lua`) — domain and vim-free logic. App modules with vim surface
  are tested by stubbing `_G.vim` and `package.preload`-ing their infra dependencies
  (see `gh_pr_spec.lua`).
- **Headless smoke** (`tests/*_smoke.lua`) — UI/marker behavior that needs a real Neovim.

Gate before every commit:

```bash
./scripts/test.sh && ./scripts/typecheck.sh && stylua --check lua/ tests/
```

## Deferred structural work (with triggers)

| Item | Trigger |
|---|---|
| `editor.lua` vim adapter (buffer/cursor/register out of `comments.lua`) | First busted test needing to stub a workflow's vim calls |
| `markers ↔ ui` intra-layer cycle (both presentation; `markers` queries `ui.active_source_line` at draw time, `ui` calls `markers.refresh` after editor close). Works because both requires are runtime, inside functions — a load-time (top-of-file) require would deadlock the cycle. Code smell, not a layer violation. | Only if either require is ever hoisted to file top; break the `ui → markers` edge with the `LocalReviewChanged` event |
