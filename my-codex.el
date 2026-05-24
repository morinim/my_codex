;;; my-codex.el --- Codex integration -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Manlio Morini

;; Author: Manlio Morini
;; Keywords: tools, convenience
;; URL: https://github.com/morinim/my_codex
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (vterm "0"))

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
(require 'easymenu)
(require 'project)
(require 'seq)
(require 'subr-x)

;; `vterm' is loaded lazily, only when Codex is opened or used.
(declare-function vterm "vterm")
(declare-function vterm-send-string "vterm")
(declare-function vterm-send-return "vterm")
(declare-function vterm-yank "vterm")
(declare-function vterm-copy-mode "vterm")
(defvar vterm-mode-map)

(defgroup my-codex nil
  "Customisation options for the Codex development tool."
  :group 'convenience
  :prefix "my/codex-")

(defcustom my/codex-buffer-name "*codex*"
  "Name of the vterm buffer used for Codex."
  :type 'string
  :group 'my-codex)

(defcustom my/codex-read-only-command
  "codex --sandbox read-only --ask-for-approval on-request"
  "Command used to start Codex in read-only mode."
  :type 'string
  :group 'my-codex)

(defcustom my/codex-workspace-command
  "codex --sandbox workspace-write --ask-for-approval on-request"
  "Command used to start Codex with workspace write access."
  :type 'string
  :group 'my-codex)

(defcustom my/codex-resume-command
  "codex resume"
  "Command used to resume a previous Codex session."
  :type 'string
  :group 'my-codex)

(defcustom my/codex-left-width 80
  "Width of the editing window text area in the Codex two-column layout."
  :type 'natnum
  :group 'my-codex)

(defcustom my/codex-min-right-width 80
  "Minimum width of the Codex vterm window."
  :type 'natnum
  :group 'my-codex)

(defcustom my/codex-project-instruction-files
  '("AGENTS.md" "CODEX.md" ".codex/instructions.md")
  "Candidate project instruction files for Codex."
  :type '(repeat string)
  :group 'my-codex)

(defcustom my/codex-project-build-command "./setup_build"
  "Command used to build the current project."
  :type 'string
  :group 'my-codex)

(defcustom my/codex-warn-about-unsaved-project-buffers t
  "When non-nil, warn before sending prompts if project buffers are unsaved."
  :type 'boolean
  :group 'my-codex)

(defvar my/codex--saved-window-configuration nil
  "Window layout configuration captured before opening Codex.")

(defun my/codex-project-root ()
  "Return the current project root, or `default-directory' if not in a project."
  (if-let ((project (project-current)))
      (project-root project)
    default-directory))

(defun my/codex-current-buffer-name ()
  "Return a project-specific buffer name for the Codex session."
  (if-let ((project (project-current)))
      (format "*codex:%s*"
              (file-name-nondirectory
               (directory-file-name (project-root project))))
    my/codex-buffer-name))

(defun my/codex-modified-project-buffers ()
  "Return modified file-visiting buffers belonging to the current project."
  (if-let ((project (project-current)))
      (seq-filter (lambda (buf)
                    (and (buffer-local-value 'buffer-file-name buf)
                         (buffer-modified-p buf)))
                  (project-buffers project))
    ;; Outside project, limit the warning to buffers under `default-directory'.
    (let ((root (file-truename default-directory)))
      (seq-filter (lambda (buf)
                    (when-let ((file (buffer-file-name buf)))
                      (and (buffer-modified-p buf)
                           (file-in-directory-p (file-truename file) root))))
                  (buffer-list)))))

(defun my/codex-warn-about-unsaved-project-buffers ()
  "Display a non-blocking warning if project buffers have unsaved changes."
  (when my/codex-warn-about-unsaved-project-buffers
    (when-let ((buffers (my/codex-modified-project-buffers)))
      (message "Codex warning: %d modified project buffer(s) not saved; disk context may be stale"
               (length buffers)))))

(defun my/codex-two-column-layout-with-command (codex-command &optional focus-term)
  "Open a two-column layout and run CODEX-COMMAND in vterm if not running.
If FOCUS-TERM is non-nil, leave the cursor focused on the terminal window."
  (require 'vterm)
  (let* ((decorations-padding 8)
         (required-width (+ my/codex-left-width
                            my/codex-min-right-width
                            decorations-padding))
         (buffer-name (my/codex-current-buffer-name))
         (existing-buf (get-buffer buffer-name)))

    (when (< (frame-width) required-width)
      (set-frame-width (selected-frame) required-width)
      (redisplay t))

    (when (and existing-buf (not (get-buffer-process existing-buf)))
      (kill-buffer existing-buf)
      (setq existing-buf nil))

    ;; Capture layout only if the target session buffer is not currently displayed.
    (unless (get-buffer-window buffer-name t)
      (setq my/codex--saved-window-configuration (current-window-configuration)))

    (delete-other-windows)
    (let* ((edit-window (selected-window))
           (term-window (condition-case nil
                            (split-window-right my/codex-left-width)
                          (error
                           (user-error "Frame is too narrow for Codex layout")))))

      ;; Adjust once for fringes, scrollbars, and dividers.
      (let ((delta (- my/codex-left-width (window-body-width edit-window))))
        (unless (zerop delta)
          (when (window-resizable-p edit-window delta t t)
            (window-resize edit-window delta t t))))

      (select-window term-window)
      (if (and existing-buf (get-buffer-process existing-buf))
          (set-window-buffer term-window existing-buf)
        (let ((buffer (vterm buffer-name)))
          (with-current-buffer buffer
            (when-let ((proc (get-buffer-process buffer)))
              (set-process-query-on-exit-flag proc nil))
            (goto-char (point-max))
            (vterm-send-string codex-command)
            (vterm-send-return))))

      (unless focus-term
        (select-window edit-window)))))

(defun my/codex-restore-layout ()
  "Restore the window layout configuration used before Codex was opened."
  (interactive)
  (if my/codex--saved-window-configuration
      (let ((config my/codex--saved-window-configuration))
        (setq my/codex--saved-window-configuration nil)
        (set-window-configuration config)
        (message "Restored previous window layout"))
    (user-error "No saved window configuration found")))

(defun my/codex-read-only ()
  "Show Codex, starting it in read-only mode if needed."
  (interactive)
  (my/codex-two-column-layout-with-command my/codex-read-only-command))

(defun my/codex-workspace ()
  "Show Codex, starting it with workspace write access if needed."
  (interactive)
  (my/codex-two-column-layout-with-command my/codex-workspace-command))

(defun my/codex-resume ()
  "Show Codex, resuming a previous session if needed and focusing the window."
  (interactive)
  (my/codex-two-column-layout-with-command my/codex-resume-command t))

(defun my/codex-buffer ()
  "Return the current project's Codex vterm buffer, or raise an error."
  (let* ((buffer-name (my/codex-current-buffer-name))
         (buffer (get-buffer buffer-name)))
    (unless buffer
      (user-error "No %s buffer found" buffer-name))
    (unless (get-buffer-process buffer)
      (user-error "No running Codex process in %s" buffer-name))
    buffer))

(defun my/codex-send-prompt (prompt)
  "Send PROMPT to the Codex vterm buffer and show it."
  (my/codex-warn-about-unsaved-project-buffers)
  (let ((buffer (my/codex-buffer)))
    (require 'vterm)
    (with-demoted-errors "Codex send error: %S"
      (when (buffer-live-p buffer)
        (if-let ((window (get-buffer-window buffer t)))
            (select-window window)
          (pop-to-buffer buffer))
        (redisplay t)
        (with-current-buffer buffer
          (goto-char (point-max))
          (vterm-send-string prompt)
          (vterm-send-return))))))

(defun my/codex-send-region (beg end)
  "Send the selected region to the Codex vterm buffer with exact file context."
  (interactive "r")
  (unless (use-region-p)
    (user-error "No active region"))
  (let* ((root (my/codex-project-root))
         (file (when buffer-file-name
                 (file-relative-name buffer-file-name root)))
         (line-start (line-number-at-pos beg))
         (line-end (line-number-at-pos (max beg (1- end))))
         (context (if file
                      (format "In file `%s` (lines %d-%d):"
                              file line-start line-end)
                    "From an unnamed buffer:")))
    (my/codex-send-prompt
     (format "%s\n\nPlease review this code and report findings:\n\n%s"
             context
             (buffer-substring-no-properties beg end)))))

(defun my/codex-send-current-file ()
  "Ask Codex to inspect the current file directly."
  (interactive)
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a file"))
  (let* ((root (my/codex-project-root))
         (file (file-relative-name buffer-file-name root)))
    (my/codex-send-prompt
     (format "Please inspect `%s` directly and report findings. Do not edit it unless I explicitly ask.\n"
             file))))

(defun my/git-repository-p ()
  "Return non-nil if `default-directory' is inside a Git repository."
  (and (executable-find "git")
       (let ((status (call-process "git" nil nil nil
                                   "rev-parse" "--is-inside-work-tree")))
         (and (integerp status)
              (zerop status)))))

(defun my/ensure-git-repository ()
  "Raise an error unless `default-directory' is inside a Git repository."
  (unless (my/git-repository-p)
    (user-error "Not inside a Git repository (or Git executable missing)")))

(defun my/codex-send-git-diff ()
  "Ask Codex to review the current Git diff."
  (interactive)
  (let ((default-directory (my/codex-project-root)))
    (my/ensure-git-repository)
    (my/codex-send-prompt
     "Please review the current Git diff using `git diff -- .`. Focus on correctness, regressions, edge cases, naming, and maintainability. Do not edit files unless I explicitly ask.\n")))

(defun my/codex-send-git-staged-diff ()
  "Ask Codex to review the staged Git diff."
  (interactive)
  (let ((default-directory (my/codex-project-root)))
    (my/ensure-git-repository)
    (my/codex-send-prompt
     "Please review the staged Git diff using `git diff --cached -- .`. Focus on correctness, regressions, edge cases, and commit readiness. Do not edit files unless I explicitly ask.\n")))

(defun my/codex-commit-message-from-diff ()
  "Ask Codex to draft a commit message from the staged Git diff."
  (interactive)
  (let ((default-directory (my/codex-project-root)))
    (my/ensure-git-repository)
    (my/codex-send-prompt
     "Please inspect the staged Git diff using `git diff --cached -- .` and write a concise but comprehensive conventional commit message. Use an imperative subject and a short explanatory body when useful. Do not edit files.\n")))

(defun my/codex-explain-region-as-error ()
  "Ask Codex to explain the selected compiler or test error."
  (interactive)
  (unless (use-region-p)
    (user-error "No active region"))
  (my/codex-send-prompt
   (format "Please explain this compiler/test error and suggest the most likely fix:\n\n%s"
           (buffer-substring-no-properties
            (region-beginning)
            (region-end)))))

(defun my/codex-open-project-instructions ()
  "Open the project Codex/agent instruction file, if present."
  (interactive)
  (let* ((root (my/codex-project-root))
         (file (seq-find
                (lambda (name)
                  (file-exists-p (expand-file-name name root)))
                my/codex-project-instruction-files)))
    (if file
        (find-file (expand-file-name file root))
      (user-error "No project instruction file found"))))

(defun my/codex-code-window ()
  "Return the most likely coding window associated with Codex."
  (let ((codex-window (get-buffer-window (my/codex-current-buffer-name) t)))
    (unless codex-window
      (user-error "No visible Codex window"))
    (let ((code-window (next-window codex-window nil t)))
      (if (and code-window (not (eq code-window codex-window)))
          code-window
        (user-error "No coding window found")))))

(defun my/codex-back-to-code ()
  "Move focus to the most likely coding window."
  (interactive)
  (select-window (my/codex-code-window)))

(defun my/codex-toggle-focus ()
  "Toggle focus between the Codex vterm and the coding window."
  (interactive)
  (let ((codex-window (get-buffer-window (my/codex-current-buffer-name) t)))
    (cond
     ((not codex-window)
      (user-error "No visible Codex window"))
     ((eq (selected-window) codex-window)
      (my/codex-back-to-code))
     (t
      (select-window codex-window)))))

(defun my/codex-selected-text ()
  "Return selected text from the current project's Codex buffer."
  (let ((codex-buffer (get-buffer (my/codex-current-buffer-name))))
    (unless (eq (current-buffer) codex-buffer)
      (user-error "Current buffer is not the Codex buffer")))
  (unless (use-region-p)
    (user-error "No active region"))
  (filter-buffer-substring (region-beginning) (region-end)))

(defun my/codex-insert-selection-into-code ()
  "Insert selected Codex text into the coding window."
  (interactive)
  (let ((text (my/codex-selected-text))
        (code-window (my/codex-code-window)))
    (with-selected-window code-window
      (unless (bolp)
        (newline))
      (insert text)
      (unless (bolp)
        (newline)))))

(defun my/codex-ask (prompt)
  "Prompt the user in the minibuffer and send the query straight to Codex."
  (interactive "sAsk Codex: ")
  (when (string-blank-p prompt)
    (user-error "Prompt cannot be empty"))
  (my/codex-send-prompt prompt))

(defun my/codex-help ()
  "Show Codex key bindings."
  (interactive)
  (message
   "Codex: F7=build, F8 o=show/start read-only, w=show/start workspace, r=resume, q=restore layout, a=ask, s/right=send region, left=insert selected Codex text, f=file, g=diff, G=staged diff, m=commit message, e=explain error, i=instructions, TAB=toggle focus, ?=help"))

;; Prefix keymap for Codex commands.
(defvar-keymap my/codex-map
  :doc "Prefix keymap for Codex commands."
  "o"       #'my/codex-read-only
  "w"       #'my/codex-workspace
  "r"       #'my/codex-resume
  "q"       #'my/codex-restore-layout
  "a"       #'my/codex-ask
  "s"       #'my/codex-send-region
  "<right>" #'my/codex-send-region
  "<left>"  #'my/codex-insert-selection-into-code
  "f"       #'my/codex-send-current-file
  "g"       #'my/codex-send-git-diff
  "G"       #'my/codex-send-git-staged-diff
  "m"       #'my/codex-commit-message-from-diff
  "e"       #'my/codex-explain-region-as-error
  "i"       #'my/codex-open-project-instructions
  "TAB"     #'my/codex-toggle-focus
  "<tab>"   #'my/codex-toggle-focus
  "?"       #'my/codex-help)

(with-eval-after-load 'vterm
  (keymap-set vterm-mode-map "S-<insert>" #'vterm-yank)
  (keymap-set vterm-mode-map "C-c C-t"   #'vterm-copy-mode)
  (keymap-set vterm-mode-map "<f8>"      my/codex-map))

(defun my/codex-project-build ()
  "Run the project build command with `compile'."
  (interactive)
  (let ((default-directory (my/codex-project-root)))
    (compile my/codex-project-build-command)))

(defvar-keymap my-codex-global-mode-map
  :doc "Keymap for `my-codex-global-mode'."
  "<f7>" #'my/codex-project-build
  "<f8>" my/codex-map)

(easy-menu-define my/codex-menu nil
  "Menu for Codex commands."
  '("Codex"
    ["Show/start read-only" my/codex-read-only
     :help "Show Codex, starting it in read-only mode if needed"]
    ["Show/start workspace-write" my/codex-workspace
     :help "Show Codex, starting it with workspace write access if needed"]
    ["Resume session" my/codex-resume
     :help "Resume a previous Codex session"]
    ["Restore window layout" my/codex-restore-layout
     :help "Restore the layout configuration to how it was before opening Codex"]
    ["Ask Codex..." my/codex-ask
     :help "Prompt for a question and send it to Codex"]
    "---"
    ["Send selected region" my/codex-send-region
     :active (use-region-p)
     :help "Send the selected region to Codex"]
    ["Explain selected error" my/codex-explain-region-as-error
     :active (use-region-p)
     :help "Ask Codex to explain the selected compiler/test error"]
    ["Inspect current file" my/codex-send-current-file
     :active buffer-file-name
     :help "Ask Codex to inspect the current file directly"]
    "---"
    ["Review Git diff" my/codex-send-git-diff
     :help "Ask Codex to review the current Git diff"]
    ["Review staged Git diff" my/codex-send-git-staged-diff
     :help "Ask Codex to review the staged Git diff"]
    ["Draft commit message" my/codex-commit-message-from-diff
     :help "Ask Codex to draft a commit message from the staged Git diff"]
    "---"
    ["Open project instructions" my/codex-open-project-instructions
     :help "Open AGENTS.md, CODEX.md, or .codex/instructions.md"]
    ["Show key bindings" my/codex-help
     :help "Show Codex key bindings"]
    "---"
    ["Compile project" my/codex-project-build
     :help "Run the project build command"]))

;;;###autoload
(define-minor-mode my-codex-global-mode
  "Global minor mode for seamless Codex integration."
  :global t
  :group 'my-codex
  :keymap my-codex-global-mode-map
  (if my-codex-global-mode
      (keymap-set global-map
                  "<menu-bar> <tools> <codex>"
                  (cons "Codex" my/codex-menu))
    (keymap-unset global-map "<menu-bar> <tools> <codex>" t)))

(provide 'my-codex)

;;; my-codex.el ends here
