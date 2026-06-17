;;; my-codex.el --- Codex integration -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Manlio Morini

;; Author: Manlio Morini
;; Keywords: tools, convenience
;; URL: https://github.com/morinim/my_codex
;; Version: 0.16.0
;; Package-Requires: ((emacs "29.1") (vterm "0") (transient "0"))

;; This file is not part of GNU Emacs.

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at https://mozilla.org/MPL/2.0/.

;;; Commentary:

;; my-codex.el runs OpenAI Codex CLI or Google Antigravity inside an Emacs
;; vterm buffer.  It provides a two-column layout, project-specific agent
;; sessions, helpers for Git diffs, selected regions, and compiler errors.

;;; Code:

(require 'compile)
(require 'ansi-color)
(require 'browse-url)
(require 'cl-lib)
(require 'ediff)
(require 'easymenu)
(require 'project)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'thingatpt)
(require 'transient)
(require 'xref)

(autoload 'vterm-mode "vterm" nil t)
(autoload 'vterm-send-string "vterm")
(autoload 'vterm-send-return "vterm")
(autoload 'vterm-yank "vterm" nil t)
(autoload 'vterm-copy-mode "vterm" nil t)
(declare-function markdown-mode "markdown-mode")
(declare-function projectile-toggle-between-implementation-and-test "projectile")
(defvar vterm-mode-map)
(defvar vterm-copy-mode-map)
(defvar vterm-copy-mode)

(defgroup my-codex nil
  "Customisation options for the Codex development tool."
  :group 'convenience
  :prefix "my-codex-")

(defconst my-codex-default-buffer-name "*codex*"
  "Default name of the vterm buffer used for Codex.")

(defcustom my-codex-buffer-name my-codex-default-buffer-name
  "Name of the vterm buffer used for Codex."
  :type 'string
  :group 'my-codex)

(defcustom my-codex-read-only-command
  "codex --sandbox read-only --ask-for-approval on-request"
  "Command used to start Codex in read-only mode."
  :type 'string
  :group 'my-codex)

(defcustom my-codex-workspace-command
  "codex --sandbox workspace-write --ask-for-approval on-request"
  "Command used to start Codex with workspace write access."
  :type 'string
  :group 'my-codex)

(defcustom my-codex-resume-command
  "codex resume"
  "Command used to resume a previous Codex session."
  :type 'string
  :group 'my-codex)

(defcustom my-codex-antigravity-read-only-command
  (concat "agy --sandbox -i \"System policy: "
          "This is a read-only session. "
          "Do not write/edit files or execute commands "
          "that alter the codebase.\"")
  "Command used to start Antigravity in read-only mode."
  :type 'string
  :group 'my-codex)

(defcustom my-codex-antigravity-workspace-command
  "agy"
  "Command used to start Antigravity with workspace write access."
  :type 'string
  :group 'my-codex)

(defcustom my-codex-antigravity-resume-command
  "agy resume"
  "Command used to resume a previous Antigravity session."
  :type 'string
  :group 'my-codex)

(defcustom my-codex-agent 'codex
  "Agent profile used by default Codex commands.
Commands such as `my-codex-read-only', `my-codex-workspace', and
`my-codex-resume' use this profile.  Named sessions can choose a
different profile interactively."
  :type 'symbol
  :group 'my-codex)

(defcustom my-codex-agent-profiles
  '((codex
     :label "Codex"
     :buffer-prefix "codex"
     :read-only-command my-codex-read-only-command
     :workspace-command my-codex-workspace-command
     :resume-command my-codex-resume-command)
    (antigravity
     :label "Antigravity"
     :buffer-prefix "agy"
     :read-only-command my-codex-antigravity-read-only-command
     :workspace-command my-codex-antigravity-workspace-command
     :resume-command my-codex-antigravity-resume-command))
  "Agent profiles available to my-codex.
Each entry has the form:

  (ID :label LABEL
      :buffer-prefix PREFIX
      :read-only-command COMMAND
      :workspace-command COMMAND
      :resume-command COMMAND)

ID is a symbol used for configuration and session metadata.  PREFIX is
used in buffer names, so different agents can have sessions with the
same project and session name without colliding.  COMMAND may be either
a string or a symbol whose value is a string."
  :type 'sexp
  :group 'my-codex)

(defcustom my-codex-left-width 81
  "Width of the editing window text area in the Codex right-side layout."
  :type 'natnum
  :group 'my-codex)

(defcustom my-codex-min-right-width 80
  "Minimum width of the Codex vterm window."
  :type 'natnum
  :group 'my-codex)

(defcustom my-codex-right-width 80
  "Target width of the Codex vterm window."
  :type 'natnum
  :group 'my-codex)

(defcustom my-codex-enforce-right-side-layout nil
  "When non-nil, resize the frame and edit window for right-side Codex.
Leave this nil when another package or window manager controls window sizes."
  :type 'boolean
  :group 'my-codex)

(defcustom my-codex-display-buffer-action
  '((display-buffer-in-side-window)
    (side . right)
    (slot . 0)
    (window-width . my-codex--right-window-width))
  "Display action used for Codex buffers.

The value is passed to `display-buffer'.  Customise this when you prefer a
different placement, such as a bottom side window or a dedicated frame."
  :type 'sexp
  :group 'my-codex)

(defcustom my-codex-project-instruction-files
  '("AGENTS.md" "CODEX.md" "ANTIGRAVITY.md" ".codex/instructions.md" ".antigravity/instructions.md")
  "Candidate project instruction files for Codex/Antigravity."
  :type '(repeat string)
  :group 'my-codex)

(defcustom my-codex-project-build-command nil
  "Command used to build the current project.
When nil, use `compile-command'."
  :type '(choice (const :tag "Use compile-command" nil)
                 string)
  :group 'my-codex)

(defcustom my-codex-commit-message-fill-column 76
  "Maximum line width for generated commit messages."
  :type 'natnum
  :group 'my-codex)

(defcustom my-codex-git-diff-review-prompt
  "Review the current Git diff using `git diff -- .`. Focus on correctness, regressions, edge cases, naming and maintainability. Do not edit unless asked\n"
  "Prompt used by `my-codex-send-git-diff'."
  :type 'string
  :group 'my-codex)

(defcustom my-codex-git-staged-diff-review-prompt
  "Review the staged Git diff using `git diff --cached -- .`. Focus on correctness, regressions, edge cases and commit readiness. Do not edit unless asked\n"
  "Prompt used by `my-codex-send-git-staged-diff'."
  :type 'string
  :group 'my-codex)

(defcustom my-codex-test-coverage-prompt
  "Analyse test coverage for this implementation and its test file.

Identify missing edge cases, unhandled exceptions, logical flaws and important behaviour that is not currently tested. Do not edit or write tests; list missing scenarios only."
  "Prompt used by `my-codex-analyse-test-coverage'."
  :type 'string
  :group 'my-codex)

(defcustom my-codex-refactor-plan-prompt
  "Draft a step-by-step, low-risk refactoring plan for this code.

Do not provide rewritten code or patches.

Focus on:
- current responsibilities and likely coupling
- small refactoring steps in a safe order
- potential breaking changes
- tests or checks to run after each step
- rollback points
- assumptions that need confirmation before editing

Finish with the smallest safe first edit worth making."
  "Prompt used by `my-codex-plan-refactor-region'."
  :type 'string
  :group 'my-codex)

(defcustom my-codex-commit-message-prompt-template
  "Inspect the staged Git diff using `git diff --cached -- .` and write a concise conventional commit message.

Put only the final commit message between these exact markers:

BEGIN_COMMIT_MESSAGE
<commit message here>
END_COMMIT_MESSAGE

Use an imperative subject and a short explanatory body when useful. Limit each line to %d columns. Do not edit files.\n"
  "Prompt template used by `my-codex-commit-message-from-diff'.
The literal substring `%d' is replaced with
`my-codex-commit-message-fill-column'.  Keep the
BEGIN_COMMIT_MESSAGE and END_COMMIT_MESSAGE markers if you want
`my-codex-latest-commit-message' to extract the generated message."
  :type 'string
  :group 'my-codex)

(defcustom my-codex-commit-message-poll-interval 0.5
  "Seconds between checks for a generated Codex commit message."
  :type 'number
  :group 'my-codex)

(defcustom my-codex-commit-message-poll-attempts 120
  "Maximum number of checks for a generated Codex commit message."
  :type 'natnum
  :group 'my-codex)

(defcustom my-codex-warn-about-unsaved-project-buffers t
  "When non-nil, warn before sending prompts if project buffers are unsaved."
  :type 'boolean
  :group 'my-codex)

(defcustom my-codex-enable-global-auto-revert t
  "When non-nil, enable `global-auto-revert-mode' with `my-codex-global-mode'."
  :type 'boolean
  :group 'my-codex)

(defcustom my-codex-enable-display-defaults nil
  "When non-nil, enable editing display helpers with `my-codex-global-mode'."
  :type 'boolean
  :group 'my-codex)

(defcustom my-codex-enable-vterm-integration t
  "When non-nil, enable vterm helpers with `my-codex-global-mode'."
  :type 'boolean
  :group 'my-codex)

(defcustom my-codex-enable-session-links t
  "When non-nil, make URLs and file references clickable in Codex buffers."
  :type 'boolean
  :group 'my-codex)

(defcustom my-codex-project-overview-max-files 80
  "Maximum project file count before project overviews use a tree summary."
  :type 'natnum
  :group 'my-codex)

(defcustom my-codex-project-overview-tree-max-entries 12
  "Maximum entries shown for each directory in project overview tree summaries."
  :type 'natnum
  :group 'my-codex)

(defcustom my-codex-enable-prompt-preview nil
  "When non-nil, show an editable preview before sending prompts."
  :type 'boolean
  :group 'my-codex)

(defcustom my-codex-large-prompt-warning-chars 12000
  "Prompt size in characters that requires confirmation before sending.
When nil, do not warn about large prompts."
  :type '(choice (const :tag "Do not warn" nil)
                 natnum)
  :group 'my-codex)

(defcustom my-codex-large-prompt-error-chars nil
  "Prompt size in characters that is refused before sending.
When nil, do not enforce a hard prompt size limit."
  :type '(choice (const :tag "No hard limit" nil)
                 natnum)
  :group 'my-codex)

(defcustom my-codex-region-reference-threshold-chars 12000
  "Region size in characters that sends a file reference instead of text.
This only applies to file-visiting buffers.  When nil, always send
selected region text from `my-codex-send-region'."
  :type '(choice (const :tag "Always send selected text" nil)
                 natnum)
  :group 'my-codex)

(defcustom my-codex-symbol-context-lines 10
  "Number of surrounding lines to include when explaining a symbol."
  :type 'natnum
  :group 'my-codex)

(defcustom my-codex-symbol-include-xref-context t
  "When non-nil, include xref definition and reference context for symbols."
  :type 'boolean
  :group 'my-codex)

(defcustom my-codex-symbol-xref-definition-limit 2
  "Maximum number of xref definitions to include for symbol explanations."
  :type 'natnum
  :group 'my-codex)

(defcustom my-codex-symbol-xref-reference-limit 8
  "Maximum number of xref references to include for symbol explanations."
  :type 'natnum
  :group 'my-codex)

(defcustom my-codex-symbol-xref-context-lines 4
  "Number of surrounding lines to include for each xref location."
  :type 'natnum
  :group 'my-codex)

(defcustom my-codex-session-summary-prompt
  "Summarise this Codex session transcript into useful project notes.

Focus on:
- decisions made
- open questions
- action items
- proposed implementation details
- risks or constraints

Preserve concrete file names, command names, and technical details. Do not edit files."
  "Prompt used by `my-codex-summarize-session-to-markdown'."
  :type 'string
  :group 'my-codex)

(defcustom my-codex-github-issue-summary-prompt
  "Summarise this Codex session transcript as a GitHub issue draft.

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

Preserve concrete file names, command names, and technical details. Do not edit files."
  "Prompt used by `my-codex-summarize-session-to-github-issue'."
  :type 'string
  :group 'my-codex)

(defcustom my-codex-session-summary-poll-interval
  my-codex-commit-message-poll-interval
  "Seconds between checks for generated Codex session summaries."
  :type 'number
  :group 'my-codex)

(defcustom my-codex-session-summary-poll-attempts 600
  "Maximum number of checks for a generated Codex session summary."
  :type 'natnum
  :group 'my-codex)

(defcustom my-codex-doctor-terminal-timeout 3
  "Seconds to wait for a diagnostic vterm process to start."
  :type 'number
  :group 'my-codex)

(defcustom my-codex-prompt-presets
  '(("Refactor" . "Review the following code and refactor it to improve readability and performance without changing its external behaviour.")
    ("Document" . "Write clear docstrings and comments for the following code. Avoid over-commenting obvious logic.")
    ("Test" . "Write focused unit tests for the following code.")
    ("Explain" . "Explain the following code clearly and concisely."))
  "Prompt presets offered by `my-codex-ask-with-preset'.
Each entry is a cons cell of the form (NAME . PROMPT)."
  :type '(alist :key-type string :value-type string)
  :group 'my-codex)

(defvar my-codex--auto-revert-enabled-by-mode nil
  "Non-nil when `my-codex-global-mode' enabled `global-auto-revert-mode'.")

(defvar my-codex--vterm-integration-enabled-by-mode nil
  "Non-nil when `my-codex-global-mode' enabled vterm integration.")

(defvar my-codex--saved-show-trailing-whitespace nil
  "Previous default value of `show-trailing-whitespace'.")

(defvar my-codex--saved-column-number-mode nil
  "Previous value of `column-number-mode'.")

(defvar my-codex--display-defaults-enabled-by-mode nil
  "Non-nil when `my-codex-global-mode' changed display defaults.")

(defconst my-codex--display-show-trailing-whitespace-value t
  "Default `show-trailing-whitespace' value set by `my-codex-global-mode'.")

(defconst my-codex--display-column-number-mode-value t
  "Default `column-number-mode' value set by `my-codex-global-mode'.")

(defvar-local my-codex--prompt-preview-origin-window nil
  "Window selected before opening the current prompt preview.")

(defvar-local my-codex--edit-fill-column-indicator-state nil
  "Previous fill-column indicator state saved by my-codex.")

(defvar my-codex--edit-fill-column-indicator-buffers nil
  "Buffers whose fill-column indicator state is temporarily managed.")

(defvar-local my-codex--commit-message-request-marker nil
  "Marker for the start of the latest Codex commit message request.")

(defvar-local my-codex--commit-message-request-signature nil
  "Staged diff signature used for the latest Codex commit message request.")

(defvar-local my-codex--commit-buffer-staged-signature nil
  "Staged diff signature for the current editable commit message.")

(defvar-local my-codex--commit-message-wait-timer nil
  "Active timer waiting for a Codex commit message.")

(defvar-local my-codex--session-summary-request-marker nil
  "Marker for the start of the latest Codex session summary request.")

(defvar-local my-codex--session-summary-wait-timer nil
  "Active timer waiting for a Codex session summary.")

(defvar-local my-codex-session-id nil
  "Identifier for the Codex session owned by the current buffer.")

(defvar-local my-codex-session-name nil
  "Human-readable Codex session name for the current buffer.")

(defvar-local my-codex-session-project-root nil
  "Project root associated with the current Codex session buffer.")

(defvar-local my-codex-session-access-mode nil
  "Access mode used for the current Codex session buffer.")

(defvar-local my-codex-session-agent nil
  "Agent profile used for the current Codex session buffer.")

(defvar-local my-codex--github-issue-creation-in-progress nil
  "Non-nil while the current GitHub issue draft is being submitted.")

(defvar-local my-codex--github-issue-repository nil
  "GitHub repository selected for the current issue draft.")

(defvar my-codex--captured-selection nil
  "Text captured before opening a transient from an active region.")

(defvar my-codex--vterm-integration-keymap-bindings nil
  "Previous vterm key bindings replaced by `my-codex-vterm-integration-mode'.")

(defvar my-codex--vterm-copy-mode-lighter :unset
  "Previous `vterm-copy-mode' lighter before my-codex changed it.")

(cl-defstruct (my-codex-vterm-backend
               (:constructor my-codex--make-vterm-backend (buffer-name)))
  "Backend implementation that runs Codex in a vterm buffer."
  buffer-name)

(defvar my-codex--backend nil
  "Current backend instance for the active project Codex session.")

(defvar my-codex--backends (make-hash-table :test #'equal)
  "Backend instances keyed by Codex buffer name.")

(defvar my-codex--project-active-agents (make-hash-table :test #'equal)
  "Agent profile identifiers keyed by project root.")

(cl-defgeneric my-codex-backend-start
    (backend project-root command &optional session-name agent access-mode)
  "Start BACKEND in PROJECT-ROOT with COMMAND and return its buffer.
When SESSION-NAME is non-nil, mark the buffer as that named session.")

(cl-defgeneric my-codex-backend-send (backend prompt)
  "Send PROMPT through BACKEND.")

(cl-defgeneric my-codex-backend-live-p (backend)
  "Return non-nil when BACKEND has a live Codex process.")

(defun my-codex--backend-buffer-name (backend)
  "Return BACKEND's buffer name."
  (my-codex-vterm-backend-buffer-name backend))

(defun my-codex--backend-buffer (backend)
  "Return BACKEND's buffer, or nil when it does not exist."
  (get-buffer (my-codex--backend-buffer-name backend)))

(defun my-codex--backend-for-buffer-name (buffer-name)
  "Return the backend for BUFFER-NAME."
  (let ((backend (gethash buffer-name my-codex--backends)))
    (unless (my-codex-vterm-backend-p backend)
      (setq backend (my-codex--make-vterm-backend buffer-name))
      (puthash buffer-name backend my-codex--backends))
    (setq my-codex--backend backend)
    backend))

(defun my-codex--current-backend ()
  "Return the backend for the current project default Codex session."
  (my-codex--backend-for-buffer-name (my-codex-current-buffer-name)))

(defun my-codex--agent-profile (agent)
  "Return the profile for AGENT, or raise an error."
  (or (alist-get agent my-codex-agent-profiles)
      (user-error "Unknown my-codex agent profile: %s" agent)))

(defun my-codex--agent-ids ()
  "Return configured agent profile identifiers."
  (mapcar #'car my-codex-agent-profiles))

(defun my-codex--agent-label (agent)
  "Return the display label for AGENT."
  (or (plist-get (my-codex--agent-profile agent) :label)
      (symbol-name agent)))

(defun my-codex--agent-buffer-prefix (agent)
  "Return the buffer prefix for AGENT."
  (let ((prefix (plist-get (my-codex--agent-profile agent) :buffer-prefix)))
    (cond
     ((and (stringp prefix) (not (string-empty-p prefix))) prefix)
     ((symbolp prefix) (symbol-name prefix))
     (t (symbol-name agent)))))

(defun my-codex--agent-command (agent access-mode)
  "Return AGENT's command string for ACCESS-MODE."
  (let* ((profile (my-codex--agent-profile agent))
         (key (pcase access-mode
                ('read-only :read-only-command)
                ('workspace-write :workspace-command)
                ('resume :resume-command)
                (_ (user-error "Unknown access mode: %s" access-mode))))
         (command (plist-get profile key)))
    (cond
     ((and (stringp command) (not (string-empty-p command))) command)
     ((and (symbolp command)
           (boundp command)
           (stringp (symbol-value command))
           (not (string-empty-p (symbol-value command))))
      (symbol-value command))
     ((symbolp command)
      (user-error "Agent %s command %s is not a non-empty string"
                  agent command))
     (t
      (user-error "Agent %s has no %s command" agent access-mode)))))

(defun my-codex--read-agent ()
  "Read and return an agent profile identifier."
  (intern
   (completing-read
    "Agent: "
    (mapcar #'symbol-name (my-codex--agent-ids))
    nil t nil nil (symbol-name my-codex-agent))))

(cl-defmethod my-codex-backend-live-p ((backend my-codex-vterm-backend))
  "Return non-nil when BACKEND's vterm process is live."
  (when-let (buffer (my-codex--backend-buffer backend))
    (process-live-p (get-buffer-process buffer))))

(defun my-codex--session-access-mode (command &optional agent)
  "Return the session access mode represented by COMMAND."
  (let ((agent (or agent my-codex-agent)))
    (cond
     ((equal command (my-codex--agent-command agent 'workspace-write))
      'workspace-write)
     ((equal command (my-codex--agent-command agent 'read-only))
      'read-only)
     ((equal command (my-codex--agent-command agent 'resume)) 'resume)
     (t 'custom))))

(defun my-codex--default-session-id (project-root &optional agent)
  "Return the default session identifier for PROJECT-ROOT."
  (format "%s:default:%s"
          (or agent my-codex-agent)
          (substring (secure-hash 'sha1 (file-truename project-root)) 0 8)))

(defun my-codex--session-id (project-root session-name &optional agent)
  "Return the named session identifier for PROJECT-ROOT and SESSION-NAME."
  (format "%s:session:%s:%s"
          (or agent my-codex-agent)
          (substring (secure-hash 'sha1 (file-truename project-root)) 0 8)
          (my-codex--safe-session-name session-name)))

(defun my-codex--mark-session
    (buffer session-id session-name project-root access-mode agent)
  "Mark BUFFER as SESSION-ID named SESSION-NAME for PROJECT-ROOT."
  (with-current-buffer buffer
    (setq-local my-codex-session-id session-id)
    (setq-local my-codex-session-name session-name)
    (setq-local my-codex-session-project-root
                (file-name-as-directory (file-truename project-root)))
    (setq-local my-codex-session-access-mode access-mode)
    (setq-local my-codex-session-agent agent)))

(defun my-codex--mark-default-session
    (buffer project-root access-mode &optional agent)
  "Mark BUFFER as the default Codex session for PROJECT-ROOT."
  (let ((agent (or agent my-codex-agent)))
    (my-codex--mark-session
     buffer
     (my-codex--default-session-id project-root agent)
     "default"
     project-root
     access-mode
     agent)))

(defun my-codex--mark-named-session
    (buffer session-name project-root access-mode &optional agent)
  "Mark BUFFER as SESSION-NAME for PROJECT-ROOT."
  (let ((agent (or agent my-codex-agent)))
    (my-codex--mark-session
     buffer
     (my-codex--session-id project-root session-name agent)
     session-name
     project-root
     access-mode
     agent)))

(cl-defmethod my-codex-backend-start
  ((backend my-codex-vterm-backend) project-root command
   &optional session-name agent access-mode)
  "Start BACKEND's vterm process in PROJECT-ROOT with COMMAND."
  (let* ((agent (or agent my-codex-agent))
         (access-mode
          (or access-mode (my-codex--session-access-mode command agent)))
         (default-directory project-root)
         (buffer-name (my-codex--backend-buffer-name backend))
         (buffer (get-buffer-create buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'vterm-mode)
        (vterm-mode))
      (setq-local show-trailing-whitespace nil)
      (when my-codex-enable-session-links
        (my-codex-session-links-mode 1))
      (let ((proc (get-buffer-process buffer)))
        (unless (process-live-p proc)
          (user-error "Failed to start vterm process in %s" buffer-name))
        (set-process-query-on-exit-flag proc nil)
        (goto-char (point-max))
        (vterm-send-string (my-codex--shell-command-and-exit command))
        (vterm-send-return)))
    (if session-name
        (my-codex--mark-named-session
         buffer session-name project-root access-mode agent)
      (my-codex--mark-default-session
       buffer project-root access-mode agent))
    buffer))

(cl-defmethod my-codex-backend-send
  ((backend my-codex-vterm-backend) prompt)
  "Send PROMPT through BACKEND's vterm buffer."
  (let ((buffer (or (my-codex--backend-buffer backend)
                    (user-error "No %s buffer found"
                                (my-codex--backend-buffer-name backend)))))
    (with-current-buffer buffer
      (goto-char (point-max))
      (vterm-send-string prompt t)
      (vterm-send-return))))

(defun my-codex--selected-window-is-codex-p ()
  "Return non-nil if the selected window shows Codex."
  (eq (selected-window)
      (ignore-errors
        (my-codex-visible-window))))

(defun my-codex--vterm-shell-name ()
  "Return the configured vterm shell executable name, if known."
  (let ((shell (or (and (boundp 'vterm-shell)
                        (let ((value (symbol-value 'vterm-shell)))
                          (and (stringp value)
                               (not (string-empty-p value))
                               value)))
                   shell-file-name
                   "")))
    (file-name-nondirectory
     (replace-regexp-in-string "\\\\" "/" shell))))

(defun my-codex--shell-command-and-exit (command)
  "Return shell text that runs COMMAND, then exits with its status."
  (let ((shell (downcase (my-codex--vterm-shell-name))))
    (cond
     ((member shell '("cmd" "cmd.exe" "cmdproxy" "cmdproxy.exe"))
      (format "%s\nexit %%ERRORLEVEL%%" command))
     ((member shell '("powershell" "powershell.exe" "pwsh" "pwsh.exe"))
      (format (concat "%s\n"
                      "if ($LASTEXITCODE -ne $null) { exit $LASTEXITCODE }\n"
                      "if ($?) { exit 0 } else { exit 1 }")
              command))
     (t
      (format "%s\nstatus=$?\nexit $status" command)))))


(defun my-codex--right-window-width (window)
  "Resize WINDOW to the target Codex width when enforcement is enabled."
  (when my-codex-enforce-right-side-layout
    (my-codex--resize-window-to-body-width
     window
     (max my-codex-min-right-width my-codex-right-width))))

(defun my-codex--display-buffer-action-alist ()
  "Return the alist part of `my-codex-display-buffer-action', if any."
  (when (and (consp my-codex-display-buffer-action)
             (listp (cdr my-codex-display-buffer-action)))
    (cdr my-codex-display-buffer-action)))

(defun my-codex--right-side-action-p ()
  "Return non-nil when Codex is configured for a right side window."
  (eq (alist-get 'side (my-codex--display-buffer-action-alist)) 'right))

(defun my-codex--right-layout-width ()
  "Return the minimum frame width for the default right-side layout."
  (+ my-codex-left-width
     (max my-codex-min-right-width my-codex-right-width)))

(defun my-codex--enforce-right-side-layout-p ()
  "Return non-nil when Codex should enforce the right-side layout."
  (and my-codex-enforce-right-side-layout
       (my-codex--right-side-action-p)))

(defun my-codex--fit-frame-to-right-layout ()
  "Widen the selected frame enough for the default right-side layout."
  (when (my-codex--enforce-right-side-layout-p)
    (let ((required-width (my-codex--right-layout-width)))
      (when (< (frame-width) required-width)
        (condition-case nil
            (progn
              (set-frame-width (selected-frame) (+ required-width 8))
              (redisplay t))
          (error nil)))
      (when (< (frame-width) required-width)
        (user-error "Frame is too narrow for Codex layout")))))

(defun my-codex--resize-window-to-body-width (window width)
  "Resize WINDOW to WIDTH body columns when possible."
  (when (and (window-live-p window)
             (integerp width)
             (> width 0))
    (let ((delta (- width (window-body-width window))))
      (when (not (zerop delta))
        (ignore-errors
          (window-resize window delta t 'ignore))))))

(defun my-codex--apply-display-window-width (window)
  "Apply the configured Codex display width to WINDOW."
  (when (window-live-p window)
    (pcase (alist-get 'window-width (my-codex--display-buffer-action-alist))
      ((and width (pred integerp))
       (my-codex--resize-window-to-body-width window width))
      (`(body-columns . ,width)
       (my-codex--resize-window-to-body-width window width))
      ((and width (pred functionp))
       (funcall width window)))))

(defun my-codex--resize-edit-window-for-right-layout (edit-window term-window)
  "Keep EDIT-WINDOW wide enough for the default right-side Codex layout."
  (when (and (my-codex--enforce-right-side-layout-p)
             (window-live-p edit-window)
             (window-live-p term-window)
             (> (window-left-column term-window)
                (window-left-column edit-window))
             (< (window-body-width edit-window)
                my-codex-left-width))
    (my-codex--resize-window-to-body-width edit-window
                                            my-codex-left-width)))

(defun my-codex--refresh-edit-fill-column-indicator ()
  "Refresh the fill-column indicator after window layout changes."
  (when (and my-codex--edit-fill-column-indicator-state
             (fboundp 'display-fill-column-indicator-mode)
             (bound-and-true-p display-fill-column-indicator-mode))
    (display-fill-column-indicator-mode -1)
    (display-fill-column-indicator-mode 1)))

(defun my-codex--edit-window-codex-visible-p (window frame)
  "Return non-nil if WINDOW's Codex buffer is visible in FRAME."
  (when-let ((buffer (window-parameter window 'my-codex-term-buffer)))
    (and (buffer-live-p buffer)
         (get-buffer-window buffer frame))))

(defun my-codex--restore-edit-fill-column-indicator (buffer)
  "Restore BUFFER's fill-column indicator state saved by my-codex."
  (setq my-codex--edit-fill-column-indicator-buffers
        (delq buffer my-codex--edit-fill-column-indicator-buffers))
  (when (and (buffer-live-p buffer)
             (fboundp 'display-fill-column-indicator-mode))
    (with-current-buffer buffer
      (when my-codex--edit-fill-column-indicator-state
        (let ((mode (plist-get my-codex--edit-fill-column-indicator-state
                               :mode))
              (column-local
               (plist-get my-codex--edit-fill-column-indicator-state
                          :column-local))
              (column
               (plist-get my-codex--edit-fill-column-indicator-state
                          :column)))
          (remove-hook 'window-configuration-change-hook
                       #'my-codex--refresh-edit-fill-column-indicator
                       t)
          (if column-local
              (setq-local display-fill-column-indicator-column column)
            (kill-local-variable 'display-fill-column-indicator-column))
          (display-fill-column-indicator-mode (if mode 1 -1))
          (setq my-codex--edit-fill-column-indicator-state nil))))))

(defun my-codex--apply-edit-fill-column-indicator (window)
  "Show a fill-column indicator in WINDOW's buffer."
  (when (and (fboundp 'display-fill-column-indicator-mode)
             (window-live-p window))
    (with-current-buffer (window-buffer window)
      (unless my-codex--edit-fill-column-indicator-state
        (setq-local my-codex--edit-fill-column-indicator-state
                    (list
                     :mode
                     (bound-and-true-p display-fill-column-indicator-mode)
                     :column-local
                     (local-variable-p
                      'display-fill-column-indicator-column)
                     :column
                     display-fill-column-indicator-column)))
      (cl-pushnew (current-buffer)
                  my-codex--edit-fill-column-indicator-buffers)
      (setq-local display-fill-column-indicator-column 80)
      (add-hook 'window-configuration-change-hook
                #'my-codex--refresh-edit-fill-column-indicator
                nil
                t)
      (display-fill-column-indicator-mode 1))))

(defun my-codex--active-edit-fill-column-indicator-buffers ()
  "Return buffers shown in live Codex edit windows."
  (let (buffers)
    (dolist (frame (frame-list))
      (dolist (window (window-list frame 'no-minibuf))
        (when (and (window-parameter window 'my-codex-edit-window)
                   (my-codex--edit-window-codex-visible-p window frame))
          (cl-pushnew (window-buffer window) buffers))))
    buffers))

(defun my-codex--restore-inactive-edit-fill-column-indicator-buffers ()
  "Restore managed buffers no longer shown in a live Codex edit window."
  (let ((active-buffers
         (my-codex--active-edit-fill-column-indicator-buffers)))
    (dolist (buffer (copy-sequence
                     my-codex--edit-fill-column-indicator-buffers))
      (unless (memq buffer active-buffers)
        (my-codex--restore-edit-fill-column-indicator buffer)))))

(defun my-codex--refresh-edit-fill-column-indicator-windows (frame)
  "Apply Codex fill-column indicators to marked edit windows in FRAME."
  (dolist (window (window-list frame 'no-minibuf))
    (when (window-parameter window 'my-codex-edit-window)
      (let ((previous-buffer
             (window-parameter window 'my-codex-edit-buffer))
            (current-buffer (window-buffer window)))
        (unless (eq previous-buffer current-buffer)
          (my-codex--restore-edit-fill-column-indicator previous-buffer))
        (if (my-codex--edit-window-codex-visible-p window frame)
            (progn
              (set-window-parameter window 'my-codex-edit-buffer
                                    current-buffer)
              (my-codex--apply-edit-fill-column-indicator window))
          (my-codex--restore-edit-fill-column-indicator current-buffer)
          (my-codex--restore-edit-fill-column-indicator previous-buffer)
          (set-window-parameter window 'my-codex-edit-buffer nil)
          (set-window-parameter window 'my-codex-edit-window nil)
          (set-window-parameter window 'my-codex-term-buffer nil)))))
  (my-codex--restore-inactive-edit-fill-column-indicator-buffers))

(defun my-codex--set-edit-fill-column-indicator-window (window)
  "Mark WINDOW as the Codex edit window and update its indicator."
  (let ((previous-buffer (window-parameter window 'my-codex-edit-buffer))
        (current-buffer (window-buffer window)))
    (unless (eq previous-buffer current-buffer)
      (my-codex--restore-edit-fill-column-indicator previous-buffer))
    (set-window-parameter window 'my-codex-edit-buffer current-buffer)
    (my-codex--apply-edit-fill-column-indicator window)))

(defun my-codex--enable-edit-fill-column-indicator (edit-window term-window)
  "Show a fill-column indicator in EDIT-WINDOW."
  (when (and (fboundp 'display-fill-column-indicator-mode)
             (window-live-p edit-window)
             (window-live-p term-window)
             (not (eq (window-buffer edit-window)
                      (window-buffer term-window))))
    (set-window-parameter edit-window 'my-codex-edit-window t)
    (set-window-parameter edit-window 'my-codex-term-buffer
                          (window-buffer term-window))
    (add-hook 'window-buffer-change-functions
              #'my-codex--refresh-edit-fill-column-indicator-windows)
    (my-codex--set-edit-fill-column-indicator-window edit-window)))

(defun my-codex--safe-root-name (root)
  "Return a buffer-name-safe representation of ROOT."
  (replace-regexp-in-string
   "[^[:alnum:]._-]+" "!"
   (directory-file-name (file-truename root))))

(defun my-codex-project-root ()
  "Return the current project root, or `default-directory' if not in a project."
  (file-name-as-directory
   (if-let (project (project-current))
       (project-root project)
     default-directory)))

(defun my-codex--project-key (&optional root)
  "Return the stable project key for ROOT or the current project."
  (file-name-as-directory
   (file-truename (or root (my-codex-project-root)))))

(defun my-codex--active-agent (&optional root)
  "Return the active agent profile for ROOT or the current project."
  (or (gethash (my-codex--project-key root)
               my-codex--project-active-agents)
      my-codex-agent))

(defun my-codex--set-active-agent (agent &optional root)
  "Record AGENT as the active agent for ROOT or the current project."
  (puthash (my-codex--project-key root)
           agent
           my-codex--project-active-agents))

(defun my-codex-current-buffer-name (&optional agent)
  "Return the buffer name for the current Codex session."
  (let ((agent (or agent (my-codex--active-agent))))
    (if-let* ((project (project-current))
              (root (file-truename (project-root project)))
              (name (file-name-nondirectory (directory-file-name root)))
              (hash (substring (secure-hash 'sha1 root) 0 8)))
        (format "*%s:%s:%s*"
                (my-codex--agent-buffer-prefix agent) name hash)
      (if (and (eq agent 'codex)
               (not (equal my-codex-buffer-name
                           my-codex-default-buffer-name)))
          my-codex-buffer-name
        (let* ((root (file-truename (my-codex-project-root)))
               (name (file-name-nondirectory (directory-file-name root)))
               (hash (substring (secure-hash 'sha1 root) 0 8)))
          (format "*%s:%s:%s*"
                  (my-codex--agent-buffer-prefix agent) name hash))))))

(defun my-codex--normalise-session-name (name)
  "Return a normalised Codex session NAME, or raise an error."
  (let ((normalised (string-trim name)))
    (when (string-empty-p normalised)
      (user-error "Session name cannot be empty"))
    (when (string-equal normalised "default")
      (user-error "Use F8 S o or F8 S w for the default session"))
    normalised))

(defun my-codex--safe-session-name (name)
  "Return a buffer-name-safe representation of session NAME."
  (let* ((normalised (my-codex--normalise-session-name name))
         (slug (replace-regexp-in-string
                "[^[:alnum:]._-]+" "!"
                normalised))
         (hash (substring (secure-hash 'sha1 normalised) 0 8)))
    (format "%s-%s" slug hash)))

(defun my-codex-session-buffer-name (session-name &optional agent)
  "Return the buffer name for SESSION-NAME in the current project."
  (let* ((safe-name (my-codex--safe-session-name session-name))
         (default-name (my-codex-current-buffer-name agent)))
    (if (string-suffix-p "*" default-name)
        (concat (substring default-name 0 -1) ":" safe-name "*")
      (format "%s:%s" default-name safe-name))))

(defconst my-codex-sessions-buffer-name "*Codex sessions*"
  "Buffer name used to display open Codex sessions.")

(defvar-keymap my-codex-sessions-mode-map
  :parent tabulated-list-mode-map
  "RET" #'my-codex-sessions-visit
  "<mouse-1>" #'my-codex-sessions-mouse-visit)

(define-derived-mode my-codex-sessions-mode tabulated-list-mode
  "Codex sessions"
  "Major mode for selecting open Codex sessions."
  (setq tabulated-list-format
        [("Buffer" 32 t)
         ("Agent" 12 t)
         ("Name" 18 t)
         ("Access" 16 t)
         ("Project" 0 t)])
  (setq tabulated-list-padding 2)
  (tabulated-list-init-header))

(defun my-codex--visible-session-window (&optional source-window)
  "Return the visible Codex session window for SOURCE-WINDOW."
  (let* ((source-window (or source-window (selected-window)))
         (term-buffer (window-parameter source-window
                                        'my-codex-term-buffer)))
    (or (and (buffer-live-p term-buffer)
             (get-buffer-window term-buffer nil))
        (seq-find
         (lambda (window)
           (with-current-buffer (window-buffer window)
             (bound-and-true-p my-codex-session-id)))
         (window-list nil 'no-minibuf)))))

(defun my-codex--edit-windows-for-session-buffer (buffer)
  "Return edit windows associated with Codex session BUFFER."
  (seq-filter
   (lambda (window)
     (eq (window-parameter window 'my-codex-term-buffer) buffer))
   (window-list nil 'no-minibuf)))

(defun my-codex--switch-active-session-buffer (buffer)
  "Switch the active Codex session window to BUFFER."
  (let* ((source-window (selected-window))
         (term-window (my-codex--visible-session-window source-window))
         (previous-buffer (and (window-live-p term-window)
                               (window-buffer term-window))))
    (if (window-live-p term-window)
        (progn
          (set-window-buffer term-window buffer)
          (dolist (window
                   (my-codex--edit-windows-for-session-buffer
                    previous-buffer))
            (set-window-parameter window 'my-codex-term-buffer buffer))
          (select-window term-window))
      (select-window
       (or (display-buffer buffer my-codex-display-buffer-action)
           (user-error "Failed to display %s" (buffer-name buffer)))))))

(defun my-codex-sessions-visit ()
  "Visit the Codex session at point."
  (interactive)
  (let* ((buffer-name (tabulated-list-get-id))
         (buffer (and buffer-name (get-buffer buffer-name))))
    (unless buffer
      (user-error "No Codex session on this line"))
    (my-codex--switch-active-session-buffer buffer)))

(defun my-codex-sessions-mouse-visit (event)
  "Visit the Codex session clicked in EVENT."
  (interactive "e")
  (let* ((end (event-end event))
         (window (posn-window end))
         (point (posn-point end)))
    (when (and (windowp window) (integer-or-marker-p point))
      (select-window window)
      (goto-char point)
      (my-codex-sessions-visit))))

(defun my-codex--session-buffers ()
  "Return open Codex session buffers."
  (seq-sort-by
   #'buffer-name #'string<
   (seq-filter
    (lambda (buffer)
      (with-current-buffer buffer
        (and (bound-and-true-p my-codex-session-id)
             (when-let ((process (get-buffer-process buffer)))
               (process-live-p process)))))
    (buffer-list))))

;;;###autoload
(defun my-codex-list-sessions ()
  "List open Codex session buffers."
  (interactive)
  (let ((buffers (my-codex--session-buffers)))
    (if (null buffers)
        (message "No open Codex sessions.")
      (with-current-buffer (get-buffer-create my-codex-sessions-buffer-name)
        (my-codex-sessions-mode)
        (setq tabulated-list-entries
              (mapcar
               (lambda (buffer)
                 (let (agent name access root)
                   (with-current-buffer buffer
                     (setq agent my-codex-session-agent
                           name my-codex-session-name
                           access my-codex-session-access-mode
                           root my-codex-session-project-root))
                   (list (buffer-name buffer)
                         (vector
                          (buffer-name buffer)
                          (if agent (symbol-name agent) "")
                          (or name "")
                          (if access (symbol-name access) "")
                          (or root "")))))
               buffers))
        (tabulated-list-print t)
        (pop-to-buffer (current-buffer))))))

(defun my-codex-modified-project-buffers ()
  "Return modified file-visiting buffers belonging to the current project."
  (if-let (project (project-current))
      (seq-filter (lambda (buf)
                    (and (buffer-file-name buf)
                         (buffer-modified-p buf)))
                  (project-buffers project))
    (let ((root (file-truename default-directory)))
      (seq-filter (lambda (buf)
                    (when-let (file (buffer-file-name buf))
                      (and (buffer-modified-p buf)
                           (file-in-directory-p (file-truename file) root))))
                  (buffer-list)))))

(defun my-codex--warn-about-unsaved-project-buffers ()
  "Display a non-blocking warning if project buffers have unsaved changes."
  (when my-codex-warn-about-unsaved-project-buffers
    (when-let (buffers (my-codex-modified-project-buffers))
      (message "Codex warning: unsaved buffer(s): %s"
               (mapconcat #'buffer-name buffers ", ")))))

(defun my-codex-two-column-layout-with-command
    (codex-command &optional focus-term session-name agent access-mode)
  "Display Codex and run CODEX-COMMAND if the backend is not running.
If FOCUS-TERM is non-nil, leave the cursor focused on the terminal window.
When SESSION-NAME is non-nil, use that named session instead of default.
AGENT identifies the agent profile used for buffer names and metadata."
  (cl-labels
      ((display-codex-buffer
        (buffer)
        (or (display-buffer buffer my-codex-display-buffer-action)
            (user-error "Failed to display %s" (buffer-name buffer)))))
    (let* ((agent (or agent (my-codex--active-agent)))
           (session-name (when session-name
                           (my-codex--normalise-session-name session-name)))
           (buffer-name (if session-name
                            (my-codex-session-buffer-name session-name agent)
                          (my-codex-current-buffer-name agent)))
           (backend (my-codex--backend-for-buffer-name buffer-name))
           (project-root (my-codex-project-root))
           (existing-buf (get-buffer buffer-name)))
      (unless session-name
        (my-codex--set-active-agent agent project-root))
      (my-codex--fit-frame-to-right-layout)

      (when (and existing-buf
                 (not (my-codex-backend-live-p backend)))
        (with-current-buffer existing-buf
          (rename-buffer
           (generate-new-buffer-name
            (format "%s<old>" buffer-name))))
        (setq existing-buf nil))

      (let* ((edit-window (selected-window))
             (term-buffer (or existing-buf
                              (get-buffer-create buffer-name)))
             (term-window (display-codex-buffer term-buffer)))
        (my-codex--apply-display-window-width term-window)
        (my-codex--resize-edit-window-for-right-layout edit-window term-window)
        (my-codex--enable-edit-fill-column-indicator edit-window term-window)
        (select-window term-window)
        (when (and existing-buf
                   (my-codex-backend-live-p backend))
          (set-window-buffer term-window existing-buf))
        (unless (and existing-buf
                     (my-codex-backend-live-p backend))
          (my-codex-backend-start
           backend project-root codex-command session-name agent access-mode))

        (if focus-term
            (select-window term-window)
          (when (window-live-p edit-window)
            (select-window edit-window)))))))

;;;###autoload
(defun my-codex-restore-layout ()
  "Hide visible windows showing the current Codex buffer."
  (interactive)
  (let* ((buffer-name (my-codex-current-buffer-name))
         (windows (get-buffer-window-list buffer-name nil t)))
    (unless windows
      (user-error "Codex window is not visible"))
    (dolist (window windows)
      (when (window-live-p window)
        (quit-window nil window)))
    (message "Codex window hidden")))

(defun my-codex--session-layout-buffer ()
  "Return the Codex buffer associated with the selected session layout."
  (or (window-parameter (selected-window) 'my-codex-term-buffer)
      (when (bound-and-true-p my-codex-session-id)
        (current-buffer))
      (get-buffer (my-codex-current-buffer-name))
      (user-error "Codex window is not visible")))

;;;###autoload
(defun my-codex-restore-session-layout ()
  "Hide visible windows showing the selected Codex session buffer."
  (interactive)
  (let* ((buffer (my-codex--session-layout-buffer))
         (windows (get-buffer-window-list buffer nil t)))
    (unless windows
      (user-error "Codex window is not visible"))
    (dolist (window windows)
      (when (window-live-p window)
        (quit-window nil window)))
    (message "Codex window hidden")))

;;;###autoload
(defun my-codex-read-only ()
  "Show Codex, starting it in read-only mode if needed."
  (interactive)
  (my-codex-two-column-layout-with-command
   (my-codex--agent-command my-codex-agent 'read-only)
   nil nil my-codex-agent 'read-only))

;;;###autoload
(defun my-codex-workspace ()
  "Show Codex, starting it with workspace write access if needed."
  (interactive)
  (my-codex-two-column-layout-with-command
   (my-codex--agent-command my-codex-agent 'workspace-write)
   nil nil my-codex-agent 'workspace-write))

;;;###autoload
(defun my-codex-default-read-only (agent)
  "Show the default AGENT session in read-only mode."
  (interactive (list (my-codex--read-agent)))
  (my-codex-two-column-layout-with-command
   (my-codex--agent-command agent 'read-only)
   nil nil agent 'read-only))

;;;###autoload
(defun my-codex-default-workspace (agent)
  "Show the default AGENT session with workspace write access."
  (interactive (list (my-codex--read-agent)))
  (my-codex-two-column-layout-with-command
   (my-codex--agent-command agent 'workspace-write)
   nil nil agent 'workspace-write))

(defun my-codex--read-session-access-mode ()
  "Read and return an access mode for a new named session."
  (pcase (completing-read
          "Session access: "
          '("read-only" "workspace-write")
          nil t nil nil "read-only")
    ("read-only" 'read-only)
    ("workspace-write" 'workspace-write)))

;;;###autoload
(defun my-codex-new-session (name agent &optional access-mode)
  "Start or show a named Codex session NAME using AGENT and ACCESS-MODE.
For compatibility, AGENT may also be a command string when ACCESS-MODE is nil."
  (interactive
   (list
    (read-string "Session name: ")
    (my-codex--read-agent)
    (my-codex--read-session-access-mode)))
  (let ((session-name (my-codex--normalise-session-name name)))
    (if (and (stringp agent) (null access-mode))
        (my-codex-two-column-layout-with-command
         agent nil session-name my-codex-agent)
      (my-codex-two-column-layout-with-command
       (my-codex--agent-command agent access-mode)
       nil session-name agent access-mode))))

;;;###autoload
(defun my-codex-resume ()
  "Show Codex, resuming a previous session if needed and focusing the window."
  (interactive)
  (my-codex-two-column-layout-with-command
   (my-codex--agent-command my-codex-agent 'resume)
   t nil my-codex-agent 'resume))

(defun my-codex-buffer ()
  "Return the current project's Codex backend buffer, or raise an error."
  (let* ((backend (my-codex--current-backend))
         (buffer-name (my-codex--backend-buffer-name backend))
         (buffer (get-buffer buffer-name)))
    (unless buffer
      (user-error "No %s buffer found" buffer-name))
    (unless (my-codex-backend-live-p backend)
      (user-error "No running Codex process in %s" buffer-name))
    buffer))

(defun my-codex--session-buffer ()
  "Return the current project's Codex session buffer, or raise an error."
  (let* ((buffer-name (my-codex-current-buffer-name))
         (buffer (get-buffer buffer-name)))
    (unless buffer
      (user-error "No %s buffer found" buffer-name))
    buffer))

(defun my-codex--session-export-buffer-name (root)
  "Return the session export buffer name for ROOT."
  (format "*Codex session export:%s*" (my-codex--safe-root-name root)))

(defun my-codex--session-summary-buffer-name (root)
  "Return the session summary buffer name for ROOT."
  (format "*Codex session summary:%s*" (my-codex--safe-root-name root)))

(defun my-codex--unique-output-markers (name)
  "Return unique begin and end output markers for NAME."
  (let ((suffix (substring
                 (secure-hash
                  'sha1
                  (format "%s-%s-%s" name (float-time) (random)))
                 0 12)))
    (cons (format "BEGIN_%s_%s" name suffix)
          (format "END_%s_%s" name suffix))))

(defun my-codex--marked-output-instructions (begin-marker end-marker placeholder)
  "Return prompt instructions for marked output.
BEGIN-MARKER and END-MARKER delimit the output.  PLACEHOLDER is
shown between them as an example."
  (format "Put only the final answer between these exact markers:\n\n%s\n%s\n%s"
          begin-marker
          placeholder
          end-marker))

(defun my-codex--strip-terminal-control-codes (text)
  "Return TEXT without common terminal control codes."
  (let ((cleaned (ansi-color-filter-apply text)))
    (setq cleaned
          (replace-regexp-in-string
           "\x1b\\][^\a\x1b]*\\(\a\\|\x1b\\\\\\)" "" cleaned))
    (setq cleaned
          (replace-regexp-in-string
           "\x1b\\[[0-?]*[ -/]*[@-~]" "" cleaned))
    (setq cleaned
          (replace-regexp-in-string "\r" "" cleaned))
    cleaned))

(defun my-codex--clean-session-transcript (text)
  "Return cleaned Codex session transcript TEXT."
  (with-temp-buffer
    (insert (my-codex--strip-terminal-control-codes text))
    (goto-char (point-min))
    (while (re-search-forward "[[:blank:]]+$" nil t)
      (replace-match ""))
    (goto-char (point-min))
    (while (re-search-forward "\n\\{4,\\}" nil t)
      (replace-match "\n\n\n"))
    (string-trim (buffer-string))))

(defun my-codex-session-transcript ()
  "Return the cleaned transcript from the current project's Codex buffer."
  (let ((buffer (my-codex--session-buffer)))
    (with-current-buffer buffer
      (my-codex--clean-session-transcript
       (buffer-substring-no-properties (point-min) (point-max))))))

(defun my-codex--session-export-mode ()
  "Use a suitable mode for a session export buffer."
  (if (require 'markdown-mode nil t)
      (markdown-mode)
    (text-mode)))

(defun my-codex--markdown-code-fence (text)
  "Return a Markdown code fence delimiter that does not occur in TEXT."
  (let ((max-length 2)
        (start 0))
    (while (string-match "`+" text start)
      (setq max-length (max max-length
                            (- (match-end 0) (match-beginning 0)))
            start (match-end 0)))
    (make-string (1+ max-length) ?`)))

(defun my-codex--insert-session-export-markdown (transcript root source-buffer)
  "Insert Markdown for TRANSCRIPT from ROOT and SOURCE-BUFFER."
  (let ((fence (my-codex--markdown-code-fence transcript)))
    (insert "# Codex Session\n\n")
    (insert (format "- Project root: `%s`\n" root))
    (insert (format "- Source buffer: `%s`\n" source-buffer))
    (insert (format "- Exported: `%s`\n\n"
                    (format-time-string "%Y-%m-%d %H:%M:%S %Z")))
    (insert "## Transcript\n\n")
    (insert fence "text\n")
    (insert transcript)
    (insert "\n" fence "\n")))

(defun my-codex--session-summary-prompt
    (summary-prompt transcript begin-marker end-marker &optional placeholder)
  "Return a marked session summary prompt.
SUMMARY-PROMPT describes the requested summary.  TRANSCRIPT is the
cleaned Codex transcript.  BEGIN-MARKER and END-MARKER delimit the answer.
PLACEHOLDER is shown inside the output markers."
  (let ((fence (my-codex--markdown-code-fence transcript)))
    (format "%s\n\n%s\n\nRaw transcript:\n\n%stext\n%s\n%s"
            summary-prompt
            (my-codex--marked-output-instructions
             begin-marker end-marker (or placeholder "<Markdown notes here>"))
            fence
            transcript
            fence)))

;;;###autoload
(defun my-codex-export-session-to-markdown ()
  "Export the current project's Codex session transcript to Markdown."
  (interactive)
  (let* ((root (my-codex-project-root))
         (buffer (my-codex--session-buffer))
         (transcript (my-codex-session-transcript))
         (export-buffer
          (get-buffer-create (my-codex--session-export-buffer-name root))))
    (when (string-empty-p transcript)
      (user-error "Codex session transcript is empty"))
    (with-current-buffer export-buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (my-codex--insert-session-export-markdown
         transcript root (buffer-name buffer))
        (goto-char (point-min)))
      (my-codex--session-export-mode))
    (pop-to-buffer export-buffer)
    (message "Codex session exported to Markdown.")))

;;;###autoload
(defun my-codex-summarize-session-to-markdown ()
  "Ask Codex to summarize the current session transcript as Markdown notes.
Open the generated notes in an editable Markdown buffer when they are ready."
  (interactive)
  (let* ((root (my-codex-project-root))
         (buffer (my-codex-buffer))
         (transcript (my-codex-session-transcript))
         (markers (my-codex--unique-output-markers "SESSION_SUMMARY"))
         (begin-marker (car markers))
         (end-marker (cdr markers)))
    (when (string-empty-p transcript)
      (user-error "Codex session transcript is empty"))
    (let ((start-point (with-current-buffer buffer
                         (copy-marker (point-max))))
          (prompt (my-codex--session-summary-prompt
                   my-codex-session-summary-prompt
                   transcript begin-marker end-marker)))
      (with-current-buffer buffer
        (setq my-codex--session-summary-request-marker start-point))
      (my-codex-send-prompt prompt)
      (my-codex--wait-for-session-summary
       buffer start-point root begin-marker end-marker)
      (message "Asked Codex to summarize the session; waiting to open editor."))))

(require 'my-codex-prompts)
(require 'my-codex-git)
(require 'my-codex-github)
(require 'my-codex-links)
(require 'my-codex-doctor)
(require 'my-codex-vterm)

;; Prefix keymap for Codex commands.
(defvar-keymap my-codex-map
  :doc "Prefix keymap for Codex commands."
  "o"       #'my-codex-read-only
  "w"       #'my-codex-workspace
  "S"       #'my-codex-session-transient
  "r"       #'my-codex-resume
  "q"       #'my-codex-restore-layout
  "a"       #'my-codex-ask
  "A"       #'my-codex-ask-preset-transient
  "s"       #'my-codex-send-region
  "<right>" #'my-codex-send-region
  "R"       #'my-codex-plan-refactor-region
  "<left>"  #'my-codex-insert-selection-into-code
  "f"       #'my-codex-send-current-file
  "C"       #'my-codex-analyse-test-coverage
  "x"       #'my-codex-explain-symbol-at-point
  "g"       #'my-codex-send-git-diff
  "G"       #'my-codex-send-git-staged-diff
  "v"       #'my-codex-show-git-diff
  "V"       #'my-codex-show-git-staged-diff
  "d"       #'my-codex-ediff-current-file-against-head
  "D"       #'my-codex-ediff-changed-file-against-head
  "c"       #'my-codex-git-commit-with-latest-message
  "e"       #'my-codex-explain-region-as-error
  "i"       #'my-codex-open-project-instructions
  "p"       #'my-codex-send-project-overview
  "X"       #'my-codex-export-session-to-markdown
  "M"       #'my-codex-summarize-session-to-markdown
  "t"       #'my-codex-list-open-tickets
  "T"       #'my-codex-summarize-session-to-github-issue
  "!"       #'my-codex-doctor
  "TAB"     #'my-codex-toggle-focus
  "<tab>"   #'my-codex-toggle-focus)

;;;###autoload
(transient-define-prefix my-codex-session-transient ()
  "Show Codex session commands."
  [["Default session"
    ("o" "Read-only" my-codex-default-read-only)
    ("w" "Workspace" my-codex-default-workspace)]
   ["Session"
    ("l" "List" my-codex-list-sessions)
    ("n" "New named" my-codex-new-session)
    ("r" "Resume" my-codex-resume)
    ("q" "Hide Codex" my-codex-restore-session-layout)]])

;;;###autoload
(transient-define-prefix my-codex-transient ()
  "Show Codex commands."
  [["Session"
    ("o" "Read-only" my-codex-read-only)
    ("w" "Workspace" my-codex-workspace)
    ("S" "Sessions" my-codex-session-transient)
    ("r" "Resume" my-codex-resume)
    ("q" "Hide Codex" my-codex-restore-layout)
    ("<tab>" "Toggle focus" my-codex-toggle-focus)]
   ["Send"
    ("a" "Ask" my-codex-ask)
    ("A" "Preset menu" my-codex-ask-preset-transient)
    ("s" "Region" my-codex-send-region)
    ("<right>" "Region" my-codex-send-region)
    ("R" "Refactor plan" my-codex-plan-refactor-region)
    ("<left>" "Insert selection" my-codex-insert-selection-into-code)
    ("f" "Current file" my-codex-send-current-file)
    ("C" "Coverage gaps" my-codex-analyse-test-coverage)
    ("x" "Explain symbol" my-codex-explain-symbol-at-point)
    ("p" "Project overview" my-codex-send-project-overview)]
   ["Git"
    ("g" "Review diff" my-codex-send-git-diff)
    ("G" "Review staged diff" my-codex-send-git-staged-diff)
    ("v" "View diff" my-codex-show-git-diff)
    ("V" "View staged diff" my-codex-show-git-staged-diff)
    ("d" "Ediff current file" my-codex-ediff-current-file-against-head)
    ("D" "Ediff changed file" my-codex-ediff-changed-file-against-head)
    ("c" "Commit with Codex message" my-codex-git-commit-with-latest-message)]
   ["Context"
    ("e" "Explain error" my-codex-explain-region-as-error)
    ("i" "Project instructions" my-codex-open-project-instructions)
    ("X" "Export session" my-codex-export-session-to-markdown)
    ("M" "Summarize session" my-codex-summarize-session-to-markdown)
    ("!" "Doctor" my-codex-doctor)]
   ["GitHub"
    ("t" "List issues" my-codex-list-open-tickets)
    ("T" "Draft issue" my-codex-summarize-session-to-github-issue)]])

;;;###autoload
(defun my-codex-transient-preserve-selection ()
  "Show Codex commands without disturbing the active region."
  (interactive)
  (setq my-codex--captured-selection
        (when (and (my-codex--selected-window-is-codex-p)
                   (use-region-p))
          (prog1
              (filter-buffer-substring
               (region-beginning)
               (region-end))
            (deactivate-mark))))
  (my-codex-transient))


;;;###autoload
(defun my-codex-project-build ()
  "Run the project build command with `compile'."
  (interactive)
  (let ((default-directory (my-codex-project-root)))
    (compile (or my-codex-project-build-command compile-command))))

(defvar-keymap my-codex-global-mode-map
  :doc "Keymap for `my-codex-global-mode'."
  "<f7>" #'my-codex-project-build
  "<f8>" #'my-codex-transient-preserve-selection)

(defun my-codex--enable-display-defaults ()
  "Enable default editing display helpers."
  (unless my-codex--display-defaults-enabled-by-mode
    (setq my-codex--saved-show-trailing-whitespace
          (default-value 'show-trailing-whitespace))
    (setq my-codex--saved-column-number-mode
          (bound-and-true-p column-number-mode))
    (setq my-codex--display-defaults-enabled-by-mode t))
  (setq-default show-trailing-whitespace
                my-codex--display-show-trailing-whitespace-value)
  (column-number-mode
   (if my-codex--display-column-number-mode-value 1 -1)))

(defun my-codex--restore-display-defaults ()
  "Restore display defaults changed by `my-codex-global-mode'."
  (when my-codex--display-defaults-enabled-by-mode
    (when (eq (default-value 'show-trailing-whitespace)
              my-codex--display-show-trailing-whitespace-value)
      (setq-default show-trailing-whitespace
                    my-codex--saved-show-trailing-whitespace))
    (when (eq (bound-and-true-p column-number-mode)
              my-codex--display-column-number-mode-value)
      (column-number-mode
       (if my-codex--saved-column-number-mode 1 -1)))
    (setq my-codex--saved-show-trailing-whitespace nil)
    (setq my-codex--saved-column-number-mode nil)
    (setq my-codex--display-defaults-enabled-by-mode nil)))

(easy-menu-define my-codex-menu my-codex-global-mode-map
  "Menu for Codex commands."
  '("Codex"
    ("Session"
     ["Show/start read-only" my-codex-read-only
      :keys "F8 o"
      :help "Show Codex, starting it in read-only mode if needed"]
     ["Show/start workspace-write" my-codex-workspace
      :keys "F8 w"
      :help "Show Codex, starting it with workspace write access if needed"]
     ["Session commands" my-codex-session-transient
      :keys "F8 S"
      :help "Open default and future Codex session commands"]
     ["Resume session" my-codex-resume
      :keys "F8 r"
      :help "Resume a previous Codex session"]
     ["Show/start default read-only" my-codex-default-read-only
      :keys "F8 S o"
      :help "Show the default Codex session in read-only mode"]
     ["Show/start default workspace-write" my-codex-default-workspace
      :keys "F8 S w"
      :help "Show the default Codex session with workspace write access"]
     ["List open sessions" my-codex-list-sessions
      :keys "F8 S l"
      :help "List open Codex session buffers"]
     ["New named session" my-codex-new-session
      :keys "F8 S n"
      :help "Start or show a named Codex session"]
     ["Hide selected session window" my-codex-restore-session-layout
      :keys "F8 S q"
      :help "Hide the Codex window associated with the selected session"]
     ["Hide Codex window" my-codex-restore-layout
      :keys "F8 q"
      :help "Hide the visible Codex window"]
     ["Toggle focus" my-codex-toggle-focus
      :keys "F8 TAB"
      :help "Toggle focus between Codex and the previous window"])
    ("Send"
     ["Ask Codex..." my-codex-ask
      :keys "F8 a"
      :help "Prompt for a question and send it to Codex"]
     ["Preset menu" my-codex-ask-preset-transient
      :keys "F8 A"
      :help "Open the prompt preset menu"]
     ["Send selected region" my-codex-send-region
      :keys "F8 s"
      :active (use-region-p)
      :help "Send the selected region to Codex"]
     ["Plan refactor for selected region" my-codex-plan-refactor-region
      :keys "F8 R"
      :active (and (use-region-p) buffer-file-name)
      :help "Ask Codex for a low-risk refactoring plan without sending the code"]
     ["Insert selection" my-codex-insert-selection-into-code
      :keys "F8 Left"
      :help "Insert the captured Codex selection into the code buffer"]
     ["Inspect current file" my-codex-send-current-file
      :keys "F8 f"
      :active buffer-file-name
      :help "Ask Codex to inspect the current file directly"]
     ["Analyse test coverage" my-codex-analyse-test-coverage
      :keys "F8 C"
      :active buffer-file-name
      :help "Ask Codex to analyse missing test scenarios for the current file"]
     ["Explain symbol at point" my-codex-explain-symbol-at-point
      :keys "F8 x"
      :active buffer-file-name
      :help "Ask Codex to explain the symbol at point"]
     ["Send project overview" my-codex-send-project-overview
      :keys "F8 p"
      :help "Send Codex a compact summary of the current project structure"])
    ("Git"
     ["Review Git diff" my-codex-send-git-diff
      :keys "F8 g"
      :help "Ask Codex to review the current Git diff"]
     ["Review staged Git diff" my-codex-send-git-staged-diff
      :keys "F8 G"
      :help "Ask Codex to review the staged Git diff"]
     ["View Git diff" my-codex-show-git-diff
      :keys "F8 v"
      :help "Show the current Git diff in a diff-mode buffer"]
     ["View staged Git diff" my-codex-show-git-staged-diff
      :keys "F8 V"
      :help "Show the staged Git diff in a diff-mode buffer"]
     ["Ediff current file against HEAD" my-codex-ediff-current-file-against-head
      :keys "F8 d"
      :active (my-codex--current-or-left-file-available-p)
      :help "Review the current file's uncommitted changes against HEAD"]
     ["Ediff changed file against HEAD" my-codex-ediff-changed-file-against-head
      :keys "F8 D"
      :help "Choose a tracked changed file and review it against HEAD"]
     ["Edit commit with Codex message" my-codex-git-commit-with-latest-message
      :keys "F8 c"
      :help "Use the latest Codex commit message, or ask Codex for one, then edit before committing"])
    ("Context"
     ["Explain selected error" my-codex-explain-region-as-error
      :keys "F8 e"
      :active (use-region-p)
      :help "Ask Codex to explain the selected compiler/test error"]
     ["Open project instructions" my-codex-open-project-instructions
      :keys "F8 i"
      :help "Open AGENTS.md, CODEX.md, or .codex/instructions.md"]
     ["Export session to Markdown" my-codex-export-session-to-markdown
      :keys "F8 X"
      :help "Export the current Codex session transcript to a Markdown buffer"]
     ["Summarize session to Markdown" my-codex-summarize-session-to-markdown
      :keys "F8 M"
      :help "Ask Codex to summarize the current session transcript as Markdown notes"]
     ["Run health check" my-codex-doctor
      :keys "F8 !"
      :help "Check Emacs, Codex, vterm, Git, gh, project, configuration, and terminal startup"])
    ("GitHub"
     ["List issues" my-codex-list-open-tickets
      :keys "F8 t"
      :help "List open GitHub issues for the current repository in a buffer"]
     ["Draft issue" my-codex-summarize-session-to-github-issue
      :keys "F8 T"
      :help "Ask Codex to draft a GitHub issue, then edit it before creating it with gh"])
    "---"
    ["Compile project" my-codex-project-build
     :keys "F7"
     :help "Run the project build command"]))

;;;###autoload
(define-minor-mode my-codex-global-mode
  "Global minor mode for seamless Codex integration."
  :global t
  :group 'my-codex
  :keymap my-codex-global-mode-map
  (if my-codex-global-mode
      (progn
        (when my-codex-enable-display-defaults
          (my-codex--enable-display-defaults))
        (when (and my-codex-enable-vterm-integration
                   (not my-codex--vterm-integration-enabled-by-mode)
                   (not (bound-and-true-p my-codex-vterm-integration-mode)))
          (setq my-codex--vterm-integration-enabled-by-mode t)
          (my-codex-vterm-integration-mode 1))
        (when (and my-codex-enable-global-auto-revert
                   (not my-codex--auto-revert-enabled-by-mode)
                   (not (bound-and-true-p global-auto-revert-mode)))
          (setq my-codex--auto-revert-enabled-by-mode t)
          (global-auto-revert-mode 1)))
    (when (and my-codex--auto-revert-enabled-by-mode
               (bound-and-true-p global-auto-revert-mode))
      (global-auto-revert-mode -1))
    (when (and my-codex--vterm-integration-enabled-by-mode
               (bound-and-true-p my-codex-vterm-integration-mode))
      (my-codex-vterm-integration-mode -1))
    (my-codex--restore-display-defaults)
    (setq my-codex--vterm-integration-enabled-by-mode nil)
    (setq my-codex--auto-revert-enabled-by-mode nil)))

(provide 'my-codex)

;;; my-codex.el ends here
