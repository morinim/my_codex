# my-codex.el

`my-codex.el` is a small Emacs integration for running the OpenAI Codex CLI inside a `vterm` buffer.

It is designed for a simple two-column workflow:

- source code on the left, fixed to 80 columns;
- Codex on the right, running inside Emacs;
- read-only mode by default;
- explicit commands for reviewing files, diffs, staged changes, compiler errors, and commit messages.

The goal isn't to replace Emacs or the usual development workflow. Codex stays close at hand as an interactive assistant, while Emacs remains the main editing and review environment.


## Features

- Start Codex in a two-column Emacs layout.
- Keep the editing window at a configurable width.
- Automatically resize the frame when it is too narrow.
- Reuse an existing Codex `vterm` buffer when possible.
- Start Codex in read-only or workspace-write mode.
- Resume a previous Codex session.
- Send the selected region to Codex.
- Ask Codex to inspect the current file directly.
- Ask Codex to review the current Git diff.
- Ask Codex to review the staged Git diff.
- Ask Codex to draft a commit message from staged changes.
- Ask Codex to explain selected compiler or test errors.
- Open project instruction files such as `AGENTS.md`.
- Run a configurable project build command via `compile`.
- Provide both key bindings and a simple Emacs menu.


## Requirements

- Emacs with lexical binding support.
- [`vterm`](https://github.com/akermu/emacs-libvterm).
- OpenAI Codex CLI available as `codex`.
- Git, for the Git-related commands.

The package uses standard Emacs libraries:

- `seq`
- `project`
- `compile`
- `easymenu`


## Installation

Clone the repository somewhere in your Emacs load path, for example:

```sh
git clone https://github.com/morinim/my_codex/my-codex.el.git ~/.emacs.d/lisp/my-codex.el
```

Then add it to your Emacs configuration:

```
(add-to-list 'load-path "~/.emacs.d/lisp/my-codex.el")
(require 'my-codex)
```

Alternatively, copy `my-codex.el` directly into your personal Emacs configuration directory and load it from there.

Basic usage

Press:

```
F8 o
```

to open the two-column layout and start Codex in read-only mode.

By default this runs:

```shell
codex --sandbox read-only --ask-for-approval on-request
```

This lets Codex inspect the project, but it must ask before performing actions outside the read-only sandbox.

Press:

```
F8 w
```

to start Codex with workspace-write access:

```shell
codex --sandbox workspace-write --ask-for-approval on-request
```

This is useful when you want Codex to be able to modify files, while still asking for approval when required.


## Key bindings

The package installs a prefix map on `F8`.

| Key  | Command              | Description |
| ---  | ---                  | ---         |
| F8 o | my/codex-read-only | Show or start Codex in read-only mode |
| F8 w | my/codex-workspace | Show or start Codex with workspace-write access |
| F8 r | my/codex-resume | Resume a previous Codex session |
| F8 s | my/codex-send-region | Send the selected region |
| F8 f | my/codex-send-current-file | Ask to inspect the current file |
| F8 g | my/codex-send-git-diff | Ask to review the current Git diff |
| F8 G | my/codex-send-git-staged-diff | Ask to review the staged Git diff |
| F8 m | my/codex-commit-message-from-diff | Ask to draft a commit message |
| F8 e | my/codex-explain-region-as-error | Ask to explain a selected error |
| F8 i | my/codex-open-project-instructions | Open project instruction files |
| F8 ? | my/codex-help | Show a compact help message |

The package also binds:

| Key | Command | Description |
| --- | ---     | ---         |
| F7  | my/codex-project-build | Run the configured project build command |


Two-column layout

The default layout is:

```
+--------------------------------------+--------------------------------------+
|                                      |                                      |
|  Source code                         |  Codex in vterm                      |
|  80 columns                          |                                      |
|                                      |                                      |
+--------------------------------------+--------------------------------------+
```

The left editing window defaults to 80 columns. The Codex window defaults to a minimum width of 80 columns.

If the current frame is too narrow, the package tries to resize it automatically.


## Customisation

All user options are available through the my-codex customisation group:

```
M-x customize-group RET my-codex RET
```

- Buffer name
    ```elisp
    (setq my/codex-buffer-name "*codex*")
    ```
- Read-only command
    ```elisp
    (setq my/codex-read-only-command
          "codex --sandbox read-only --ask-for-approval on-request")
    ```
- Workspace-write command
    ```elisp
    (setq my/codex-workspace-command
          "codex --sandbox workspace-write --ask-for-approval on-request")
    ```
- Resume command
    ```elisp
    (setq my/codex-resume-command "codex resume")
    ```
- Layout widths
    ```elisp
    (setq my/codex-left-width 80)
    (setq my/codex-min-right-width 80)
    ```
- Project instruction files
    By default, the command `my/codex-open-project-instructions` looks for:
    ```elisp
    '("AGENTS.md" "CODEX.md" ".codex/instructions.md")
    ```

    You can customise this list:

    ```elisp
    (setq my/codex-project-instruction-files
          '("AGENTS.md" ".codex/instructions.md"))
    ```
- Build command
    The default project build command is:
    ```elisp
    (setq my/codex-project-build-command "./setup_build")
    ```

    For a CMake project, you might use:
    ```elisp
    (setq my/codex-project-build-command "cmake --build build")
    ```

    or

    ```elisp
    (setq my/codex-project-build-command "ninja -C build")
    ```


## Suggested Codex configuration

For a conservative default, configure Codex itself to run in read-only mode with explicit approvals.

In `~/.codex/config.toml`:

```toml
sandbox_mode = "read-only"
approval_policy = "on-request"
approvals_reviewer = "user"
```

This keeps Codex useful but controlled: it can inspect the project, but it must ask before modifying files.


## Typical workflow

- Start Codex in read-only mode: `F8 o`
- Ask Codex to inspect the current file: `F8 f`
- Review the current diff: `F8 g`
- Review staged changes before committing: `F8 G`
- Draft a commit message: `F8 m`
- Build the project: `F7`


## Notes

For small snippets, `F8 s` is convenient.

For larger code reviews, prefer `F8 f`, `F8 g` or `F8 G`. These commands ask Codex to inspect files or Git diffs directly from the project instead of pasting large amounts of text into the terminal.

This is usually more reliable and keeps the interaction cleaner.

## Licence

[Mozilla Public License v2.0][mpl2] (also available in the accompanying [LICENSE][license] file).




[license]: https://github.com/morinim/my_codex/blob/master/LICENSE
