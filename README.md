# my-codex.el

```text
┌───────────────┬───────────────┐
│ code          │ codex         │
│ 1  </>        │ >_            │
│ 2  ─────      │ ─────────     │
│ 3  ───────    │ ─────         │
│ 4  }          │ ▌             │
└───────────────┴───────────────┘
```

`my-codex.el` runs the OpenAI Codex CLI inside Emacs using `vterm`.

It keeps code on the left and Codex on the right, with small helpers for
regions, files, Git diffs, build output, project instructions, and commit
messages. Codex buffers are project-specific, so different projects keep
separate sessions.

## Features

- Start Codex in read-only, workspace-write, or resume mode.
- Use a right-side Codex layout and hide it without disturbing other windows.
- Send selected code, symbols, the current file, Git diffs, or staged Git
  diffs.
- Analyse an implementation alongside its test file for missing coverage.
- Ask free-form questions from the minibuffer.
- Ask from customisable prompt presets for common transformations.
- Draft a commit message from staged changes, then open an editable commit.
- Explain selected compiler/test errors or the symbol at point.
- Open project instruction files such as `AGENTS.md`.
- Send a compact project overview for Codex orientation.
- Run a configurable project build command.
- Open clickable URLs and in-project file references from Codex output.
- Export a Codex session transcript to Markdown.
- Ask Codex to summarize a session transcript into organized Markdown notes.
- Create GitHub issues from Codex session summaries with `gh`.
- Warn when project buffers have unsaved changes before sending prompts.
- Run a health check for Emacs, Codex, vterm, Git, project state, configured
  commands, and terminal startup.
- Optionally enable useful display defaults with `my-codex-global-mode`.
- Provide global keys and a Codex menu.

## Requirements

- Emacs 29.1 or newer.
- [`vterm`][vterm].
- OpenAI [Codex CLI][codex] available as `codex`.
- Git, for Git-related commands.
- GitHub CLI `gh`, for creating GitHub issues from session summaries.

`vterm` is loaded lazily, only when Codex is used.

## Installation

Clone the repository somewhere in your Emacs load path:

```sh
git clone https://github.com/morinim/my_codex.git ~/.emacs.d/lisp/my_codex
```

Then add:

```elisp
(add-to-list 'load-path "~/.emacs.d/lisp/my_codex")
(require 'my-codex)
(my-codex-global-mode 1)
```

## Basic Usage

Start Codex first:

```text
F8 o   start in read-only mode
F8 w   start with workspace-write access
F8 r   resume a previous session
```

Then use the `F8` prefix for everyday actions.

## Key Bindings

| Key | Command | Description |
| --- | --- | --- |
| F7 | `my-codex-project-build` | Run the project build command |
| F8 | `my-codex-transient-preserve-selection` | Open the Codex command menu |

Prefix bindings:

| Key | Command | Description |
| --- | --- | --- |
| F8 o | `my-codex-read-only` | Show/start read-only Codex |
| F8 w | `my-codex-workspace` | Show/start workspace-write Codex |
| F8 r | `my-codex-resume` | Resume a Codex session |
| F8 q | `my-codex-restore-layout` | Hide the Codex window |
| F8 a | `my-codex-ask` | Ask a free-form question |
| F8 A | `my-codex-ask-preset-transient` | Open the prompt preset menu |
| F8 s | `my-codex-send-region` | Send the selected region |
| F8 Right | `my-codex-send-region` | Send the selected region |
| F8 Left | `my-codex-insert-selection-into-code` | Insert selected Codex text into code |
| F8 TAB | `my-codex-toggle-focus` | Toggle focus between code and Codex |
| F8 f | `my-codex-send-current-file` | Ask Codex to inspect the current file |
| F8 C | `my-codex-analyse-test-coverage` | Analyse missing test coverage for the current file |
| F8 x | `my-codex-explain-symbol-at-point` | Explain the symbol at point |
| F8 g | `my-codex-send-git-diff` | Review the current Git diff |
| F8 G | `my-codex-send-git-staged-diff` | Review the staged Git diff |
| F8 d | `my-codex-ediff-current-file-against-head` | Ediff current file against `HEAD` |
| F8 D | `my-codex-ediff-changed-file-against-head` | Choose a changed file to Ediff against `HEAD` |
| F8 m | `my-codex-commit-message-from-diff` | Draft a commit message |
| F8 c | `my-codex-git-commit-with-latest-message` | Edit commit from latest draft |
| F8 e | `my-codex-explain-region-as-error` | Explain a selected error |
| F8 i | `my-codex-open-project-instructions` | Open project instructions |
| F8 p | `my-codex-send-project-overview` | Send project structure and state |
| F8 X | `my-codex-export-session-to-markdown` | Export the session transcript to Markdown |
| F8 M | `my-codex-summarize-session-to-markdown` | Summarize the session into an editable Markdown buffer |
| F8 t | `my-codex-list-open-tickets` | List open GitHub issues in a buffer |
| F8 T | `my-codex-summarize-session-to-github-issue` | Draft a GitHub issue from the session |
| F8 ! | `my-codex-doctor` | Run a health check |

