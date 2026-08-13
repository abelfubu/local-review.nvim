# local-review.nvim

Neovim plugin for local code review, built for use with coding agents.

> Fork of [ssundarraj/local-review.nvim](https://github.com/ssundarraj/local-review.nvim), heavily extended: multi-line ranges, dual anchors, stale detection, concurrency-safe storage, tests and CI.

Add, edit and delete comments on lines of code while reviewing, then export them as agent-ready text. Use your existing diff-viewer for diffs.

![Comment UI](./screenshots/comment_ui.png)

Use the included [skill](./skills/local-review/SKILL.md) that tells agents how to read comments.

## Features

- **Multi-line comments** — visually select lines, comment covers the range; every line gets a gutter sign, the box renders below the last line, export shows `file.lua:3-5`
- **Context anchors** — comments follow the code when the file changes; both ends of a range are anchored independently
- **Stale detection** — when the anchored code is gone, the comment is marked stale (orange sign, `[stale]` in the title) instead of pointing at the wrong code
- **Git-style gutter marker** — `▎` in `LocalReviewMarker` (blue), grouped with git signs by statuscolumn plugins (e.g. snacks.nvim)
- **Concurrency-safe storage** — two Neovim instances on the same repo merge instead of clobbering each other
- **Safe export** — exported comments are only cleared after a confirmed clipboard write
- **Recoverable delete** — deleting a comment yanks its body to the unnamed register
- **Telescope picker + quickfix list** — with range display and range highlighting
- **Vim help** — `:h local-review`
- **Tested** — busted suite for the core logic, CI runs tests, typecheck and stylua

## Installation

Use your preferred plugin manager. Example with `lazy.nvim`:

```lua
{
  "abelfubu/local-review.nvim",
  config = function()
    require("local_review").setup({
      marker_text = "▎",
      marker_hl = "LocalReviewMarker",
      stale_marker_hl = "LocalReviewStaleMarker",
      keymaps = {
        comment = "<leader>rc",
        delete = "<leader>rd",
        next = "]r",
        prev = "[r",
        export = "<leader>re",
        list = "<leader>rl",
      },
      comment_close_keys = {
        { modes = { "n" }, key = "q" },
        { modes = { "n", "i" }, key = "<C-c>" },
      },
    })
  end,
}
```

See `:h local-review` for the full reference.

### Skill

Copy or symlink the skill into your preferred harness's skills directory.

### Telescope

If you use Telescope, you can open a picker for all review comments in the current repo:

```lua
vim.keymap.set("n", "<leader>lr", function()
  require("local_review.telescope").comments()
end, { desc = "Local Review Picker" })
```

## Commands

- `:LocalReviewComment` open the comment editor for the current line; accepts a line range (`:'<,'>LocalReviewComment`) or a visual selection via the keymap
- `:LocalReviewDelete` delete the comment covering the current line (its body is yanked to the unnamed register first, so `p` recovers it)
- `:LocalReviewNext` / `:LocalReviewPrev` jump between review comments in the current file and echo a one-line summary
- `:LocalReviewExport [path]` copy review comments for a path to the system clipboard in a copy/paste-friendly format, then delete the exported comments if the clipboard copy succeeded. In headless mode the output is printed to stdout so agent skills can read it and the comments are still cleared. If path is omitted, it uses the current repo root when available, otherwise `cwd`.
- `:LocalReviewExportPreserve [path]` copy review comments to the system clipboard without deleting them. In headless mode the output is printed to stdout. If path is omitted, it uses the current repo root when available, otherwise `cwd`.
- `:LocalReviewClear [path]` delete stored review comments for a path. If path is omitted, it uses the current repo root when available, otherwise `cwd`.
- `:LocalReviewList [path]` list review comments in the quickfix list. If path is omitted, it uses the current repo root when available, otherwise `cwd`.

Comments can only be added to real file buffers; scheme-prefixed buffers (`diffview://`, `fugitive://`, `oil://`, ...) are rejected with a notification. The working-tree side of a diff is a real buffer and works fine.

## Skills

- [`local-review`](./skills/local-review/SKILL.md) reads comments with `:LocalReviewExport`, which deletes exported comments by default.
- [`local-review-preserve`](./skills/local-review-preserve/SKILL.md) reads comments with `:LocalReviewExportPreserve`, which leaves comments in place.

## Notes

- The inline comment editor starts in insert mode. `<Enter>` inserts a newline, `<Esc>` returns to normal mode, and `<Enter>` in normal mode (or the configured `comment_close_keys`) accepts the comment and closes the editor. By default `q` closes in normal mode and `<C-c>` closes in normal or insert mode.
- Comments are stored by scope root: repo root when inside git, otherwise the file's parent directory.
- Export and clear can target either a file or a directory.
- Issues/PRs welcome but please open an issue before making a large change.
