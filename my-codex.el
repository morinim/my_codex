;;; my-codex.el --- Codex integration -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Manlio Morini

;; Author: Manlio Morini
;; Keywords: tools, convenience
;; URL: https://github.com/morinim/my_codex
;; Version: 0.9.8
;; Package-Requires: ((emacs "29.1") (vterm "0") (transient "0"))

;; This file is not part of GNU Emacs.

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at https://mozilla.org/MPL/2.0/.

;;; Commentary:

;; my-codex.el runs the OpenAI Codex CLI inside an Emacs vterm buffer.
;; It provides a two-column workflow, project-specific Codex sessions,
;; helpers for Git diffs, selected regions, current files, compiler errors,
;; and a configurable project build command.

;;; Code:

(require 'compile)
(require 'ansi-color)
(require 'cl-lib)
(require 'ediff)
(require 'easymenu)
(require 'project)
(require 'seq)
(require 'subr-x)
(require 'thingatpt)
(require 'transient)

(autoload 'vterm-mode "vterm" nil t)
(autoload 'vterm-send-string "vterm")
(autoload 'vterm-send-return "vterm")
(autoload 'vterm-yank "vterm" nil t)
(autoload 'vterm-copy-mode "vterm" nil t)
(declare-function markdown-mode "markdown-mode")
(defvar vterm-mode-map)
(defvar vterm-copy-mode)

(defgroup my-codex nil
  "Customisation options for the Codex development tool."
  :group 'convenience
  :prefix "my-codex-")

(defcustom my-codex-buffer-name "*codex*"
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
  '("AGENTS.md" "CODEX.md" ".codex/instructions.md")
  "Candidate project instruction files for Codex."
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
  "Please review the current Git diff using `git diff -- .`. Focus on correctness, regressions, edge cases, naming, and maintainability. Do not edit files unless I explicitly ask.\n"
  "Prompt used by `my-codex-send-git-diff'."
  :type 'string
  :group 'my-codex)

(defcustom my-codex-git-staged-diff-review-prompt
  "Please review the staged Git diff using `git diff --cached -- .`. Focus on correctness, regressions, edge cases, and commit readiness. Do not edit files unless I explicitly ask.\n"
  "Prompt used by `my-codex-send-git-staged-diff'."
  :type 'string
  :group 'my-codex)

(defcustom my-codex-test-coverage-prompt
  "Please analyse the test coverage for this implementation and its test file.

Identify missing edge cases, unhandled exceptions, logical flaws, and important behaviour that is not currently tested. Do not edit files and do not write tests; only list the missing scenarios."
  "Prompt used by `my-codex-analyse-test-coverage'."
  :type 'string
  :group 'my-codex)

(defcustom my-codex-commit-message-prompt-template
  "Please inspect the staged Git diff using `git diff --cached -- .` and write a concise but comprehensive conventional commit message.

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

(defcustom my-codex-enable-session-links t
  "When non-nil, make URLs and file references clickable in Codex buffers."
  :type 'boolean
  :group 'my-codex)

(defcustom my-codex-project-overview-max-files 200
  "Maximum project file count before project overviews use a tree summary."
  :type 'natnum
  :group 'my-codex)

(defcustom my-codex-project-overview-tree-max-entries 25
  "Maximum entries shown for each directory in project overview tree summaries."
  :type 'natnum
  :group 'my-codex)

(defcustom my-codex-enable-prompt-preview nil
  "When non-nil, show an editable preview before sending prompts."
  :type 'boolean
  :group 'my-codex)

(defcustom my-codex-symbol-context-lines 10
  "Number of surrounding lines to include when explaining a symbol."
  :type 'natnum
  :group 'my-codex)

(defcustom my-codex-session-summary-prompt
  "Please summarize, organize, and rationalize this Codex session transcript into useful project notes.

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

(defvar my-codex--saved-show-trailing-whitespace nil
  "Previous default value of `show-trailing-whitespace'.")

(defvar my-codex--saved-column-number-mode nil
  "Previous value of `column-number-mode'.")

(defvar my-codex--display-defaults-enabled-by-mode nil
  "Non-nil when `my-codex-global-mode' changed display defaults.")

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

(defvar-local my-codex--commit-message-wait-timer nil
  "Active timer waiting for a Codex commit message.")

(defvar-local my-codex--session-summary-request-marker nil
  "Marker for the start of the latest Codex session summary request.")

(defvar-local my-codex--session-summary-wait-timer nil
  "Active timer waiting for a Codex session summary.")

(defvar-local my-codex--github-issue-creation-in-progress nil
  "Non-nil while the current GitHub issue draft is being submitted.")

(defvar my-codex--captured-selection nil
  "Text captured before opening a transient from an active region.")

(defun my-codex--selected-window-is-codex-p ()
  "Return non-nil if the selected window shows Codex."
  (eq (selected-window)
      (ignore-errors
        (my-codex-visible-window))))

(defun my-codex--shell-command-and-exit (command)
  "Return shell text that runs COMMAND, then exits with its status."
  (format "(%s); exit $?" command))

(defun my-codex--right-window-width (window)
  "Resize WINDOW to the target Codex width when enforcement is enabled."
  (when my-codex-enforce-right-side-layout
    (my-codex--resize-window-to-body-width
     window
     (max my-codex-min-right-width my-codex-right-width))))

(defun my-codex--right-side-action-p ()
  "Return non-nil when Codex is configured for a right side window."
  (eq (alist-get 'side (cdr my-codex-display-buffer-action)) 'right))

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
    (pcase (alist-get 'window-width (cdr my-codex-display-buffer-action))
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

(defun my-codex-current-buffer-name ()
  "Return a project-specific buffer name for the Codex session."
  (if-let* ((project (project-current))
            (root (file-truename (project-root project)))
            (name (file-name-nondirectory (directory-file-name root)))
            (hash (substring (secure-hash 'sha1 root) 0 8)))
      (format "*codex:%s:%s*" name hash)
    my-codex-buffer-name))

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

(defun my-codex-two-column-layout-with-command (codex-command &optional focus-term)
  "Display Codex and run CODEX-COMMAND in vterm if not running.
If FOCUS-TERM is non-nil, leave the cursor focused on the terminal window."
  (cl-labels
      ((live-buffer-p
        (buffer)
        (process-live-p (get-buffer-process buffer)))
       (start-codex-buffer
        (buffer-name)
        (let* ((default-directory (my-codex-project-root))
               (buffer (get-buffer-create buffer-name)))
          (with-current-buffer buffer
            (unless (derived-mode-p 'vterm-mode)
              (vterm-mode))
            (when my-codex-enable-session-links
              (my-codex-session-links-mode 1))
            (let ((proc (get-buffer-process buffer)))
              (unless (process-live-p proc)
                (user-error "Failed to start vterm process in %s"
                            buffer-name))
              (set-process-query-on-exit-flag proc nil)
              (goto-char (point-max))
              (vterm-send-string
               (my-codex--shell-command-and-exit codex-command))
              (vterm-send-return)))
          buffer))
       (display-codex-buffer
        (buffer)
        (or (display-buffer buffer my-codex-display-buffer-action)
            (user-error "Failed to display %s" (buffer-name buffer)))))
    (let* ((buffer-name (my-codex-current-buffer-name))
           (existing-buf (get-buffer buffer-name)))
      (my-codex--fit-frame-to-right-layout)

      (when (and existing-buf
                 (not (live-buffer-p existing-buf)))
        (kill-buffer existing-buf)
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
                   (live-buffer-p existing-buf))
          (set-window-buffer term-window existing-buf))
        (unless (and existing-buf
                     (live-buffer-p existing-buf))
          (start-codex-buffer buffer-name))

        (if focus-term
            (select-window term-window)
          (when (window-live-p edit-window)
            (select-window edit-window)))))))

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

(defun my-codex-read-only ()
  "Show Codex, starting it in read-only mode if needed."
  (interactive)
  (my-codex-two-column-layout-with-command my-codex-read-only-command))

(defun my-codex-workspace ()
  "Show Codex, starting it with workspace write access if needed."
  (interactive)
  (my-codex-two-column-layout-with-command my-codex-workspace-command))

(defun my-codex-resume ()
  "Show Codex, resuming a previous session if needed and focusing the window."
  (interactive)
  (my-codex-two-column-layout-with-command my-codex-resume-command t))

(defun my-codex-buffer ()
  "Return the current project's Codex vterm buffer, or raise an error."
  (let* ((buffer-name (my-codex-current-buffer-name))
         (buffer (get-buffer buffer-name)))
    (unless buffer
      (user-error "No %s buffer found" buffer-name))
    (let ((proc (get-buffer-process buffer)))
      (unless (process-live-p proc)
        (user-error "No running Codex process in %s" buffer-name)))
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

(defun my-codex--github-issue-output-buffer-name (root)
  "Return the GitHub issue process buffer name for ROOT."
  (format "*Codex GitHub issue:%s*" (my-codex--safe-root-name root)))

(defun my-codex--github-ticket-list-buffer-name (root)
  "Return the open issue list buffer name for ROOT."
  (format "*Codex open issues:%s*" (my-codex--safe-root-name root)))

(defun my-codex--github-issue-draft-buffer-name (root)
  "Return the GitHub issue draft buffer name for ROOT."
  (format "*Codex GitHub issue draft:%s*" (my-codex--safe-root-name root)))

(defun my-codex--github-ticket-list-sentinel (proc _event)
  "Handle completion of open issue list process PROC."
  (when (memq (process-status proc) '(exit signal))
    (let ((status (process-exit-status proc))
          (buffer (process-buffer proc))
          (content-start (process-get proc 'my-codex-content-start)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (cond
             ((zerop status)
              (when (and content-start (= (point-max) content-start))
                (insert "No open issues.\n")))
             (t
              (insert (format "\nProcess %s exited with status %s\n"
                              (process-name proc)
                              status)))))
          (goto-char (point-min))
          (special-mode))
        (unless (zerop status)
          (display-buffer buffer))
        (message "Open issue list %s."
                 (if (zerop status) "updated" "failed"))))))

;;;###autoload
(defun my-codex-list-open-tickets ()
  "List open GitHub issues for the current repository in a buffer."
  (interactive)
  (unless (executable-find "gh")
    (user-error "GitHub CLI `gh' not found in exec-path"))
  (let* ((root (my-codex-project-root))
         (buffer
          (get-buffer-create (my-codex--github-ticket-list-buffer-name root))))
    (with-current-buffer buffer
      (read-only-mode -1)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Open issues for %s\n\n" root)))
      (setq default-directory root))
    (pop-to-buffer buffer)
    (let ((process
           (let ((default-directory root))
             (make-process
              :name "my-codex-open-tickets"
              :buffer buffer
              :command (list "gh" "issue" "list"
                             "--state" "open"
                             "--limit" "100")
              :connection-type 'pipe
              :noquery t
              :sentinel #'my-codex--github-ticket-list-sentinel))))
      (process-put process 'my-codex-content-start
                   (with-current-buffer buffer (point-max)))
      (message "Listing open issues with gh...")
      process)))

(defun my-codex--parse-github-issue-draft (draft)
  "Return a cons of issue title and body parsed from DRAFT."
  (let ((text (string-trim draft)))
    (unless (string-match
             "\\`[ \t\n]*Title:[ \t]*\\([^\n]+\\)\n+[ \t]*Body:[ \t]*\n*"
             text)
      (user-error "Could not parse GitHub issue draft"))
    (let ((title (string-trim (match-string 1 text)))
          (body (string-trim (substring text (match-end 0)))))
      (when (string-empty-p title)
        (user-error "GitHub issue title is empty"))
      (when (string-empty-p body)
        (user-error "GitHub issue body is empty"))
      (cons title body))))

(defun my-codex--github-issue-draft-text (title body)
  "Return editable GitHub issue draft text for TITLE and BODY."
  (format "Title: %s\n\nBody:\n%s\n" title (string-trim body)))

(defun my-codex--github-issue-process-sentinel (proc _event)
  "Handle completion of GitHub issue creation process PROC."
  (when (memq (process-status proc) '(exit signal))
    (let ((status (process-exit-status proc))
          (buffer (process-buffer proc))
          (file (process-get proc 'my-codex-temp-file))
          (draft-buffer (process-get proc 'my-codex-draft-buffer)))
      (when file
        (ignore-errors
          (delete-file file)))
      (if (zerop status)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (goto-char (point-min))
              (message "GitHub issue created: %s"
                       (string-trim (buffer-string))))
            (when (buffer-live-p draft-buffer)
              (quit-windows-on draft-buffer t)))
        (when (buffer-live-p draft-buffer)
          (with-current-buffer draft-buffer
            (setq my-codex--github-issue-creation-in-progress nil)
            (setq-local header-line-format
                        "Edit GitHub issue draft. C-c C-c creates issue; C-c C-k cancels.")))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (goto-char (point-max))
            (insert (format "\nProcess %s exited with status %s"
                            (process-name proc)
                            status))
            (display-buffer buffer)))))))

(defun my-codex--create-github-issue-with-body
    (title body root &optional draft-buffer)
  "Create a GitHub issue with TITLE and BODY in ROOT using `gh'."
  (unless (executable-find "gh")
    (user-error "GitHub CLI `gh' not found in exec-path"))
  (let ((file (make-temp-file "my-codex-github-issue-" nil ".md"))
        (output-buffer
         (get-buffer-create (my-codex--github-issue-output-buffer-name root))))
    (condition-case err
        (progn
          (with-temp-file file
            (insert (string-trim body) "\n"))
          (with-current-buffer output-buffer
            (read-only-mode -1)
            (erase-buffer))
          (let ((default-directory root))
            (let ((process
                   (make-process
                    :name "my-codex-github-issue"
                    :buffer output-buffer
                    :command (list "gh" "issue" "create"
                                   "--title" title
                                   "--body-file" file)
                    :connection-type 'pipe
                    :noquery t
                    :sentinel #'my-codex--github-issue-process-sentinel)))
              (process-put process 'my-codex-temp-file file)
              (process-put process 'my-codex-draft-buffer draft-buffer)
              (message "Creating GitHub issue with gh...")
              process)))
      (error
       (ignore-errors
         (delete-file file))
       (signal (car err) (cdr err))))))

(defun my-codex--github-issue-draft-fields ()
  "Return the edited GitHub issue draft fields in the current buffer."
  (my-codex--parse-github-issue-draft
   (buffer-substring-no-properties (point-min) (point-max))))

(defun my-codex--create-github-issue-from-draft ()
  "Create a GitHub issue from the current editable draft buffer."
  (interactive)
  (when my-codex--github-issue-creation-in-progress
    (user-error "GitHub issue creation is already in progress"))
  (pcase-let ((`(,title . ,body) (my-codex--github-issue-draft-fields)))
    (setq my-codex--github-issue-creation-in-progress t)
    (setq-local header-line-format
                "Creating GitHub issue with gh; wait for completion.")
    (condition-case err
        (my-codex--create-github-issue-with-body
         title body default-directory (current-buffer))
      (error
       (setq my-codex--github-issue-creation-in-progress nil)
       (setq-local header-line-format
                   "Edit GitHub issue draft. C-c C-c creates issue; C-c C-k cancels.")
       (signal (car err) (cdr err))))))

(defun my-codex--cancel-github-issue-draft ()
  "Cancel the current GitHub issue draft buffer."
  (interactive)
  (when my-codex--github-issue-creation-in-progress
    (user-error "GitHub issue creation is already in progress"))
  (quit-window 'kill)
  (message "GitHub issue draft canceled."))

(defun my-codex-edit-github-issue-draft (draft root)
  "Open an editable GitHub issue DRAFT for ROOT."
  (pcase-let* ((`(,title . ,body)
                (my-codex--parse-github-issue-draft draft))
               (buffer
                (get-buffer-create
                 (my-codex--github-issue-draft-buffer-name root))))
    (pop-to-buffer buffer)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (my-codex--github-issue-draft-text title body))
      (goto-char (point-min)))
    (setq default-directory root)
    (my-codex--session-export-mode)
    (setq-local header-line-format
                "Edit GitHub issue draft. C-c C-c creates issue; C-c C-k cancels.")
    (let ((map (define-keymap :parent (current-local-map)
                 "C-c C-c" #'my-codex--create-github-issue-from-draft
                 "C-c C-k" #'my-codex--cancel-github-issue-draft)))
      (use-local-map map))
    (message "Edit the GitHub issue draft, then press C-c C-c to create it.")))

;;;###autoload
(defun my-codex-summarize-session-to-github-issue ()
  "Ask Codex to draft a GitHub issue from the current session.
Open an editable issue draft before running `gh issue create'."
  (interactive)
  (let* ((root (my-codex-project-root))
         (buffer (my-codex-buffer))
         (transcript (my-codex-session-transcript))
         (markers (my-codex--unique-output-markers "GITHUB_ISSUE_DRAFT"))
         (begin-marker (car markers))
         (end-marker (cdr markers)))
    (unless (executable-find "gh")
      (user-error "GitHub CLI `gh' not found in exec-path"))
    (when (string-empty-p transcript)
      (user-error "Codex session transcript is empty"))
    (let ((start-point (with-current-buffer buffer
                         (copy-marker (point-max))))
          (prompt (my-codex--session-summary-prompt
                   my-codex-github-issue-summary-prompt
                   transcript begin-marker end-marker
                   "<GitHub issue draft here>")))
      (with-current-buffer buffer
        (setq my-codex--session-summary-request-marker start-point))
      (my-codex-send-prompt prompt)
      (my-codex--wait-for-session-summary
       buffer start-point root begin-marker end-marker
       (lambda (draft)
         (my-codex-edit-github-issue-draft draft root))
       "Codex GitHub issue draft is ready for editing."
       '("<GitHub issue draft here>"))
      (message "Asked Codex to draft a GitHub issue; waiting to open editor."))))

(defvar my-codex-session-link-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'my-codex-open-session-link-at-event)
    (define-key map (kbd "RET") #'my-codex-open-session-link-at-point)
    map)
  "Keymap used for clickable Codex session links.")

(defvar my-codex-session-links-mode)

(defconst my-codex--url-regexp
  "\\_<https?://[^[:space:]<>()\"'.,;:!?]+\\(?:[.,;:!?]*[^[:space:]<>()\"'.,;:!?]\\)*"
  "Regexp matching HTTP and HTTPS URLs.")

(defconst my-codex--file-reference-regexp
  (concat
   "\\(?1:\\(?:[[:alnum:]_.@+-]+/\\)*[[:alnum:]_.@+-]+\\.[[:alnum:]_.@+-]+\\)"
   "\\(?:"
   ":\\(?2:[0-9]+\\)\\(?::\\(?3:[0-9]+\\)\\)?"
   "\\|"
   ":L\\(?4:[0-9]+\\)\\(?:-L?\\(?5:[0-9]+\\)\\)?"
   "\\|"
   "#L\\(?6:[0-9]+\\)\\(?:-L?\\(?7:[0-9]+\\)\\)?"
   "\\)")
  "Regexp matching in-repository file references.

Supported forms include:

  src/foo.el:42
  src/foo.el:42:7
  src/foo.el:L42-L60
  src/foo.el#L42-L60")

(defconst my-codex--file-reference-context-lines 3
  "Number of preceding lines used to resolve split file references.")

(defun my-codex--add-session-link (beg end type target)
  "Add a clickable Codex session link from BEG to END.
TYPE is one of `url' or `file'.  TARGET is link-specific data."
  (add-text-properties
   beg end
   `(mouse-face highlight
     help-echo "mouse-1 or RET: open link"
     keymap ,my-codex-session-link-map
     my-codex-session-link-type ,type
     my-codex-session-link-target ,target
     font-lock-face link)))

(defun my-codex-open-session-link-at-event (event)
  "Open the Codex session link clicked by EVENT."
  (interactive "e")
  (let* ((end (event-end event))
         (window (posn-window end))
         (pos (posn-point end)))
    (with-current-buffer (window-buffer window)
      (my-codex-open-session-link-at-position pos))))

(defun my-codex-open-session-link-at-point ()
  "Open the Codex session link at point."
  (interactive)
  (my-codex-open-session-link-at-position (point)))

(defun my-codex-open-session-link-at-position (pos)
  "Open the Codex session link at POS."
  (let ((type (get-text-property pos 'my-codex-session-link-type))
        (target (get-text-property pos 'my-codex-session-link-target)))
    (pcase type
      ('url
       (browse-url target))
      ('file
       (my-codex-open-file-reference target))
      (_
       (user-error "No Codex session link at point")))))

(defun my-codex-open-file-reference (target)
  "Open file reference TARGET.
TARGET is a plist containing :file, :line, :column, and :end-line."
  (let* ((root (my-codex-project-root))
         (file (plist-get target :file))
         (line (plist-get target :line))
         (column (plist-get target :column))
         (end-line (plist-get target :end-line)))
    (unless (my-codex--valid-file-reference-target-p target)
      (user-error "File does not exist: %s" file))
    (find-file-other-window (expand-file-name file root))
    (when line
      (goto-char (point-min))
      (forward-line (1- line))
      (if (and end-line
               (>= end-line line))
          (push-mark
           (save-excursion
             (forward-line (- end-line line))
             (line-end-position))
           nil t)
        (deactivate-mark)))
    (when column
      (move-to-column (1- column)))))

(defun my-codex--file-reference-target-at-match ()
  "Return a plist describing the current file-reference regexp match."
  (let ((file (match-string-no-properties 1))
        (line-str (or (match-string-no-properties 2)
                      (match-string-no-properties 4)
                      (match-string-no-properties 6)))
        (column-str (match-string-no-properties 3))
        (end-line-str (or (match-string-no-properties 5)
                          (match-string-no-properties 7))))
    (list :file file
          :line (when line-str
                  (string-to-number line-str))
          :column (when column-str
                    (string-to-number column-str))
          :end-line (when end-line-str
                      (string-to-number end-line-str)))))

(defun my-codex--file-reference-context-directory (pos)
  "Return a nearby preceding directory prefix for a file reference at POS."
  (save-excursion
    (goto-char pos)
    (let ((limit (save-excursion
                   (forward-line (- my-codex--file-reference-context-lines))
                   (point)))
          directory)
      (while (and (not directory)
                  (> (line-beginning-position) limit))
        (forward-line -1)
        (let ((line (string-trim-right
                     (buffer-substring-no-properties
                      (line-beginning-position)
                      (line-end-position)))))
          (when (string-match
                 "\\(?:^\\|[^[:alnum:]_.@+-]\\)\\(\\(?:[[:alnum:]_.@+-]+/\\)+\\)\\'"
                 line)
            (setq directory (match-string 1 line)))))
      directory)))

(defun my-codex--resolve-file-reference-target (target pos)
  "Return a valid file reference TARGET, resolving context at POS when needed."
  (if (my-codex--valid-file-reference-target-p target)
      target
    (let ((file (plist-get target :file)))
      (when (and file
                 (not (file-name-directory file))
                 (not (file-name-absolute-p file)))
        (when-let ((directory (my-codex--file-reference-context-directory pos)))
          (let ((resolved (plist-put (copy-sequence target)
                                     :file
                                     (concat directory file))))
            (when (my-codex--valid-file-reference-target-p resolved)
              resolved)))))))

(defun my-codex--valid-file-reference-target-p (target)
  "Return non-nil if TARGET refers to a readable in-project file."
  (let* ((root (file-truename (my-codex-project-root)))
         (file (plist-get target :file)))
    (and file
         (not (file-name-absolute-p file))
         (let ((path (expand-file-name file root)))
           (and (file-readable-p path)
                (file-in-directory-p (file-truename path) root))))))

(defun my-codex--line-bounds (beg end)
  "Return a cons of linkification bounds around BEG and END."
  (save-excursion
    (cons
     (progn
       (goto-char beg)
       (line-beginning-position))
     (progn
       (goto-char end)
       (forward-line my-codex--file-reference-context-lines)
       (line-end-position)))))

(defun my-codex--clear-session-links (beg end)
  "Remove Codex session link properties between BEG and END."
  (remove-text-properties
   beg end
   '(mouse-face nil
     help-echo nil
     keymap nil
     my-codex-session-link-type nil
     my-codex-session-link-target nil
     font-lock-face nil)))

(defun my-codex--linkify-session-region (beg end &optional _len)
  "Add Codex session links in the region from BEG to END."
  (when my-codex-session-links-mode
    (pcase-let ((`(,rbeg . ,rend) (my-codex--line-bounds beg end)))
      (let ((inhibit-read-only t)
            (inhibit-modification-hooks t))
        (my-codex--clear-session-links rbeg rend)

        ;; URLs first, so file-like text inside URLs is not also linkified.
        (save-excursion
          (goto-char rbeg)
          (while (re-search-forward my-codex--url-regexp rend t)
            (my-codex--add-session-link
             (match-beginning 0)
             (match-end 0)
             'url
             (match-string-no-properties 0))))

        ;; File references.
        (save-excursion
          (goto-char rbeg)
          (while (re-search-forward my-codex--file-reference-regexp rend t)
            (unless (get-text-property (match-beginning 0)
                                       'my-codex-session-link-type)
              (let ((target (my-codex--file-reference-target-at-match))
                    (match-beg (match-beginning 0))
                    (match-end (match-end 0)))
                (when-let ((resolved-target
                            (save-match-data
                              (my-codex--resolve-file-reference-target
                               target match-beg))))
                  (my-codex--add-session-link
                   match-beg
                   match-end
                   'file
                   resolved-target))))))))))

(define-minor-mode my-codex-session-links-mode
  "Make URLs and in-repository file references clickable in Codex buffers."
  :lighter " Links"
  (if my-codex-session-links-mode
      (progn
        (add-hook 'after-change-functions
                  #'my-codex--linkify-session-region
                  nil t)
        (my-codex--linkify-session-region (point-min) (point-max)))
    (remove-hook 'after-change-functions
                 #'my-codex--linkify-session-region
                 t)
    (let ((inhibit-read-only t)
          (inhibit-modification-hooks t))
      (my-codex--clear-session-links (point-min) (point-max)))))

(defun my-codex-send-prompt (prompt)
  "Send PROMPT to the Codex vterm buffer and show it."
  (my-codex--warn-about-unsaved-project-buffers)
  (let ((buffer (my-codex-buffer)))
    (if-let (window (get-buffer-window buffer t))
        (select-window window)
      (pop-to-buffer buffer))
    (redisplay t)
    (with-current-buffer buffer
      (goto-char (point-max))
      (vterm-send-string prompt t)
      (vterm-send-return))))

(defun my-codex--prompt-preview-buffer-name (root)
  "Return the prompt preview buffer name for ROOT."
  (format "*Codex prompt preview:%s*" (my-codex--safe-root-name root)))

(defun my-codex--display-prompt-preview-buffer (buffer origin-window)
  "Display prompt preview BUFFER, preferring ORIGIN-WINDOW."
  (if-let* ((origin-frame (and (window-live-p origin-window)
                               (window-frame origin-window)))
            (codex-window (get-buffer-window (my-codex-current-buffer-name)
                                             origin-frame))
            (preview-window
             (cond
              ((not (eq origin-window codex-window))
               origin-window)
              (t
               (seq-find
                (lambda (window)
                  (not (eq window codex-window)))
                (sort (window-list (window-frame codex-window) 'no-minibuf)
                      (lambda (a b)
                        (or (< (window-left-column a)
                               (window-left-column b))
                            (and (= (window-left-column a)
                                    (window-left-column b))
                                 (< (window-top-line a)
                                    (window-top-line b)))))))))))
      (progn
        (set-window-buffer preview-window buffer)
        (select-window preview-window))
    (pop-to-buffer buffer)))

(defun my-codex--finish-prompt-preview ()
  "Send the current prompt preview buffer contents to Codex."
  (interactive)
  (let ((prompt (string-trim-right
                 (buffer-substring-no-properties (point-min) (point-max))))
        (root default-directory)
        (buffer (current-buffer)))
    (when (string-blank-p prompt)
      (user-error "Prompt is empty"))
    (let ((default-directory root))
      (my-codex-send-prompt prompt))
    (when (buffer-live-p buffer)
      (kill-buffer buffer))))

(defun my-codex--cancel-prompt-preview ()
  "Cancel the current Codex prompt preview buffer."
  (interactive)
  (let ((origin-window my-codex--prompt-preview-origin-window))
    (kill-buffer (current-buffer))
    (when (window-live-p origin-window)
      (select-window origin-window)))
  (message "Codex prompt canceled."))

(defun my-codex--preview-and-send-prompt (prompt)
  "Preview PROMPT before sending it to Codex when enabled."
  (if my-codex-enable-prompt-preview
      (let* ((root (my-codex-project-root))
             (origin-window (selected-window))
             (buffer (get-buffer-create
                      (my-codex--prompt-preview-buffer-name root))))
        (my-codex--display-prompt-preview-buffer buffer origin-window)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert prompt)
          (goto-char (point-min)))
        (text-mode)
        (setq default-directory root)
        (setq-local my-codex--prompt-preview-origin-window origin-window)
        (setq-local header-line-format
                    (concat "Edit if needed; C-c C-c sends to Codex,"
                            " C-c C-k cancels."))
        (let ((map (define-keymap :parent (current-local-map)
                     "C-c C-c" #'my-codex--finish-prompt-preview
                     "C-c C-k" #'my-codex--cancel-prompt-preview)))
          (use-local-map map))
        (message "Codex prompt preview opened."))
    (my-codex-send-prompt prompt)))

(defun my-codex-send-region (beg end)
  "Send the region between BEG and END to Codex with exact file context."
  (interactive "r")
  (unless (use-region-p)
    (user-error "No active region"))
  (my-codex--preview-and-send-prompt
   (format "%s\n\nPlease review this code and report findings:\n\n%s"
           (my-codex--region-context beg end)
           (buffer-substring-no-properties beg end))))

(defun my-codex-send-current-file ()
  "Ask Codex to inspect the current file directly."
  (interactive)
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a file"))
  (let* ((root (my-codex-project-root))
         (file (file-relative-name buffer-file-name root)))
    (my-codex--preview-and-send-prompt
     (format "Please inspect `%s` directly and report findings. Do not edit it unless I explicitly ask.\n"
             file))))

(defun my-codex--project-relative-file (file root)
  "Return FILE relative to ROOT, or nil when FILE is outside ROOT."
  (let ((truename (file-truename file))
        (root-truename (file-name-as-directory (file-truename root))))
    (when (file-in-directory-p truename root-truename)
      (file-relative-name truename root-truename))))

(defun my-codex--projectile-counterpart-file ()
  "Return Projectile's implementation/test counterpart for current file, or nil."
  (when (fboundp 'projectile-toggle-between-implementation-and-test)
    (let ((current-file (buffer-file-name)))
      (when current-file
        (save-window-excursion
          (save-current-buffer
            (condition-case nil
                (progn
                  (call-interactively
                   #'projectile-toggle-between-implementation-and-test)
                  (let ((candidate (buffer-file-name)))
                    (when (and candidate
                               (not (file-equal-p candidate current-file))
                               (file-readable-p candidate))
                      candidate)))
              (error nil))))))))

(defun my-codex--test-file-candidates (file root)
  "Return likely test file candidates for FILE under ROOT."
  (let* ((relative (file-relative-name file root))
         (directory (or (file-name-directory relative) ""))
         (basename (file-name-base relative))
         (extension (or (file-name-extension relative t) ""))
         (file-name (file-name-nondirectory relative))
         (without-src (if (string-prefix-p "src/" relative)
                          (substring relative 4)
                        relative))
         (dir-without-src (or (file-name-directory without-src) ""))
         (common
          (delq nil
                (list
                 (concat "test/" without-src)
                 (concat "tests/" without-src)
                 (concat "spec/" without-src)
                 (concat "test/" dir-without-src "test_" file-name)
                 (concat "tests/" dir-without-src "test_" file-name)
                 (concat "test/" dir-without-src basename "_test" extension)
                 (concat "tests/" dir-without-src basename "_test" extension)
                 (concat "spec/" dir-without-src basename "_spec" extension)
                 (concat directory basename "-test" extension)
                 (concat directory basename "_test" extension)
                 (concat directory basename ".test" extension)
                 (concat directory basename "-spec" extension)
                 (concat directory basename "_spec" extension)
                 (concat directory basename ".spec" extension))))
         (seen nil)
         (candidates nil))
    (dolist (candidate common (nreverse candidates))
      (unless (member candidate seen)
        (push candidate seen)
        (push (expand-file-name candidate root) candidates)))))

(defun my-codex--read-test-file (implementation-file root)
  "Read a test file for IMPLEMENTATION-FILE under ROOT."
  (let* ((root (file-name-as-directory (expand-file-name root)))
         (projectile-file (my-codex--projectile-counterpart-file))
         (projectile-file
          (when (and projectile-file
                     (file-in-directory-p (file-truename projectile-file)
                                          (file-truename root)))
            projectile-file))
         (candidates (append (when projectile-file (list projectile-file))
                             (my-codex--test-file-candidates
                              implementation-file root)))
         (existing (seq-filter #'file-readable-p candidates))
         (default (car existing))
         (file (expand-file-name
                (read-file-name "Test file: " root default t)
                root)))
    (unless (file-in-directory-p (file-truename file)
                                 (file-truename root))
      (user-error "Test file is outside the current project"))
    file))

(defun my-codex-analyse-test-coverage ()
  "Ask Codex to analyse coverage of the current file by its test file."
  (interactive)
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a file"))
  (let* ((root (my-codex-project-root))
         (implementation-file buffer-file-name)
         (test-file (my-codex--read-test-file implementation-file root))
         (implementation-relative
          (my-codex--project-relative-file implementation-file root))
         (test-relative (my-codex--project-relative-file test-file root)))
    (unless implementation-relative
      (user-error "Implementation file is outside the current project"))
    (unless test-relative
      (user-error "Test file is outside the current project"))
    (my-codex--preview-and-send-prompt
     (string-join
      (list my-codex-test-coverage-prompt
            (format "Implementation: @%s" implementation-relative)
            (format "Test: @%s" test-relative))
      "\n\n"))))

(defun my-codex--symbol-at-point ()
  "Return the symbol at point, or raise a user error."
  (let ((symbol (thing-at-point 'symbol t)))
    (if (and symbol (not (string-blank-p symbol)))
        symbol
      (user-error "No symbol at point"))))

(defun my-codex--line-context-around-point (context-lines)
  "Return text around point spanning CONTEXT-LINES before and after."
  (save-excursion
    (save-restriction
      (widen)
      (let* ((line (line-number-at-pos))
             (start-line (max 1 (- line context-lines)))
             (end-line (+ line context-lines))
             start end)
        (goto-char (point-min))
        (forward-line (1- start-line))
        (setq start (line-beginning-position))
        (goto-char (point-min))
        (forward-line (1- end-line))
        (setq end (line-end-position))
        (buffer-substring-no-properties start end)))))

(defun my-codex-explain-symbol-at-point ()
  "Ask Codex to explain the symbol at point with nearby file context."
  (interactive)
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a file"))
  (let* ((root (my-codex-project-root))
         (file (file-relative-name buffer-file-name root))
         (line (line-number-at-pos))
         (symbol (my-codex--symbol-at-point))
         (context (my-codex--line-context-around-point
                   my-codex-symbol-context-lines)))
    (my-codex--preview-and-send-prompt
     (format (concat "In file `%s`, explain the role of symbol `%s` "
                     "near line %d.\n\n"
                     "Relevant context:\n\n"
                     "```\n%s\n```\n\n"
                     "Inspect the file directly if needed. Do not edit files.")
             file symbol line context))))

(defun my-codex--commit-message-trailer-line-p (line)
  "Return non-nil if LINE looks like a Git commit message trailer."
  (string-match-p "\\`[[:alnum:]-]+: .+" line))

(defun my-codex--commit-message-list-line-p (line)
  "Return non-nil if LINE looks like a list item."
  (string-match-p "\\`[[:space:]]*\\([-+*]\\|[0-9]+[.)]\\)[[:space:]]+" line))

(defun my-codex--commit-message-preserve-line-p (line)
  "Return non-nil if LINE should not be reflowed with surrounding text."
  (or (string-match-p "\\`\\([[:blank:]]\\{4,\\}\\|\t\\)" line)
      (my-codex--commit-message-trailer-line-p line)))

(defun my-codex--fill-commit-message-text (text)
  "Return TEXT filled to `my-codex-commit-message-fill-column'."
  (with-temp-buffer
    (insert text)
    (let ((fill-column my-codex-commit-message-fill-column))
      (fill-region (point-min) (point-max)))
    (string-trim-right (buffer-string))))

(defun my-codex--fill-commit-message-list-line (line)
  "Return list item LINE filled with continuation indentation preserved."
  (with-temp-buffer
    (insert (string-trim-right line))
    (let* ((fill-column my-codex-commit-message-fill-column)
           (prefix
            (save-excursion
              (goto-char (point-min))
              (when (looking-at
                     "\\([[:space:]]*\\(?:[-+*]\\|[0-9]+[.)]\\)[[:space:]]+\\)")
                (make-string (length (match-string 1)) ? )))))
      (let ((fill-prefix prefix))
        (fill-region (point-min) (point-max))))
    (string-trim-right (buffer-string))))

(defun my-codex--clean-commit-message-body-lines (lines)
  "Return LINES trimmed and filled for a Git commit message body."
  (let (result)
    (while lines
      (let ((line (car lines)))
        (cond
         ((string-blank-p line)
          (push "" result)
          (setq lines (cdr lines)))
         ((my-codex--commit-message-list-line-p line)
          (push (my-codex--fill-commit-message-list-line line)
                result)
          (setq lines (cdr lines)))
         ((my-codex--commit-message-preserve-line-p line)
          (push (string-trim-right line) result)
          (setq lines (cdr lines)))
         (t
          (let (paragraph)
            (while (and lines
                        (not (string-blank-p (car lines)))
                        (not (my-codex--commit-message-list-line-p (car lines)))
                        (not (my-codex--commit-message-preserve-line-p (car lines))))
              (push (string-trim (car lines)) paragraph)
              (setq lines (cdr lines)))
            (push (my-codex--fill-commit-message-text
                   (string-join (nreverse paragraph) " "))
                  result))))))
    (nreverse result)))

(defun my-codex-clean-commit-message (message)
  "Return MESSAGE trimmed and filled for use as a Git commit message."
  (let ((trimmed-message (string-trim message)))
    (if (string-empty-p trimmed-message)
        ""
      (let ((lines (split-string trimmed-message "\n")))
        (string-join
         (cons (string-trim (car lines))
               (my-codex--clean-commit-message-body-lines (cdr lines)))
         "\n")))))

(defun my-codex--git-repository-p ()
  "Return non-nil if `default-directory' is inside a Git repository."
  (and (executable-find "git")
       (let ((status (process-file "git" nil nil nil
                                   "rev-parse" "--is-inside-work-tree")))
         (and (integerp status) (zerop status)))))

(defun my-codex--ensure-git-repository ()
  "Raise an error unless `default-directory' is inside a Git repository."
  (unless (my-codex--git-repository-p)
    (user-error "Not inside a Git repository (or Git executable missing)")))

(defun my-codex--process-output-lines (program &rest args)
  "Return PROGRAM output lines for ARGS, or nil when PROGRAM fails."
  (with-temp-buffer
    (when (eq 0 (apply #'process-file program nil t nil args))
      (split-string (string-trim-right (buffer-string)) "\n" t))))

(defun my-codex--git-toplevel ()
  "Return the Git repository toplevel for `default-directory'."
  (with-temp-buffer
    (unless (eq 0 (process-file "git" nil t nil
                                "rev-parse" "--show-toplevel"))
      (user-error "Unable to determine Git repository toplevel"))
    (file-name-as-directory (string-trim (buffer-string)))))

(defun my-codex--project-files (root)
  "Return project files relative to ROOT."
  (let ((default-directory root))
    (let ((files
           (if (my-codex--git-repository-p)
               (my-codex--process-output-lines
                "git" "ls-files" "--cached" "--others" "--exclude-standard")
             (when-let (project (project-current nil root))
               (mapcar (lambda (file)
                         (file-relative-name file root))
                       (project-files project))))))
      (sort (or files nil) #'string<))))

(defun my-codex--file-count-label (count)
  "Return a human-readable file count label for COUNT."
  (format "%d %s" count (if (= count 1) "file" "files")))

(defun my-codex--project-tree-lines (files)
  "Return a compact tree summary for project FILES."
  (let ((max-entries my-codex-project-overview-tree-max-entries))
    (cl-labels
        ((split-file (file)
           (split-string file "/" t))
         (group-paths (paths)
           (let ((groups nil))
             (dolist (path paths)
               (when-let ((name (car path)))
                 (let ((cell (assoc name groups)))
                   (if cell
                       (setcdr cell (cons (cdr path) (cdr cell)))
                     (push (cons name (list (cdr path))) groups)))))
             (sort groups (lambda (a b) (string< (car a) (car b))))))
         (render-paths (paths depth indent)
           (let* ((groups (group-paths paths))
                  (root-level (string-empty-p indent))
                  (shown (if root-level
                             groups
                           (seq-take groups max-entries)))
                  (hidden (if root-level
                              0
                            (- (length groups) (length shown))))
                  (lines nil))
             (dolist (group shown)
               (let* ((name (car group))
                      (tails (cdr group))
                      (child-tails (seq-filter #'identity tails)))
                 (if child-tails
                     (progn
                       (push (format "%s%s/ (%s)"
                                     indent
                                     name
                                     (my-codex--file-count-label
                                      (length child-tails)))
                             lines)
                       (if (> depth 1)
                           (setq lines
                                 (append (reverse (render-paths
                                                   child-tails
                                                   (1- depth)
                                                   (concat indent "  ")))
                                         lines))
                         (push (format "%s  ..." indent) lines)))
                   (push (format "%s%s" indent name) lines))))
             (when (> hidden 0)
               (push (format "%s... (%d more entries)" indent hidden) lines))
             (reverse lines))))
      (render-paths (mapcar #'split-file files) 2 ""))))

(defun my-codex--project-files-text (files)
  "Return project FILES text for a project overview prompt."
  (cond
   ((not files)
    "No project files found.")
   ((> (length files) my-codex-project-overview-max-files)
    (format "Project has %d files; showing a compact tree summary:\n%s"
            (length files)
            (string-join (my-codex--project-tree-lines files) "\n")))
   (t
    (string-join files "\n"))))

(defun my-codex--git-status-text (root)
  "Return compact Git status text for ROOT."
  (let ((default-directory root))
    (if (my-codex--git-repository-p)
        (let ((lines (my-codex--process-output-lines "git" "status" "--short")))
          (if lines
              (string-join lines "\n")
            "Clean working tree"))
      "Not a Git repository.")))

(defun my-codex--unsaved-project-buffer-text (root)
  "Return text describing unsaved modified project buffers under ROOT."
  (let ((buffers (my-codex-modified-project-buffers)))
    (if buffers
        (mapconcat
         (lambda (buf)
           (file-relative-name (buffer-file-name buf) root))
         buffers
         "\n")
      "No unsaved modified project buffers.")))

(defun my-codex-send-project-overview ()
  "Send a compact summary of the current project structure to Codex."
  (interactive)
  (let* ((root (my-codex-project-root))
         (default-directory root)
         (files (my-codex--project-files root))
         (files-text (my-codex--project-files-text files)))
    (my-codex--preview-and-send-prompt
     (format "Here is the current state and structure of my project. Use this as orientation context for subsequent requests. Do not inspect files, generate code, or make changes solely because of this message.

**Project root:** `%s`

**Git status:**
```text
%s
```

**Unsaved modified project buffers:**
```text
%s
```

**Project files:**
```text
%s
```
"
             root
             (my-codex--git-status-text root)
             (my-codex--unsaved-project-buffer-text root)
             files-text))))

(defun my-codex--git-comment-char (root)
  "Return Git's commit comment character for ROOT."
  (let* ((default-directory root)
         (value (with-temp-buffer
                  (when (zerop (process-file "git" nil t nil
                                             "config" "--get"
                                             "core.commentChar"))
                    (string-trim (buffer-string))))))
    (if (and value
             (not (string-empty-p value))
             (not (string= value "auto")))
        (substring value 0 1)
      "#")))

(defconst my-codex--commit-template-begin "MY_CODEX_COMMIT_TEMPLATE_BEGIN"
  "Marker for the start of an inserted commit template section.")

(defconst my-codex--commit-template-end "MY_CODEX_COMMIT_TEMPLATE_END"
  "Marker for the end of an inserted commit template section.")

(defun my-codex--strip-commit-template-section (message)
  "Return MESSAGE without an inserted commit template section."
  (with-temp-buffer
    (insert message)
    (goto-char (point-min))
    (while (re-search-forward
            (regexp-quote my-codex--commit-template-begin) nil t)
      (let ((beg (line-beginning-position)))
        (if (re-search-forward
             (regexp-quote my-codex--commit-template-end) nil t)
            (delete-region beg (min (point-max) (1+ (line-end-position))))
          (delete-region beg (point-max)))))
    (buffer-string)))

(defun my-codex--git-commit-template (root)
  "Return Git commit template contents for ROOT, or nil."
  (let* ((default-directory root)
         (path (with-temp-buffer
                 (when (zerop (process-file "git" nil t nil
                                            "config" "--path" "--get"
                                            "commit.template"))
                   (string-trim (buffer-string))))))
    (when (and path
               (not (string-empty-p path))
               (file-readable-p path))
      (with-temp-buffer
        (insert-file-contents path)
        (string-trim-right (buffer-string))))))

(defun my-codex--comment-commit-template (template comment-char)
  "Return TEMPLATE as Git COMMENT-CHAR comment lines."
  (mapconcat
   (lambda (line)
     (cond
      ((string-empty-p line)
       comment-char)
      ((string-prefix-p comment-char line)
       line)
      (t
       (concat comment-char " " line))))
   (split-string template "\n")
   "\n"))

(defun my-codex--commit-template-section (template comment-char)
  "Return TEMPLATE as a marked Git COMMENT-CHAR comment section."
  (my-codex--comment-commit-template
   (string-join
    (list my-codex--commit-template-begin
          template
          my-codex--commit-template-end)
    "\n")
   comment-char))

(defun my-codex--staged-changes-p ()
  "Return non-nil when `default-directory' has staged Git changes."
  (let ((status (process-file "git" nil nil nil
                              "diff" "--cached" "--quiet" "--" ".")))
    (cond
     ((eq status 0) nil)
     ((eq status 1) t)
     (t (user-error "Unable to inspect staged Git changes")))))

(defun my-codex--staged-diff-signature ()
  "Return a hash of the staged Git diff for `default-directory'."
  (with-temp-buffer
    (let ((status (process-file "git" nil t nil
                                "diff" "--cached" "--" ".")))
      (unless (and (integerp status) (zerop status))
        (user-error "Unable to inspect staged Git diff"))
      (secure-hash 'sha1 (current-buffer)))))

(defun my-codex--send-git-prompt (prompt)
  "Send PROMPT to Codex from the project root after checking Git."
  (let ((default-directory (my-codex-project-root)))
    (my-codex--ensure-git-repository)
    (my-codex--preview-and-send-prompt prompt)))

(defun my-codex--git-diff-review-prompt ()
  "Return the prompt for reviewing the current Git diff."
  my-codex-git-diff-review-prompt)

(defun my-codex--git-staged-diff-review-prompt ()
  "Return the prompt for reviewing the staged Git diff."
  my-codex-git-staged-diff-review-prompt)

(defun my-codex--commit-message-prompt ()
  "Return the prompt for drafting a commit message from staged changes."
  (replace-regexp-in-string
   "%d" (number-to-string my-codex-commit-message-fill-column)
   my-codex-commit-message-prompt-template t t))

(defun my-codex-send-git-diff ()
  "Ask Codex to review the current Git diff."
  (interactive)
  (my-codex--send-git-prompt (my-codex--git-diff-review-prompt)))

(defun my-codex-send-git-staged-diff ()
  "Ask Codex to review the staged Git diff."
  (interactive)
  (my-codex--send-git-prompt (my-codex--git-staged-diff-review-prompt)))

(defun my-codex--git-relative-file-name (file root)
  "Return FILE as a path relative to Git repository ROOT."
  (let ((absolute-file (file-truename file))
        (absolute-root (file-name-as-directory (file-truename root))))
    (unless (file-in-directory-p absolute-file absolute-root)
      (user-error "File is not under Git repository root"))
    (file-relative-name absolute-file absolute-root)))

(defun my-codex--git-head-buffer (root relative-file)
  "Return a buffer containing RELATIVE-FILE from HEAD in ROOT.
When RELATIVE-FILE does not exist in HEAD, return an empty buffer."
  (let ((buffer (generate-new-buffer
                 (format "*Codex HEAD:%s*" relative-file))))
    (with-current-buffer buffer
      (let* ((default-directory root)
             (status (process-file "git" nil t nil
                                   "show"
                                   (concat "HEAD:" relative-file))))
        (unless (and (integerp status) (zerop status))
          (erase-buffer)))
      (setq buffer-read-only t))
    buffer))

(defun my-codex--ediff-file-against-head (file project-root)
  "Review FILE against its version in HEAD.
PROJECT-ROOT scopes the command, but HEAD paths are resolved from the Git
repository toplevel."
  (let* ((git-root (let ((default-directory project-root))
                     (my-codex--git-toplevel)))
         (relative-file (my-codex--git-relative-file-name file git-root))
         (head-buffer (my-codex--git-head-buffer git-root relative-file))
         (worktree-buffer (find-file-noselect file)))
    (ediff-buffers head-buffer worktree-buffer)))

(defun my-codex--selected-codex-vterm-window-p ()
  "Return non-nil when the selected window is the current Codex vterm."
  (let ((buffer (window-buffer (selected-window))))
    (and (eq buffer (get-buffer (my-codex-current-buffer-name)))
         (with-current-buffer buffer
           (derived-mode-p 'vterm-mode)))))

(defun my-codex--left-window-file-name ()
  "Return the file visited by the window to the left, or nil."
  (when-let* ((window (window-in-direction 'left (selected-window)))
              (buffer (window-buffer window)))
    (buffer-file-name buffer)))

(defun my-codex--current-or-left-file-name ()
  "Return the current file, using the left window from Codex vterm."
  (cond
   (buffer-file-name)
   ((my-codex--selected-codex-vterm-window-p)
    (or (my-codex--left-window-file-name)
        (user-error "No file-visiting buffer to the left of Codex")))
   (t
    (user-error "Current buffer is not visiting a file"))))

(defun my-codex--current-or-left-file-available-p ()
  "Return non-nil when a file target is available for current-file commands."
  (or buffer-file-name
      (and (my-codex--selected-codex-vterm-window-p)
           (my-codex--left-window-file-name))))

(defun my-codex-ediff-current-file-against-head ()
  "Review the current file's uncommitted changes against HEAD using Ediff.
When invoked from the Codex vterm, use the file in the window to its left."
  (interactive)
  (let ((file (my-codex--current-or-left-file-name))
        (root (my-codex-project-root)))
    (let ((default-directory root))
      (my-codex--ensure-git-repository))
    (my-codex--ediff-file-against-head file root)))

(defun my-codex-ediff-changed-file-against-head ()
  "Choose a tracked changed file and review it against HEAD using Ediff."
  (interactive)
  (let ((root (my-codex-project-root)))
    (let* ((default-directory root)
           (_ (my-codex--ensure-git-repository))
           (files (my-codex--process-output-lines
                   "git" "diff" "--relative" "--name-only"
                   "--diff-filter=ACMT" "HEAD" "--" ".")))
      (unless files
        (user-error "No tracked changed files to review"))
      (my-codex--ediff-file-against-head
       (expand-file-name
        (completing-read "Ediff changed file: " files nil t)
        root)
       root))))

(defun my-codex-commit-message-from-diff ()
  "Ask Codex to draft a commit message from the staged Git diff."
  (interactive)
  (let* ((buffer (my-codex-buffer))
         (root (my-codex-project-root))
         (default-directory root)
         (signature nil))
    (my-codex--ensure-git-repository)
    (unless (my-codex--staged-changes-p)
      (user-error "No staged Git changes to draft a commit message from"))
    (setq signature (my-codex--staged-diff-signature))
    (with-current-buffer buffer
      (setq my-codex--commit-message-request-signature signature)
      (setq my-codex--commit-message-request-marker
            (copy-marker (point-max))))
    (my-codex-send-prompt (my-codex--commit-message-prompt))))

(defun my-codex--terminal-marker-regexp (marker)
  "Return a regexp matching MARKER with terminal whitespace artefacts."
  (mapconcat
   (lambda (char)
     (regexp-quote (char-to-string char)))
   marker
   "[[:space:]\r]*"))

(defun my-codex--trim-blank-lines (text)
  "Return TEXT without leading or trailing blank lines."
  (setq text (replace-regexp-in-string "\\`[ \t\n]*\n" "" text))
  (setq text (replace-regexp-in-string "\n[ \t\n]*\\'" "" text))
  text)

(defun my-codex--common-leading-whitespace-width (text)
  "Return the common leading whitespace width among nonblank lines in TEXT."
  (let (width)
    (dolist (line (split-string text "\n"))
      (unless (string-blank-p line)
        (let ((line-width
               (if (string-match "\\`[ \t]*" line)
                   (length (match-string 0 line))
                 0)))
          (setq width
                (if width
                    (min width line-width)
                  line-width)))))
    (or width 0)))

(defun my-codex--remove-leading-whitespace-width (text width)
  "Return TEXT with WIDTH leading whitespace characters removed per line."
  (if (<= width 0)
      text
    (mapconcat
     (lambda (line)
       (if (string-blank-p line)
           ""
         (replace-regexp-in-string
          (format "\\`[ \t]\\{0,%d\\}" width)
          ""
          line
          nil
          nil)))
     (split-string text "\n")
     "\n")))

(defun my-codex--normalize-marked-output (text)
  "Return generated marked output TEXT without terminal layout indentation."
  (let ((output (my-codex--trim-blank-lines
                 (replace-regexp-in-string "\r" "" text))))
    (my-codex--remove-leading-whitespace-width
     output
     (my-codex--common-leading-whitespace-width output))))

(defun my-codex--latest-marked-output-after
    (buffer start-point begin-marker end-marker &optional ignored-values)
  "Return marked output in BUFFER after START-POINT, or nil.
BEGIN-MARKER and END-MARKER delimit the generated output.  Ignore
empty output and any exact string in IGNORED-VALUES."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (save-restriction
        (widen)
        (save-excursion
          (goto-char (point-max))
          (let* ((valid-start-point-p
                  (and start-point
                       (integer-or-marker-p start-point)
                       (or (not (markerp start-point))
                           (eq (marker-buffer start-point) buffer))
                       (<= (point-min) start-point)
                       (< start-point (point))))
                 (bound (when valid-start-point-p start-point)))
            (when (or (null start-point) bound)
              (when (re-search-backward
                     (my-codex--terminal-marker-regexp begin-marker)
                     bound t)
                (let ((beg (match-end 0)))
                  (when (re-search-forward
                         (my-codex--terminal-marker-regexp end-marker)
                         nil t)
                    (let ((output
                           (my-codex--normalize-marked-output
                            (buffer-substring-no-properties
                             beg
                             (match-beginning 0)))))
                      (unless (member output
                                      (append '("") ignored-values))
                        output))))))))))))

(defun my-codex--wait-for-marked-output
    (buffer start-point begin-marker end-marker callback timeout-message
            ready-message poll-interval poll-attempts &optional
            ignored-values attempts timer-var)
  "Poll BUFFER after START-POINT for marked output, then run CALLBACK.
BEGIN-MARKER and END-MARKER delimit the output.  CALLBACK receives
the extracted text.  ATTEMPTS tracks polling cycles."
  (let ((attempts (or attempts 0))
        (output (my-codex--latest-marked-output-after
                 buffer start-point begin-marker end-marker ignored-values)))
    (cond
     ((> attempts poll-attempts)
      (my-codex--clear-marker start-point)
      (when timer-var
        (my-codex--clear-buffer-local-timer buffer timer-var))
      (message "%s" timeout-message))
     (output
      (my-codex--clear-marker start-point)
      (when timer-var
        (my-codex--clear-buffer-local-timer buffer timer-var))
      (funcall callback output)
      (message "%s" ready-message))
     (t
      (let ((timer
             (run-with-timer
              poll-interval nil
              #'my-codex--wait-for-marked-output
              buffer start-point begin-marker end-marker callback timeout-message
              ready-message poll-interval poll-attempts ignored-values
              (1+ attempts) timer-var)))
        (when (and timer-var (buffer-live-p buffer))
          (with-current-buffer buffer
            (set timer-var timer))))))))

(defun my-codex-latest-commit-message-after (buffer start-point)
  "Return the commit message in BUFFER appearing after START-POINT, or nil."
  (my-codex--latest-marked-output-after
   buffer start-point
   "BEGIN_COMMIT_MESSAGE"
   "END_COMMIT_MESSAGE"
   '("..." "<commit message here>")))

(defun my-codex-latest-commit-message ()
  "Return latest requested commit message from current Codex buffer.
Return nil when no matching message is available."
  (when-let ((buffer (get-buffer (my-codex-current-buffer-name))))
    (with-current-buffer buffer
      (when-let* ((marker my-codex--commit-message-request-marker)
                  ((markerp marker))
                  ((eq (marker-buffer marker) buffer)))
        (my-codex-latest-commit-message-after buffer marker)))))

(defun my-codex--commit-message-buffer-name (root)
  "Return the commit message buffer name for ROOT."
  (format "*Codex commit message:%s*" (my-codex--safe-root-name root)))

(defun my-codex-edit-session-summary (summary root)
  "Open an editable Markdown buffer with Codex session SUMMARY from ROOT."
  (let ((buffer (get-buffer-create (my-codex--session-summary-buffer-name root))))
    (pop-to-buffer buffer)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (string-trim summary))
      (goto-char (point-min)))
    (setq default-directory root)
    (my-codex--session-export-mode)
    (setq-local header-line-format "Edit Codex session summary Markdown.")
    (message "Codex session summary is ready for editing.")))

(defun my-codex--finish-git-commit ()
  "Commit staged changes using the current buffer as the commit message."
  (interactive)
  (let* ((root default-directory)
         (raw-message (buffer-substring-no-properties (point-min) (point-max)))
         (message (my-codex-clean-commit-message
                   (my-codex--strip-commit-template-section raw-message))))
    (when (string-empty-p message)
      (user-error "Commit message is empty"))
    (my-codex-git-commit-with-message message root (current-buffer))))

(defun my-codex--cancel-git-commit ()
  "Cancel the current Codex commit message buffer."
  (interactive)
  (quit-window 'kill)
  (message "Git commit canceled."))

(defun my-codex--quit-commit-buffer (buffer)
  "Kill BUFFER and quit any windows that were opened for it."
  (when (buffer-live-p buffer)
    (quit-windows-on buffer t)))

(defun my-codex-edit-git-commit-with-message (message root)
  "Open an editable Git commit buffer with MESSAGE from ROOT."
  (let ((buffer (get-buffer-create (my-codex--commit-message-buffer-name root))))
    (pop-to-buffer buffer)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (my-codex-clean-commit-message message))
      (when-let (template (my-codex--git-commit-template root))
        (insert "\n\n")
        (insert (my-codex--commit-template-section
                 template
                 (my-codex--git-comment-char root))))
      (goto-char (point-min)))
    (setq default-directory root)
    (text-mode)
    (setq-local header-line-format
                "Edit commit message. C-c C-c commits staged changes; C-c C-k cancels.")
    (let ((map (define-keymap :parent (current-local-map)
                 "C-c C-c" #'my-codex--finish-git-commit
                 "C-c C-k" #'my-codex--cancel-git-commit)))
      (use-local-map map))
    (message "Edit the commit message, then press C-c C-c to commit.")))

(defun my-codex-git-commit-with-message (message root &optional commit-buffer)
  "Run `git commit -F FILE' with MESSAGE from ROOT.
Kill COMMIT-BUFFER after a successful commit when it is non-nil."
  (let ((file (make-temp-file "my-codex-commit-" nil ".txt"))
        (output-buffer (get-buffer-create "*Codex git commit*")))
    (condition-case err
        (progn
          (with-temp-file file
            (insert (my-codex-clean-commit-message message) "\n"))
          (with-current-buffer output-buffer
            (read-only-mode -1)
            (erase-buffer))
          (let* ((default-directory root)
                 (process
                  (make-process
                   :name "my-codex-git-commit"
                   :buffer output-buffer
                   :command (list "git"
                                  "commit"
                                  "--cleanup=strip"
                                  "--no-status"
                                  "-F" file)
                   :connection-type 'pipe
                   :noquery t
                   :sentinel
                   (lambda (proc event)
                     (when (memq (process-status proc) '(exit signal))
                       (let ((status (process-exit-status proc))
                             (buffer (process-buffer proc)))
                         (ignore-errors
                           (delete-file file))
                         (if (zerop status)
                             (progn
                               (when (buffer-live-p commit-buffer)
                                 (my-codex--quit-commit-buffer commit-buffer))
                               (when (buffer-live-p buffer)
                                 (kill-buffer buffer))
                               (message "Git commit finished successfully."))
                           (when (buffer-live-p buffer)
                             (with-current-buffer buffer
                               (goto-char (point-max))
                               (insert (format "\nProcess %s %s"
                                               (process-name proc)
                                               (string-trim event))))
                             (display-buffer buffer))
                           (message "Git commit failed with status %s"
                                    status))))))))
            (set-process-query-on-exit-flag process nil)
            (with-current-buffer output-buffer
              (setq default-directory root))))
      (error
       (ignore-errors
         (delete-file file))
       (signal (car err) (cdr err))))))

(defun my-codex--clear-marker (marker)
  "Detach MARKER from its buffer when MARKER is a marker."
  (when (markerp marker)
    (set-marker marker nil)))

(defun my-codex--clear-buffer-local-timer (buffer timer-var)
  "Cancel and clear TIMER-VAR in BUFFER when it names a timer."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (timerp (symbol-value timer-var))
        (cancel-timer (symbol-value timer-var)))
      (set timer-var nil))))

(defun my-codex--wait-for-commit-message (buffer start-point root &optional attempts)
  "Poll BUFFER after START-POINT for a finished commit message.
ROOT is the Git repository root used for the eventual commit.
ATTEMPTS tracks the number of polling cycles to prevent infinite loops."
  (unless attempts
    (my-codex--clear-buffer-local-timer
     buffer 'my-codex--commit-message-wait-timer))
  (my-codex--wait-for-marked-output
   buffer start-point
   "BEGIN_COMMIT_MESSAGE"
   "END_COMMIT_MESSAGE"
   (lambda (msg)
     (my-codex-edit-git-commit-with-message msg root))
   "Timed out waiting for Codex commit message."
   "Codex commit message is ready for editing."
   my-codex-commit-message-poll-interval
   my-codex-commit-message-poll-attempts
   '("..." "<commit message here>")
   attempts
   'my-codex--commit-message-wait-timer))

(defun my-codex--wait-for-session-summary
    (buffer start-point root begin-marker end-marker
            &optional callback ready-message ignored-values attempts)
  "Poll BUFFER after START-POINT for a finished session summary.
ROOT is the project root used for the editable summary buffer.
BEGIN-MARKER and END-MARKER delimit this request's summary.
CALLBACK receives the summary and defaults to opening an editable buffer.
READY-MESSAGE is shown after a summary is found.
IGNORED-VALUES are additional exact placeholder outputs to ignore.
ATTEMPTS tracks the number of polling cycles to prevent infinite loops."
  (unless attempts
    (my-codex--clear-buffer-local-timer
     buffer 'my-codex--session-summary-wait-timer))
  (my-codex--wait-for-marked-output
   buffer start-point
   begin-marker
   end-marker
   (or callback
       (lambda (summary)
         (my-codex-edit-session-summary summary root)))
   "Timed out waiting for Codex session summary."
   (or ready-message "Codex session summary is ready for editing.")
   my-codex-session-summary-poll-interval
   my-codex-session-summary-poll-attempts
   (append '("..." "<Markdown notes here>") ignored-values)
   attempts
   'my-codex--session-summary-wait-timer))

(defun my-codex-git-commit-with-latest-message ()
  "Edit a commit with the latest Codex message, or ask Codex for one and wait."
  (interactive)
  (let ((root (my-codex-project-root))
        current-signature)
    (let ((default-directory root))
      (my-codex--ensure-git-repository)
      (unless (my-codex--staged-changes-p)
        (user-error "No staged Git changes to commit"))
      (setq current-signature (my-codex--staged-diff-signature)))
    (let* ((buffer (my-codex-buffer))
           marker
           request-signature
           current-request-p)
      (with-current-buffer buffer
        (setq marker my-codex--commit-message-request-marker)
        (setq request-signature my-codex--commit-message-request-signature))
      (setq current-request-p
            (and (markerp marker)
                 (eq (marker-buffer marker) buffer)
                 (equal request-signature current-signature)))
      (if current-request-p
          (if-let (message (my-codex-latest-commit-message-after buffer marker))
              (progn
                (my-codex-edit-git-commit-with-message message root)
                (message "Editing latest Codex commit message."))
            (my-codex--wait-for-commit-message buffer marker root)
            (message "Waiting for Codex commit message."))
        (let ((start-point (with-current-buffer buffer
                             (copy-marker (point-max)))))
          (my-codex-commit-message-from-diff)
          (my-codex--wait-for-commit-message buffer start-point root)
          (message "Asked Codex to draft a commit message; waiting to open editor."))))))

(defun my-codex-explain-region-as-error ()
  "Ask Codex to explain the selected compiler or test error."
  (interactive)
  (unless (use-region-p)
    (user-error "No active region"))
  (my-codex--preview-and-send-prompt
   (format "Please explain this compiler/test error and suggest the most likely fix:\n\n%s"
           (buffer-substring-no-properties (region-beginning) (region-end)))))

(defun my-codex-open-project-instructions ()
  "Open the project Codex/agent instruction file, if present."
  (interactive)
  (let* ((root (my-codex-project-root))
         (file (seq-find (lambda (name)
                           (file-exists-p (expand-file-name name root)))
                         my-codex-project-instruction-files)))
    (if file
        (find-file (expand-file-name file root))
      (user-error "No project instruction file found"))))

(defun my-codex-visible-window ()
  "Return the visible Codex window in the selected frame, or raise an error."
  (or (get-buffer-window (my-codex-current-buffer-name))
      (user-error "No visible Codex window in selected frame")))

(defun my-codex-code-window ()
  "Return the most likely coding window associated with Codex."
  (let ((codex-window (my-codex-visible-window)))
    (let ((code-window (next-window codex-window nil)))
      (if (and code-window (not (eq code-window codex-window)))
          code-window
        (user-error "No coding window found")))))

(defun my-codex-back-to-code ()
  "Move focus to the most likely coding window."
  (interactive)
  (select-window (my-codex-code-window)))

(defun my-codex-toggle-focus ()
  "Toggle focus between the Codex vterm and the coding window."
  (interactive)
  (let ((codex-window (my-codex-visible-window)))
    (cond
     ((eq (selected-window) codex-window) (my-codex-back-to-code))
     (t (select-window codex-window)))))

(defun my-codex-selected-text ()
  "Return actively selected text from the visible Codex window."
  (let ((codex-window (my-codex-visible-window)))
    (with-selected-window codex-window
      (cond
       ((use-region-p)
        (prog1
            (filter-buffer-substring
             (region-beginning)
             (region-end))
          (setq my-codex--captured-selection nil)
          (deactivate-mark)))
       (my-codex--captured-selection
        (prog1 my-codex--captured-selection
          (setq my-codex--captured-selection nil)))
       (t
        (user-error "No active selection in the Codex buffer"))))))

(defun my-codex-insert-selection-into-code ()
  "Insert selected Codex text into the coding window."
  (interactive)
  (let ((text (my-codex-selected-text))
        (code-window (my-codex-code-window)))
    (select-window code-window)
    (insert text)))

(defun my-codex-ask (prompt)
  "Read PROMPT in the minibuffer and send it straight to Codex."
  (interactive "sAsk Codex: ")
  (when (string-blank-p prompt)
    (user-error "Prompt cannot be empty"))
  (my-codex--preview-and-send-prompt prompt))

(defun my-codex--region-context (beg end)
  "Return a context string for the region between BEG and END."
  (let* ((root (my-codex-project-root))
         (file (when buffer-file-name
                 (file-relative-name buffer-file-name root)))
         (line-start (line-number-at-pos beg))
         (line-end (line-number-at-pos (max beg (1- end)))))
    (if file
        (format "In file `%s` (lines %d-%d):" file line-start line-end)
      "From an unnamed buffer:")))

(defun my-codex--read-prompt-preset ()
  "Read and return a prompt preset cons cell."
  (unless my-codex-prompt-presets
    (user-error "No Codex prompt presets configured"))
  (let* ((names (mapcar #'car my-codex-prompt-presets))
         (name (completing-read "Codex preset: " names nil t)))
    (assoc-string name my-codex-prompt-presets)))

(defun my-codex--file-reference-completion-at-point (files)
  "Complete project FILES after an at-sign at the start of a minibuffer line."
  (let ((line-start (max (line-beginning-position) (minibuffer-prompt-end)))
        (point (point)))
    (when (and (< line-start point)
               (eq (char-after line-start) ?@)
               (save-excursion
                 (goto-char (1+ line-start))
                 (looking-at "[^[:space:]]*"))
               (<= point (match-end 0)))
      (list (1+ line-start) point files :exclusive 'no))))

(defun my-codex--read-additional-instructions ()
  "Read optional additional instructions with project file completion.
When a minibuffer line starts with @, complete project-relative file names
after the at-sign with `completion-at-point'."
  (let* ((root (my-codex-project-root))
         (files (my-codex--project-files root)))
    (minibuffer-with-setup-hook
        (lambda ()
          (add-hook 'completion-at-point-functions
                    (lambda ()
                      (my-codex--file-reference-completion-at-point files))
                    nil t)
          (let ((map (copy-keymap (current-local-map))))
            (define-key map (kbd "TAB") #'completion-at-point)
            (define-key map (kbd "<tab>") #'completion-at-point)
            (use-local-map map)))
      (read-string "Additional instructions (optional): "))))

(defun my-codex--ask-with-prompt-preset (preset)
  "Send PRESET, optionally including extra instructions and the active region."
  (let* ((extra (my-codex--read-additional-instructions))
         (has-region (use-region-p))
         (parts (delq nil
                      (list (cdr preset)
                            (unless (string-blank-p extra)
                              extra)
                            (when has-region
                              (let ((beg (region-beginning))
                                    (end (region-end)))
                                (format "%s\n\n%s"
                                        (my-codex--region-context beg end)
                                        (buffer-substring-no-properties
                                         beg end))))))))
    (my-codex--preview-and-send-prompt (string-join parts "\n\n"))))

(defun my-codex-ask-with-preset ()
  "Read a prompt preset by name and send it to Codex.
After selecting a preset, read extra instructions from the minibuffer.
When a region is active, include exact file and line context for it."
  (interactive)
  (my-codex--ask-with-prompt-preset (my-codex--read-prompt-preset)))

(defconst my-codex--preset-transient-keys
  '("1" "2" "3" "4" "5" "6" "7" "8" "9" "0"
    "a" "b" "c" "d" "e" "f" "g" "h" "j" "k" "l" "n" "u" "v" "x" "y" "z")
  "Keys used for dynamically generated prompt preset transient suffixes.")

(defun my-codex--prompt-preset-transient-suffixes (_children)
  "Return transient suffixes for `my-codex-prompt-presets'."
  (let* ((visible-presets (seq-take my-codex-prompt-presets
                                    (length my-codex--preset-transient-keys)))
         (hidden-count (- (length my-codex-prompt-presets)
                          (length visible-presets))))
    (transient-parse-suffixes
     'my-codex-ask-preset-transient
     `[,@(if visible-presets
             (cl-mapcar
              (lambda (key preset)
                (let ((preset preset))
                  (list key (car preset)
                        (lambda ()
                          (interactive)
                          (my-codex--ask-with-prompt-preset preset)))))
              my-codex--preset-transient-keys
              visible-presets)
           '("No prompt presets configured"))
       ,@(when (> hidden-count 0)
           (list (format "%d more preset%s available via C"
                         hidden-count
                         (if (= hidden-count 1) "" "s"))))
       ""
       ("C" "Choose by name" my-codex-ask-with-preset)])))

(transient-define-prefix my-codex-ask-preset-transient ()
  "Ask Codex using a prompt preset."
  [:class transient-column
   :setup-children my-codex--prompt-preset-transient-suffixes])

(defun my-codex--version>= (version minimum)
  "Return non-nil when VERSION is greater than or equal to MINIMUM."
  (not (version< version minimum)))

(defun my-codex--doctor-command-assignment-token-p (token)
  "Return non-nil when TOKEN is a shell environment assignment."
  (and (stringp token)
       (string-match-p "\\`[[:alpha:]_][[:alnum:]_]*=" token)))

(defun my-codex--doctor-command-executable-token (command)
  "Return the executable shell token in COMMAND, or nil."
  (when (and (stringp command)
             (not (string-blank-p command)))
    (let ((tokens (ignore-errors (split-string-shell-command command))))
      (while (and tokens
                  (my-codex--doctor-command-assignment-token-p (car tokens)))
        (setq tokens (cdr tokens)))
      (when (member (car tokens) '("command" "exec"))
        (setq tokens (cdr tokens))
        (while (and tokens
                    (string-prefix-p "-" (car tokens)))
          (when (member (car tokens) '("-a"))
            (setq tokens (cdr tokens)))
          (setq tokens (cdr tokens))))
      (when (and tokens (string= (car tokens) "env"))
        (setq tokens (cdr tokens))
        (while (and tokens
                    (or (my-codex--doctor-command-assignment-token-p (car tokens))
                        (string-prefix-p "-" (car tokens))))
          (when (member (car tokens) '("-u" "--unset" "-C" "--chdir"))
            (setq tokens (cdr tokens)))
          (setq tokens (cdr tokens))))
      (car tokens))))

(defun my-codex--doctor-command-status (label command)
  "Return a diagnostic row for configured shell COMMAND named LABEL."
  (let* ((token (my-codex--doctor-command-executable-token command))
         (available (and token (executable-find token))))
    (list (format "command: %s" label)
          (cond
           (available 'ok)
           (token 'warn)
           (t 'fail))
          (cond
           (available (format "%s (program found at %s)" command available))
           (token (format "%s (program `%s' not found)" command token))
           (t "Not configured")))))

(defun my-codex--doctor-process-output (program &rest args)
  "Run PROGRAM with ARGS and return a cons of exit status and output."
  (with-temp-buffer
    (let ((status (apply #'process-file program nil t nil args)))
      (cons status (string-trim (buffer-string))))))

(defun my-codex--doctor-require-vterm ()
  "Return a cons describing whether `vterm' can be loaded.
The car is non-nil when loading succeeds.  The cdr is a diagnostic detail."
  (condition-case err
      (if (require 'vterm nil t)
          (cons t (format "Loaded from %s"
                          (or (locate-library "vterm") "load-path")))
        (cons nil "Cannot load vterm"))
    (error
     (cons nil (error-message-string err)))))

(defun my-codex--doctor-terminal-start ()
  "Return a diagnostic row describing whether a vterm process starts."
  (let ((buffer (generate-new-buffer " *my-codex-doctor-vterm*"))
        process)
    (unwind-protect
        (condition-case err
            (with-current-buffer buffer
              (vterm-mode)
              (let ((deadline (+ (float-time)
                                 my-codex-doctor-terminal-timeout)))
                (while (and (not (process-live-p (get-buffer-process buffer)))
                            (< (float-time) deadline))
                  (accept-process-output nil 0.05)))
              (setq process (get-buffer-process buffer))
              (if (process-live-p process)
                  (list "terminal startup" 'ok
                        (format "vterm process `%s' is live"
                                (process-name process)))
                (list "terminal startup" 'fail
                      "vterm-mode did not create a live process")))
          (error
           (list "terminal startup" 'fail
                 (error-message-string err))))
      (when (process-live-p process)
        (delete-process process))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun my-codex--doctor-rows ()
  "Return diagnostic rows for `my-codex-doctor'."
  (let* ((root (my-codex-project-root))
         (project (project-current nil default-directory))
         (codex (executable-find "codex"))
         (git (executable-find "git"))
         (gh (executable-find "gh"))
         (vterm-status (my-codex--doctor-require-vterm))
         (vterm-loadable (car vterm-status)))
    (append
     (list
      (list "Emacs version"
            (if (my-codex--version>= emacs-version "29.1") 'ok 'fail)
            (format "%s (requires 29.1 or newer)" emacs-version))
      (list "codex executable"
            (if codex 'ok 'fail)
            (or codex "Not found in exec-path"))
      (if codex
          (pcase-let ((`(,status . ,output)
                       (my-codex--doctor-process-output
                        "codex" "--version")))
            (list "codex --version"
                  (if (eq status 0) 'ok 'fail)
                  (if (string-empty-p output)
                      (format "Exited with status %s and no output" status)
                    output)))
        (list "codex --version" 'fail "Skipped; codex not found"))
      (list "vterm package"
            (if vterm-loadable 'ok 'fail)
            (cdr vterm-status))
      (list "vterm backend"
            (cond
             ((featurep 'vterm-module) 'ok)
             ((and vterm-loadable (fboundp 'vterm-mode)) 'warn)
             (t 'fail))
            (cond
             ((featurep 'vterm-module) "Native module loaded")
             ((and vterm-loadable (fboundp 'vterm-mode))
              "vterm-mode is available; backend will be confirmed by startup check")
             (t "vterm-mode is unavailable")))
      (list "Git executable"
            (if git 'ok 'fail)
            (or git "Not found in exec-path"))
      (if git
          (pcase-let ((`(,status . ,output)
                       (my-codex--doctor-process-output
                        "git" "--version")))
            (list "Git version"
                  (if (eq status 0) 'ok 'fail)
                  (if (string-empty-p output)
                      (format "Exited with status %s and no output" status)
                    output)))
        (list "Git version" 'fail "Skipped; git not found"))
      (list "GitHub CLI executable"
            (if gh 'ok 'warn)
            (or gh "Not found in exec-path; GitHub issue commands will fail"))
      (if gh
          (pcase-let ((`(,status . ,output)
                       (my-codex--doctor-process-output
                        "gh" "--version")))
            (list "gh --version"
                  (if (eq status 0) 'ok 'warn)
                  (if (string-empty-p output)
                      (format "Exited with status %s and no output" status)
                    (car (split-string output "\n")))))
        (list "gh --version" 'warn "Skipped; gh not found"))
      (list "current directory is a project"
            (if project 'ok 'warn)
            (if project
                (format "Project root: %s" (project-root project))
              (format "No project detected; using %s" root)))
      (list "AGENTS.md"
            (if (file-exists-p (expand-file-name "AGENTS.md" root))
                'ok
              'warn)
            (if (file-exists-p (expand-file-name "AGENTS.md" root))
                (expand-file-name "AGENTS.md" root)
              (format "Not found in %s" root))))
     (list
      (my-codex--doctor-command-status
       "read-only" my-codex-read-only-command)
      (my-codex--doctor-command-status
       "workspace" my-codex-workspace-command)
      (my-codex--doctor-command-status
       "resume" my-codex-resume-command)
      (list "command: project build"
            (if my-codex-project-build-command 'ok 'warn)
            (or my-codex-project-build-command
                (format "Uses compile-command: %s"
                        compile-command)))
      (if vterm-loadable
          (my-codex--doctor-terminal-start)
        (list "terminal startup" 'fail
              "Skipped; vterm cannot be loaded"))))))

(defun my-codex--doctor-status-label (status)
  "Return display label for diagnostic STATUS."
  (pcase status
    ('ok "OK")
    ('warn "WARN")
    ('fail "FAIL")
    (_ "INFO")))

(defun my-codex--doctor-insert-row (row)
  "Insert diagnostic ROW in the current buffer."
  (pcase-let ((`(,check ,status ,detail) row))
    (insert (format "%-34s %-5s %s\n"
                    check
                    (my-codex--doctor-status-label status)
                    detail))))

;;;###autoload
(defun my-codex-doctor ()
  "Run a health check for the local Codex Emacs integration."
  (interactive)
  (let ((buffer (get-buffer-create "*my-codex-doctor*"))
        (root default-directory)
        rows)
    (setq rows (my-codex--doctor-rows))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "my-codex doctor\nDirectory: %s\n\n" root))
        (insert (format "%-34s %-5s %s\n" "Check" "State" "Details"))
        (insert (make-string 78 ?-) "\n")
        (mapc #'my-codex--doctor-insert-row rows))
      (special-mode))
    (display-buffer buffer)
    (if (seq-some (lambda (row) (eq (cadr row) 'fail)) rows)
        (message "my-codex doctor finished with failures")
      (message "my-codex doctor finished"))))

;; Prefix keymap for Codex commands.
(defvar-keymap my-codex-map
  :doc "Prefix keymap for Codex commands."
  "o"       #'my-codex-read-only
  "w"       #'my-codex-workspace
  "r"       #'my-codex-resume
  "q"       #'my-codex-restore-layout
  "a"       #'my-codex-ask
  "A"       #'my-codex-ask-preset-transient
  "s"       #'my-codex-send-region
  "<right>" #'my-codex-send-region
  "<left>"  #'my-codex-insert-selection-into-code
  "f"       #'my-codex-send-current-file
  "C"       #'my-codex-analyse-test-coverage
  "x"       #'my-codex-explain-symbol-at-point
  "g"       #'my-codex-send-git-diff
  "G"       #'my-codex-send-git-staged-diff
  "d"       #'my-codex-ediff-current-file-against-head
  "D"       #'my-codex-ediff-changed-file-against-head
  "m"       #'my-codex-commit-message-from-diff
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

(transient-define-prefix my-codex-transient ()
  "Show Codex commands."
  [["Session"
    ("o" "Read-only" my-codex-read-only)
    ("w" "Workspace" my-codex-workspace)
    ("r" "Resume" my-codex-resume)
    ("q" "Hide Codex" my-codex-restore-layout)
    ("<tab>" "Toggle focus" my-codex-toggle-focus)]
   ["Send"
    ("a" "Ask" my-codex-ask)
    ("A" "Preset menu" my-codex-ask-preset-transient)
    ("s" "Region" my-codex-send-region)
    ("<right>" "Region" my-codex-send-region)
    ("<left>" "Insert selection" my-codex-insert-selection-into-code)
    ("f" "Current file" my-codex-send-current-file)
    ("C" "Coverage gaps" my-codex-analyse-test-coverage)
    ("x" "Explain symbol" my-codex-explain-symbol-at-point)
    ("p" "Project overview" my-codex-send-project-overview)]
   ["Git"
    ("g" "Review diff" my-codex-send-git-diff)
    ("G" "Review staged diff" my-codex-send-git-staged-diff)
    ("d" "Ediff current file" my-codex-ediff-current-file-against-head)
    ("D" "Ediff changed file" my-codex-ediff-changed-file-against-head)
    ("m" "Draft commit message" my-codex-commit-message-from-diff)
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

(defvar-local my-codex--vterm-copy-mode-saved-header-line-format :unset
  "Previous `header-line-format' before showing the vterm copy mode hint.")

(defun my-codex--vterm-copy-mode-header-line ()
  "Show or hide a reminder while `vterm-copy-mode' is active."
  (if (bound-and-true-p vterm-copy-mode)
      (progn
        (when (eq my-codex--vterm-copy-mode-saved-header-line-format :unset)
          (setq my-codex--vterm-copy-mode-saved-header-line-format
                header-line-format))
        (setq header-line-format
              '(:eval
                (propertize
                 " vterm-copy-mode: scroll/copy mode -- press C-c C-t to return to Codex input "
                 'face 'warning))))
    (unless (eq my-codex--vterm-copy-mode-saved-header-line-format :unset)
      (setq header-line-format
            my-codex--vterm-copy-mode-saved-header-line-format)
      (setq my-codex--vterm-copy-mode-saved-header-line-format :unset)))
  (force-mode-line-update))

(defun my-codex--disable-vterm-editing-minor-modes ()
  "Disable editing minor modes that are not useful in `vterm-mode'."
  (when (eq major-mode 'vterm-mode)
    (dolist (mode '(company-mode flyspell-mode display-line-numbers-mode))
      (when (and (boundp mode)
                 (symbol-value mode)
                 (fboundp mode))
        (funcall mode -1)))))

(defun my-codex--shorten-vterm-copy-mode-lighter ()
  "Show `vterm-copy-mode' as a short highlighted mode-line lighter."
  (let ((entry (assq 'vterm-copy-mode minor-mode-alist)))
    (when entry
      (setcdr entry '((:propertize " Copy" face warning))))))

(with-eval-after-load 'vterm
  (my-codex--shorten-vterm-copy-mode-lighter)
  (when (boundp 'vterm-mode-map)
    (keymap-set vterm-mode-map "S-<insert>" #'vterm-yank)
    (keymap-set vterm-mode-map "<prior>"    #'scroll-down-command)
    (keymap-set vterm-mode-map "<next>"     #'scroll-up-command)
    (keymap-set vterm-mode-map "<f8>"       #'my-codex-transient-preserve-selection))
  (when (boundp 'vterm-copy-mode-map)
    (keymap-set vterm-copy-mode-map "<f8>"  #'my-codex-transient-preserve-selection))
  (add-hook 'vterm-mode-hook
            #'my-codex--disable-vterm-editing-minor-modes)
  (add-hook 'after-change-major-mode-hook
            #'my-codex--disable-vterm-editing-minor-modes
            100)
  (add-hook 'vterm-copy-mode-hook
            #'my-codex--vterm-copy-mode-header-line))

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
  (setq-default show-trailing-whitespace t)
  (column-number-mode 1))

(defun my-codex--restore-display-defaults ()
  "Restore display defaults changed by `my-codex-global-mode'."
  (when my-codex--display-defaults-enabled-by-mode
    (setq-default show-trailing-whitespace
                  my-codex--saved-show-trailing-whitespace)
    (column-number-mode
     (if my-codex--saved-column-number-mode 1 -1))
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
     ["Resume session" my-codex-resume
      :keys "F8 r"
      :help "Resume a previous Codex session"]
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
     ["Ediff current file against HEAD" my-codex-ediff-current-file-against-head
      :keys "F8 d"
      :active (my-codex--current-or-left-file-available-p)
      :help "Review the current file's uncommitted changes against HEAD"]
     ["Ediff changed file against HEAD" my-codex-ediff-changed-file-against-head
      :keys "F8 D"
      :help "Choose a tracked changed file and review it against HEAD"]
     ["Draft commit message" my-codex-commit-message-from-diff
      :keys "F8 m"
      :help "Ask Codex to draft a commit message from the staged Git diff"]
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
        (my-codex--enable-display-defaults)
        (when (and my-codex-enable-global-auto-revert
                   (not my-codex--auto-revert-enabled-by-mode)
                   (not (bound-and-true-p global-auto-revert-mode)))
          (setq my-codex--auto-revert-enabled-by-mode t)
          (global-auto-revert-mode 1)))
    (when my-codex--auto-revert-enabled-by-mode
      (global-auto-revert-mode -1))
    (my-codex--restore-display-defaults)
    (setq my-codex--auto-revert-enabled-by-mode nil)))

(provide 'my-codex)

;;; my-codex.el ends here
