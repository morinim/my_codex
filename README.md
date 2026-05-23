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

`my-codex.el` runs the OpenAI Codex CLI inside Emacs, using a `vterm` buffer.

It provides a simple two-column workflow:

- source code on the left, fixed at 80 columns;
- Codex on the right;
- read-only mode by default;
- commands for files, diffs, staged changes, compiler errors, and commit messages.

Codex stays close at hand as an assistant, while Emacs remains the main environment for editing and reviewing code.

## Features

- Start Codex in a two-column Emacs layout.
- Keep the editing window at a configurable width.
- Reuse an existing Codex `vterm` buffer.
- Start Codex in read-only or workspace-write mode.
- Resume a previous Codex session.
- Send selected code to Codex with a directional shortcut.
- Insert selected Codex text back into the coding window.
- Toggle focus between the coding window and the Codex terminal.
- Ask Codex to inspect the current file.
- Review current or staged Git diffs.
- Draft commit messages from staged changes.
- Explain selected compiler or test errors.
- Open project instruction files such as `AGENTS.md`.
- Run a configurable project build command.
- Provide key bindings and an Emacs menu.

## Requirements

- Emacs with lexical binding support.
- [`vterm`](https://github.com/akermu/emacs-libvterm).
- OpenAI [Codex CLI][codex] available as `codex`.
- Git, for Git-related commands.

The package also uses these standard Emacs libraries:

- `seq`
- `project`
- `compile`
- `easymenu`

## Installation

Clone the repository somewhere in your Emacs load path:

```sh
git clone https://github.com/morinim/my_codex.git ~/.emacs.d/lisp/my_codex
```

Then add it to your Emacs configuration:

```elisp
(add-to-list 'load-path "~/.emacs.d/lisp/my_codex")
(require 'my-codex)
```

Alternatively, copy `my-codex.el` into a directory already in your `load-path`.

## Basic usage

Open Codex in read-only mode:

```text
F8 o
```

This runs:

```sh
codex --sandbox read-only --ask-for-approval on-request
```

Open Codex with workspace-write access:

```text
F8 w
```

This runs:

```sh
codex --sandbox workspace-write --ask-for-approval on-request
```

Workspace-write mode allows Codex to modify files, while still asking for approval when required.

## Key bindings

The package installs a prefix map on `F8`.

| Key | Command | Description |
| --- | --- | --- |
| F8 o | `my/codex-read-only` | Show/start Codex in read-only mode |
| F8 w | `my/codex-workspace` | Show/start Codex with workspace-write access |
| F8 r | `my/codex-resume` | Resume a previous Codex session |
| F8 s | `my/codex-send-region` | Send the selected region to Codex |
| F8 Right | `my/codex-send-region` | Directional shortcut for sending selected code to Codex |
| F8 Left | `my/codex-insert-selection-into-code` | Insert selected Codex text into the coding window |
| F8 TAB | `my/codex-toggle-focus` | Toggle focus between code and Codex |
| F8 f | `my/codex-send-current-file` | Ask Codex to inspect the current file |
| F8 g | `my/codex-send-git-diff` | Ask Codex to review the current Git diff |
| F8 G | `my/codex-send-git-staged-diff` | Ask Codex to review the staged Git diff |
| F8 m | `my/codex-commit-message-from-diff` | Draft a commit message from staged changes |
| F8 e | `my/codex-explain-region-as-error` | Explain a selected compiler or test error |
| F8 i | `my/codex-open-project-instructions` | Open project instruction files |
| F8 ? | `my/codex-help` | Show help |

The package also binds:

| Key | Command | Description |
| --- | --- | --- |
| F7 | `my/codex-project-build` | Run the configured build command |
| Shift Insert | `vterm-yank` | Paste into `vterm` |
| C-c C-t | `vterm-copy-mode` | Enter `vterm` copy mode |

## Two-column layout

The default layout is:

```text
+--------------------------------------+--------------------------------------+
| Source code                          | Codex in vterm                       |
| 80 columns                           |                                      |
+--------------------------------------+--------------------------------------+
```

The left window defaults to 80 columns. The Codex window also defaults to a minimum width of 80 columns.

If the frame is too narrow, the package tries to resize it automatically.

## Customisation

All options are available from:

```text
M-x customize-group RET my-codex RET
```

Common options:

```elisp
(setq my/codex-buffer-name "*codex*")

(setq my/codex-read-only-command
      "codex --sandbox read-only --ask-for-approval on-request")

(setq my/codex-workspace-command
      "codex --sandbox workspace-write --ask-for-approval on-request")

(setq my/codex-resume-command "codex resume")

(setq my/codex-left-width 80)
(setq my/codex-min-right-width 80)

(setq my/codex-project-build-command "./setup_build")
```

Project instruction files are searched by `my/codex-open-project-instructions`.

Default value:

```elisp
'("AGENTS.md" "CODEX.md" ".codex/instructions.md")
```

Example customisation:

```elisp
(setq my/codex-project-instruction-files
      '("AGENTS.md" ".codex/instructions.md"))
```

For a CMake project, you may want:

```elisp
(setq my/codex-project-build-command "cmake --build build")
```

or:

```elisp
(setq my/codex-project-build-command "ninja -C build")
```

## Suggested Codex configuration

For a conservative default, configure Codex itself to use read-only mode and explicit approvals.

In `~/.codex/config.toml`:

```toml
sandbox_mode = "read-only"
approval_policy = "on-request"
approvals_reviewer = "user"
```

This allows Codex to inspect the project, but requires approval before modifying files.


## Typical workflow

- Start Codex: `F8 o`
- Inspect the current file: `F8 f`
- Send selected code to Codex: `F8 Right`
- Insert selected Codex text back into code: `F8 Left`
- Review the current diff: `F8 g`
- Review staged changes: `F8 G`
- Draft a commit message: `F8 m`
- Build the project: `F7`


## Notes

Use `F8 s` / `F8 Right` for small snippets.

For larger reviews, prefer `F8 f`, `F8 g`, or `F8 G`. These commands ask Codex to inspect files or Git diffs directly, instead of pasting large amounts of text into the terminal.

Send/review commands expect a running Codex session. Start one first with `F8 o`, `F8 w`, or `F8 r`.


## Licence

[Mozilla Public License v2.0][mpl2], also available in the accompanying [LICENSE][license] file.

[codex]: https://github.com/openai/codex
[license]: https://github.com/morinim/my_codex/blob/main/LICENSE
[mpl2]: https://www.mozilla.org/MPL/2.0/