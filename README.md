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
- Use a two-column layout and restore the previous window layout.
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
- Enable `global-auto-revert-mode` when `my-codex-global-mode` starts.
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
| F8 | `my-codex-map` | Codex prefix key |

Prefix bindings:

| Key | Command | Description |
| --- | --- | --- |
| F8 o | `my-codex-read-only` | Show/start read-only Codex |
| F8 w | `my-codex-workspace` | Show/start workspace-write Codex |
| F8 r | `my-codex-resume` | Resume a Codex session |
| F8 q | `my-codex-restore-layout` | Restore the previous window layout |
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
| F8 m | `my-codex-commit-message-from-diff` | Draft a commit message |
| F8 c | `my-codex-git-commit-with-latest-message` | Edit commit from latest draft |
| F8 e | `my-codex-explain-region-as-error` | Explain a selected error |
| F8 i | `my-codex-open-project-instructions` | Open project instructions |
| F8 p | `my-codex-send-project-overview` | Send project structure and state |
| F8 ? | `my-codex-help` | Show help |

Commit message edit buffer:

| Key | Command |
| --- | --- |
| C-c C-c | Commit staged changes with the edited message |
| C-c C-k | Cancel the commit buffer |

Inside `vterm`:

| Key | Command |
| --- | --- |
| F8 | Use the Codex prefix |
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

(setq my-codex-left-width 80)
(setq my-codex-min-right-width 80)

(setq my-codex-project-build-command "./setup_build")
(setq my-codex-project-instruction-files
      '("AGENTS.md" "CODEX.md" ".codex/instructions.md"))
(setq my-codex-commit-message-fill-column 76)
(setq my-codex-project-overview-max-files 200)
(setq my-codex-prompt-preview-threshold 2000)
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

In the prompt preset menu (`F8 A`), the `Additional instructions` minibuffer
supports project file completion when the current line starts with `@`. Type
`@` followed by part of a project-relative path, then press `TAB`.

Long generated prompts open an editable `*Codex prompt preview*` buffer before
sending. Press `C-c C-c` to send the edited prompt, or `C-c C-k` to cancel.
Project overview prompts always use this preview.

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
use `F8 Left` to insert it into the coding window.

Clickable file references are limited to readable files inside the current
project.

## Licence

[Mozilla Public License v2.0][mpl2], also available in [LICENSE][license].

[codex]: https://github.com/openai/codex
[license]: https://github.com/morinim/my_codex/blob/main/LICENSE
[mpl2]: https://www.mozilla.org/MPL/2.0/
[vterm]: https://github.com/akermu/emacs-libvterm