Commit message edit buffer:

| Key | Command |
| --- | --- |
| C-c C-c | Commit staged changes with the edited message |
| C-c C-k | Cancel the commit buffer |

Inside `vterm`:

| Key | Command |
| --- | --- |
| F8 | Open the Codex command menu |
| RET / mouse-1 | Open a clickable URL or file reference |
| Shift Insert | Paste into `vterm` |
| C-c C-t | Toggle `vterm` copy mode |
| Page Up / Page Down | Scroll the terminal buffer |

From the Codex `vterm`, `F8 d` Ediffs the file shown in the window to its left.

## Customisation

Use:

```text
M-x customize-group RET my-codex RET
```

Common options:

```elisp
(setq my-codex-read-only-command
      "codex --sandbox read-only --ask-for-approval on-request")
(setq my-codex-workspace-command
      "codex --sandbox workspace-write --ask-for-approval on-request")
(setq my-codex-resume-command "codex resume")

(setq my-codex-left-width 81)
(setq my-codex-min-right-width 80)
(setq my-codex-right-width 80)
(setq my-codex-enforce-right-side-layout nil)
(setq my-codex-display-buffer-action
      '((display-buffer-in-side-window)
        (side . right)
        (slot . 0)
        (window-width . my-codex--right-window-width)))

(setq my-codex-project-build-command "./setup_build")
(setq my-codex-project-instruction-files
      '("AGENTS.md" "CODEX.md" ".codex/instructions.md"))
(setq my-codex-commit-message-fill-column 76)
(setq my-codex-git-diff-review-prompt
      "Please review the current Git diff using `git diff -- .`. Focus on correctness, regressions, edge cases, naming, and maintainability. Do not edit files unless I explicitly ask.\n")
(setq my-codex-git-staged-diff-review-prompt
      "Please review the staged Git diff using `git diff --cached -- .`. Focus on correctness, regressions, edge cases, and commit readiness. Do not edit files unless I explicitly ask.\n")
(setq my-codex-test-coverage-prompt
      "Please analyse the test coverage for this implementation and its test file.

Identify missing edge cases, unhandled exceptions, logical flaws, and important behaviour that is not currently tested. Do not edit files and do not write tests; only list the missing scenarios.")
(setq my-codex-commit-message-prompt-template
      "Please inspect the staged Git diff using `git diff --cached -- .` and write a concise but comprehensive conventional commit message.

Put only the final commit message between these exact markers:

BEGIN_COMMIT_MESSAGE
<commit message here>
END_COMMIT_MESSAGE

Use an imperative subject and a short explanatory body when useful. Limit each line to %d columns. Do not edit files.\n")
(setq my-codex-commit-message-poll-interval 0.5)
(setq my-codex-commit-message-poll-attempts 120)
(setq my-codex-session-summary-poll-attempts 600)
(setq my-codex-project-overview-max-files 200)
(setq my-codex-project-overview-tree-max-entries 25)
(setq my-codex-enable-prompt-preview nil)
(setq my-codex-symbol-context-lines 10)
(setq my-codex-session-summary-prompt
      "Please summarize, organize, and rationalize this Codex session transcript into useful project notes.

Focus on:
- decisions made
- open questions
- action items
- proposed implementation details
- risks or constraints

Preserve concrete file names, command names, and technical details. Do not edit files.")

(setq my-codex-github-issue-summary-prompt
      "Please summarize this Codex session transcript as a GitHub issue draft.

Focus on:
- concrete problem or feature context
- decisions made
- implementation details
- remaining action items
- risks or constraints

Return a concise issue title and a Markdown issue body. Use this exact format:

Title: <issue title>

Body:
<Markdown issue body>

Preserve concrete file names, command names, and technical details. Do not edit files.")

(setq my-codex-prompt-presets
      '(("Refactor" . "Review the following code and refactor it to improve readability and performance without changing its external behaviour.")
        ("Document" . "Write clear docstrings and comments for the following code. Avoid over-commenting obvious logic.")
        ("Test" . "Write focused unit tests for the following code.")
        ("Explain" . "Explain the following code clearly and concisely.")))

(setq my-codex-warn-about-unsaved-project-buffers t)
(setq my-codex-enable-global-auto-revert t)
(setq my-codex-enable-display-defaults nil)
(setq my-codex-enable-session-links t)
```

