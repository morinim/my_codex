[![Version](https://img.shields.io/github/tag/morinim/my_codex.svg)][releases]
![elisp](https://img.shields.io/badge/elisp-blue.svg)
![Platform](https://img.shields.io/badge/platform-cross--platform-lightgrey)
[![License](https://img.shields.io/badge/license-MPLv2-blue.svg)][mpl2]

# my-codex.el

```text
┌───────────────┬───────────────┐
│ code          │ agent CLI     │
│ 1  </>        │ >_            │
│ 2  ─────      │ ─────────     │
│ 3  ───────    │ ─────         │
│ 4  }          │ ▌             │
└───────────────┴───────────────┘
```

`my-codex.el` runs the Google Antigravity CLI (`agy`) or OpenAI Codex CLI (`codex`) inside Emacs using `vterm`.

> [!NOTE]
> The package is named `my-codex.el` because it initially supported only the OpenAI Codex CLI. It has since been expanded to support Google Antigravity as a first-class agent.

It keeps your code on the left and the active agent CLI on the right, providing helpers for regions, files, Git diffs, compiler errors, build commands, and commit messages. Agent buffers are project-specific, keeping separate sessions per project.

## Features

- **Multi-Agent CLI Support**: start, resume, and manage sessions with Google Antigravity or OpenAI Codex, with granular workspace write-access control.
- **Side-by-Side Layout**: code on the left, interactive agent terminal on the right.
- **Context-Aware Prompts**: send regions, files, Git diffs, compiler errors, or project structure overviews directly to the agent.
- **Refactoring & Coverage**: draft low-risk refactoring plans for file ranges and analyze implementation files against tests for missing coverage.
- **Integration Tools**: export session transcripts, summarize conversations into Markdown notes, and draft commits or GitHub issues directly from Emacs.
- **Interactive UI**: insert agent output back into your code, and open clickable file references and URLs directly from the terminal.
- **Diagnostics**: verify Emacs, agent binaries, vterm, and Git configuration using the `my-codex-doctor` health check.

The package treats token cost as part of the workflow: it limits generated
project context, warns before oversized prompts, references saved project-file
regions by file and line range, and checks for Codex CLI settings that can
bypass token usage optimisation.

## Requirements

- Emacs 29.1 or newer.
- [`vterm`][vterm].
- [`transient`][transient].
- Google [Antigravity CLI][agy] and/or OpenAI [Codex CLI][codex].
- Git (for Git commands) and GitHub CLI `gh` (for issue creation).

`vterm` is loaded lazily only when an agent session is started.

## Installation

Clone the repository and add it to your Emacs load path:

```elisp
(add-to-list 'load-path "~/.emacs.d/lisp/my_codex")
(require 'my-codex)
(my-codex-global-mode 1)
```

## Key Bindings & Usage

Press `F8` to open the agent command menu.

### Session Management
- `F8 o` / `F8 w` : start/show the default read-only or workspace-write session.
- `F8 S o` / `F8 S w` : select an agent, then start its default read-only or write session.
- `F8 S n` : start or show a named session with a selected agent and access mode.
- `F8 S l` / `F8 S q` / `F8 S r` / `F8 S t` : list open sessions, hide the selected session window, resume a previous session, or view the session dashboard.
- `F8 r` / `F8 q` : resume a previous session, or hide the active agent window.

### Prompts & Refactoring
- `F8 a` / `F8 A` : ask a free-form question or open the customizable prompt preset menu.
- `F8 s` (or `F8 Right`) / `F8 R` : send the selected region, or draft a low-risk refactoring plan for it.
- `F8 Left` / `F8 TAB` : insert agent text into code, or toggle focus between code and agent.
- `F8 f` / `F8 C` / `F8 p` : ask the agent to inspect the current file, analyze test coverage, or orient itself in the project.
- `F8 x` / `F8 e` / `F8 E` : explain the symbol at point, selected error, or Flycheck diagnostics.

### Git & GitHub Workflow
- `F8 g` / `F8 G` : review the current Git diff or the staged Git diff.
- `F8 v` / `F8 V` : view the current or staged Git diff locally.
- `F8 d` / `F8 D` : ediff the current or a changed file against `HEAD`.
- `F8 c` : draft or reuse an agent-generated commit message, edit it, then commit.
- `F8 X` / `F8 M` : export the session transcript, or summarize the session to Markdown notes.
- `F8 t` / `F8 T` : list open GitHub issues, or draft a GitHub issue from the session.

### Diagnostics, Build & Instructions
- `F8 !` : run `my-codex-doctor` diagnostics.
- `F8 i` : open project instruction files (e.g., `AGENTS.md`, `CODEX.md`, `.codex/instructions.md`).
- `F7` : run the project build command.

## Customisation

Configure options via `M-x customize-group RET my-codex RET`.

```elisp
;; Set the default agent profile
(setq my-codex-agent 'antigravity)

;; Ask agents to answer and generate output in a preferred language
(setq my-codex-language "Italian")

;; Customize agent launch commands
(setq my-codex-antigravity-workspace-command "agy --sandbox")
(setq my-codex-antigravity-resume-command "agy resume")

;; Layout & build commands
(setq my-codex-right-width 80)
(setq my-codex-project-build-command "./setup_build")
(setq my-codex-project-instruction-files
      '("AGENTS.md" "CODEX.md" "ANTIGRAVITY.md"
        ".codex/instructions.md" ".antigravity/instructions.md"))

;; Prompt & warning thresholds
(setq my-codex-enable-prompt-preview t)
(setq my-codex-region-send-policy 'prefer-reference)
(setq my-codex-large-prompt-warning-chars 12000)
(setq my-codex-warn-about-unsaved-project-buffers t)
```

## Updating CLI binaries

### Antigravity CLI

The Antigravity CLI (`agy`) has a built-in self-updater. Run the following command to update:

```sh
agy update
```

### Codex CLI

This repository includes optional helper scripts for updating direct GitHub binary installations of Codex CLI:

```sh
./update-codex.sh
```

On Windows, run from PowerShell:

```powershell
.\update-codex.ps1
```

The scripts are intentionally conservative. They only update installations where the active `codex` command points to a direct binary downloaded from the OpenAI Codex GitHub releases, and they refuse common package-manager or wrapper installations such as npm, Homebrew, Snap, Flatpak, Scoop, Chocolatey, or winget. If you installed Codex with a package manager, update it with that package manager instead.

Depending on where `codex` is installed, the Linux script may ask for `sudo`. On Windows, close running Codex sessions first and use an elevated PowerShell session if the destination directory requires administrator rights.

## Companion Skills

The `skills/` directory contains optional agent skills that complement this package. They are provided as editable source, are not installed automatically, and are not required for the Emacs package to work.

Expert users can copy, symlink, modify, or ignore them according to their own agent setup.

Example invocations:

| Skill | Description | Example invocation |
| --- | --- | --- |
| `consilium` | Codebase advisor and plan manager. Finds improvements and writes implementation plans. | `$consilium audit codebase` |
| `grill-me` | Stress-test a plan or design by asking focused questions one at a time. | `$grill-me stress-test this refactoring plan` |
| `handoff` | Create a disposable Markdown context transfer for continuing focused work in another agent session. | `$handoff continue the Firebird SQL refactoring` |

Attribution:

| Skill      | Attribution    | Reference |
| ---        | ---            | ---       |
| `grill-me` | Matt Pocock    | [grill-me: Stress-Test a Plan Before You Build][aihero-grillme] |
| `handoff`  | Matt Pocock    | [handoff: Move Context Between Agent Sessions][aihero-handoff] |

## Licence

[Mozilla Public License v2.0][mpl2], also available in [LICENSE][license].

[agy]: https://antigravity.google/product/antigravity-cli
[aihero-grillme]: https://www.aihero.dev/skills-grill-me
[aihero-handoff]: https://www.aihero.dev/skills-handoff
[codex]: https://github.com/openai/codex
[license]: https://github.com/morinim/my_codex/blob/main/LICENSE
[mpl2]: https://www.mozilla.org/MPL/2.0/
[releases]: https://github.com/morinim/my_codex/releases
[transient]: https://github.com/magit/transient
[vterm]: https://github.com/akermu/emacs-libvterm
