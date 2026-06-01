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
- Ask free-form questions from the minibuffer.
- Ask from customisable prompt presets for common transformations.
- Draft a commit message from staged changes, then open an editable commit.
- Explain selected compiler/test errors or the symbol at point.
- Open project instruction files such as `AGENTS.md`.
- Send a compact project overview for Codex orientation.
- Run a configurable project build command.
- Open clickable URLs and in-project file references from Codex output.
- Warn when project buffers have unsaved changes before sending prompts.
- Run a health check for Emacs, Codex, vterm, Git, project state, configured
  commands, and terminal startup.
- Enable useful display defaults when `my-codex-global-mode` starts.
- Provide global keys and a Codex menu.

## Requirements

- Emacs 29.1 or newer.
- [`vterm`][vterm].
- OpenAI [Codex CLI][codex] available as `codex`.
- Git, for Git-related commands.

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
| F8 ! | `my-codex-doctor` | Run a health check |
| F8 ? | `my-codex-help` | Show help |

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
| C-c C-t | Enter `vterm` copy mode |
| Page Up / Page Down | Scroll the terminal buffer |

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
(setq my-codex-commit-message-prompt-template
      "Please inspect the staged Git diff using `git diff --cached -- .` and write a concise but comprehensive conventional commit message.

Put only the final commit message between these exact markers:

BEGIN_COMMIT_MESSAGE
<commit message here>
END_COMMIT_MESSAGE

Use an imperative subject and a short explanatory body when useful. Limit each line to %d columns. Do not edit files.\n")
(setq my-codex-commit-message-poll-interval 0.5)
(setq my-codex-commit-message-poll-attempts 120)
(setq my-codex-project-overview-max-files 200)
(setq my-codex-project-overview-tree-max-entries 25)
(setq my-codex-enable-prompt-preview nil)
(setq my-codex-symbol-context-lines 10)

(setq my-codex-prompt-presets
      '(("Refactor" . "Review the following code and refactor it to improve readability and performance without changing its external behaviour.")
        ("Document" . "Write clear docstrings and comments for the following code. Avoid over-commenting obvious logic.")
        ("Test" . "Write focused unit tests for the following code.")
        ("Explain" . "Explain the following code clearly and concisely.")))

(setq my-codex-warn-about-unsaved-project-buffers t)
(setq my-codex-enable-global-auto-revert t)
(setq my-codex-enable-session-links t)
```

When `my-codex-global-mode` is enabled, it also enables trailing whitespace
display and column numbers. When Codex opens beside an edit buffer, that buffer
gets a fill-column indicator at column 80.

`my-codex-enforce-right-side-layout` is disabled by default. Enable it only if
you want my-codex to widen the selected frame and keep the edit/Codex windows at
the configured widths. Leave it disabled when packages such as `shackle` or
`golden-ratio`, your own `display-buffer-alist`, or an external window manager
should control the layout.

In the prompt preset menu (`F8 A`), the `Additional instructions` minibuffer
supports project file completion when the current line starts with `@`. Type
`@` followed by part of a project-relative path, then press `TAB`.

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
press `F8`. The selected text is captured and the live terminal selection is
cleared so it does not extend to the prompt. Use `Left` in the menu to insert
the captured text into the coding window.

Clickable file references are limited to readable files inside the current
project.

## Licence

[Mozilla Public License v2.0][mpl2], also available in [LICENSE][license].

[codex]: https://github.com/openai/codex
[license]: https://github.com/morinim/my_codex/blob/main/LICENSE
[mpl2]: https://www.mozilla.org/MPL/2.0/
[vterm]: https://github.com/akermu/emacs-libvterm