When `my-codex-enable-display-defaults` is non-nil,
`my-codex-global-mode` also enables trailing whitespace display and column
numbers. When Codex opens beside an edit buffer, that buffer gets a
fill-column indicator at column 80.

`my-codex-enforce-right-side-layout` is disabled by default. Enable it only if
you want my-codex to widen the selected frame and keep the edit/Codex windows at
the configured widths. Leave it disabled when packages such as `shackle` or
`golden-ratio`, your own `display-buffer-alist`, or an external window manager
should control the layout.

In the prompt preset menu (`F8 A`), the `Additional instructions` minibuffer
supports project file completion when the current line starts with `@`. Type
`@` followed by part of a project-relative path, then press `TAB`.

`my-codex-analyse-test-coverage` (`F8 C`) sends `@` references for the current
buffer and a test file to Codex for read-only coverage analysis. If Projectile
is loaded, it tries `projectile-toggle-between-implementation-and-test` first.
Otherwise it checks common test file names and asks you to choose the test file
when needed.

When `my-codex-enable-prompt-preview` is non-nil, prompts open an editable
`*Codex prompt preview*` buffer before sending. Press `C-c C-c` to send the
edited prompt, or `C-c C-k` to cancel. When Codex is visible, previews open in
the left-hand editing window.

In `my-codex-commit-message-prompt-template`, `%d` is replaced with
`my-codex-commit-message-fill-column`. Keep the `BEGIN_COMMIT_MESSAGE` and
`END_COMMIT_MESSAGE` markers if you want my-codex to extract the generated
message automatically.

For projects with more files than `my-codex-project-overview-max-files`, the
project overview uses a compact tree summary instead of a long flat file list.
`my-codex-project-overview-tree-max-entries` controls how many entries are shown
for each directory in that summary.

## Suggested Codex Configuration

For conservative defaults, configure Codex itself to use read-only mode and
explicit approvals.

In `~/.codex/config.toml`:

```toml
sandbox_mode = "read-only"
approval_policy = "on-request"
approvals_reviewer = "user"
```

## Notes

Use `F8 s` or `F8 Right` for small snippets, and `F8 x` for a quick
explanation of the symbol at point. For larger reviews, prefer `F8 f`, `F8 g`,
or `F8 G`, which ask Codex to inspect files or diffs directly.

To copy text from Codex, use `C-c C-t` in the `vterm` buffer, select text, then
press `F8`. While `vterm-copy-mode` is active, my-codex shows a header-line
reminder. The selected text is captured and the live terminal selection is
cleared so it does not extend to the prompt. Use `Left` in the menu to insert
the captured text into the coding window.

Clickable file references are limited to readable files inside the current
project. A basename reference can inherit a directory prefix from a nearby
preceding line, such as `src/kernel/` followed by `layered_population.tcc:240`.

Use `F8 X` to export the current project-specific Codex session to an editable
Markdown buffer. The export keeps a cleaned raw transcript with project,
source-buffer, and timestamp metadata. If `markdown-mode` is available, the
buffer uses it; otherwise it falls back to `text-mode`.

Use `F8 M` to send the cleaned transcript back to Codex, wait for organized
Markdown notes, and open the generated summary in an editable Markdown buffer.
This is useful before saving the session as project documentation or turning it
into an issue. `my-codex-summarize-session-to-markdown` appends unique
per-request markers to the prompt so older summaries echoed in the transcript
cannot be mistaken for the new response.

Use `F8 T` to ask Codex for a GitHub issue title and body from the current
session transcript. The generated draft opens in an editable buffer. Press
`C-c C-c` to create the issue in the current repository with
`gh issue create --title TITLE --body-file FILE`, or `C-c C-k` to cancel. It
uses unique markers in the same way as
`my-codex-summarize-session-to-markdown`.

Use `F8 t` to list open GitHub issues for the current repository in a
read-only buffer. This runs `gh issue list --state open --limit 100` from the
project root.

## Licence

[Mozilla Public License v2.0][mpl2], also available in [LICENSE][license].

[codex]: https://github.com/openai/codex
[license]: https://github.com/morinim/my_codex/blob/main/LICENSE
[mpl2]: https://www.mozilla.org/MPL/2.0/
[vterm]: https://github.com/akermu/emacs-libvterm
