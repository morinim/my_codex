;;; my-codex.el --- Codex integration -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Manlio Morini

;; Author: Manlio Morini
;; Keywords: tools, convenience
;; URL: https://github.com/morinim/my_codex
;; Version: 0.2.0
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

(declare-function vterm "vterm")
(declare-function vterm-send-string "vterm")
(declare-function vterm-send-return "vterm")
(declare-function vterm-yank "vterm")
(declare-function vterm-copy-mode "vterm")
(defvar vterm-mode-map)

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

(defcustom my-codex-left-width 80
  "Width of the editing window text area in the Codex two-column layout."
  :type 'natnum
  :group 'my-codex)

(defcustom my-codex-min-right-width 80
  "Minimum width of the Codex vterm window."
  :type 'natnum
  :group 'my-codex)

(defcustom my-codex-project-instruction-files
  '("AGENTS.md" "CODEX.md" ".codex/instructions.md")
  "Candidate project instruction files for Codex."
  :type '(repeat string)
  :group 'my-codex)

(defcustom my-codex-project-build-command "./setup_build"
  "Command used to build the current project."
  :type 'string
  :group 'my-codex)

(defcustom my-codex-warn-about-unsaved-project-buffers t
  "When non-nil, warn before sending prompts if project buffers are unsaved."
  :type 'boolean
  :group 'my-codex)

(defcustom my-codex-enable-global-auto-revert t
  "When non-nil, enable `global-auto-revert-mode' with `my-codex-global-mode'."
  :type 'boolean
  :group 'my-codex)

(defvar my-codex--saved-window-configuration nil
  "Window layout configuration captured before opening Codex.")

(defun my-codex-project-root ()
  "Return the current project root, or `default-directory' if not in a project."
  (file-name-as-directory
   (if-let ((project (project-current)))
       (project-root project)
     default-directory)))

(defun my-codex-current-buffer-name ()
  "Return a project-specific buffer name for the Codex session."
  (if-let* ((project (project-current))
            (root (file-truename (project-root project))))
      (format "*codex:%s*"
              (replace-regexp-in-string
               "[^[:alnum:]._-]+" "!"
               (directory-file-name root)))
    my-codex-buffer-name))

(defun my-codex-modified-project-buffers ()
  "Return modified file-visiting buffers belonging to the current project."
  (if-let ((project (project-current)))
      (seq-filter (lambda (buf)
                    (and (buffer-local-value 'buffer-file-name buf)
                         (buffer-modified-p buf)))
                  (project-buffers project))
    (let ((root (file-truename default-directory)))
      (seq-filter (lambda (buf)
                    (when-let ((file (buffer-file-name buf)))
                      (and (buffer-modified-p buf)
                           (file-in-directory-p (file-truename file) root))))
                  (buffer-list)))))

(defun my-codex-warn-about-unsaved-project-buffers ()
  "Display a non-blocking warning if project buffers have unsaved changes."
  (when my-codex-warn-about-unsaved-project-buffers
    (when-let ((buffers (my-codex-modified-project-buffers)))
      (message "Codex warning: unsaved buffer(s): %s"
               (string-join (mapcar #'buffer-name buffers) ", ")))))

(defun my-codex-two-column-layout-with-command (codex-command &optional focus-term)
  "Open a two-column layout and run CODEX-COMMAND in vterm if not running.
If FOCUS-TERM is non-nil, leave the cursor focused on the terminal window."
  (require 'vterm)
  (let* ((decorations-padding 8)
         (required-width (+ my-codex-left-width
                            my-codex-min-right-width
                            decorations-padding))
         (buffer-name (my-codex-current-buffer-name))
         (existing-buf (get-buffer buffer-name)))

    (when (< (frame-width) required-width)
      (condition-case nil
          (progn
            (set-frame-width (selected-frame) required-width)
            (redisplay t))
        (error nil)))

    (when (and existing-buf (not (get-buffer-process existing-buf)))
      (kill-buffer existing-buf)
      (setq existing-buf nil))

    (unless (get-buffer-window buffer-name t)
      (setq my-codex--saved-window-configuration (current-window-configuration)))

    (delete-other-windows)
    (let* ((edit-window (selected-window))
           (term-window (condition-case nil
                            (split-window-right my-codex-left-width)
                          (error
                           (user-error "Frame is too narrow for Codex layout"))))
           (delta (- my-codex-left-width (window-body-width edit-window))))

      (when (and (not (zerop delta)) (window-resizable-p edit-window delta t t))
        (window-resize edit-window delta t t))

      (select-window term-window)
      (if (and existing-buf (get-buffer-process existing-buf))
          (set-window-buffer term-window existing-buf)
        (let ((default-directory (my-codex-project-root)))
          (let ((buffer (vterm buffer-name)))
            (with-current-buffer buffer
              (when-let ((proc (get-buffer-process buffer)))
                (set-process-query-on-exit-flag proc nil))
              (goto-char (point-max))
              (vterm-send-string codex-command)
              (vterm-send-return)))))
      (unless focus-term
        (select-window edit-window)))))

(defun my-codex-restore-layout ()
  "Restore the window layout configuration used before Codex was opened."
  (interactive)
  (if my-codex--saved-window-configuration
      (let ((config my-codex--saved-window-configuration))
        (setq my-codex--saved-window-configuration nil)
        (set-window-configuration config)
        (message "Restored previous window layout"))
    (user-error "No saved window configuration found")))

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
    (unless (get-buffer-process buffer)
      (user-error "No running Codex process in %s" buffer-name))
    buffer))

(defun my-codex-send-prompt (prompt)
  "Send PROMPT to the Codex vterm buffer and show it."
  (my-codex-warn-about-unsaved-project-buffers)
  (require 'vterm)
  (let ((buffer (my-codex-buffer)))
    (if-let ((window (get-buffer-window buffer t)))
        (select-window window)
      (pop-to-buffer buffer))
    (redisplay t)
    (with-current-buffer buffer
      (goto-char (point-max))
      (vterm-send-string prompt)
      (vterm-send-return))))

(defun my-codex--codex-buffers ()
  "Return Codex buffers, preferring the current project's buffer."
  (let ((current (get-buffer (my-codex-current-buffer-name)))
        (codex-buffers
         (seq-filter
          (lambda (buffer)
            (string-match-p "\\`\\*codex\\(?::.*\\)?\\*\\'"
                            (buffer-name buffer)))
          (buffer-list))))
    (delete-dups (delq nil (cons current codex-buffers)))))

(defun my-codex-send-region (beg end)
  "Send the selected region to the Codex vterm buffer with exact file context."
  (interactive "r")
  (unless (use-region-p)
    (user-error "No active region"))
  (let* ((root (my-codex-project-root))
         (file (when buffer-file-name
                 (file-relative-name buffer-file-name root)))
         (line-start (line-number-at-pos beg))
         (line-end (line-number-at-pos (max beg (1- end))))
         (context (if file
                      (format "In file `%s` (lines %d-%d):" file line-start line-end)
                    "From an unnamed buffer:")))
    (my-codex-send-prompt
     (format "%s\n\nPlease review this code and report findings:\n\n%s"
             context
             (buffer-substring-no-properties beg end)))))

(defun my-codex-send-current-file ()
  "Ask Codex to inspect the current file directly."
  (interactive)
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a file"))
  (let* ((root (my-codex-project-root))
         (file (file-relative-name buffer-file-name root)))
    (my-codex-send-prompt
     (format "Please inspect `%s` directly and report findings. Do not edit it unless I explicitly ask.\n"
             file))))

(defun my-codex-clean-commit-message (message)
  "Return MESSAGE with leading/trailing whitespace removed from each line."
  (string-join
   (mapcar #'string-trim
           (split-string (string-trim message) "\n"))
   "\n"))

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

(defun my-codex--send-git-prompt (prompt)
  "Send PROMPT to Codex from the project root after checking Git."
  (let ((default-directory (my-codex-project-root)))
    (my-codex--ensure-git-repository)
    (my-codex-send-prompt prompt)))

(defun my-codex-send-git-diff ()
  "Ask Codex to review the current Git diff."
  (interactive)
  (my-codex--send-git-prompt
   "Please review the current Git diff using `git diff -- .`. Focus on correctness, regressions, edge cases, naming, and maintainability. Do not edit files unless I explicitly ask.\n"))

(defun my-codex-send-git-staged-diff ()
  "Ask Codex to review the staged Git diff."
  (interactive)
  (my-codex--send-git-prompt
   "Please review the staged Git diff using `git diff --cached -- .`. Focus on correctness, regressions, edge cases, and commit readiness. Do not edit files unless I explicitly ask.\n"))

(defun my-codex-commit-message-from-diff ()
  "Ask Codex to draft a commit message from the staged Git diff."
  (interactive)
  (my-codex--send-git-prompt
   "Please inspect the staged Git diff using `git diff --cached -- .` and write a concise but comprehensive conventional commit message.

Put only the final commit message between these exact markers:

BEGIN_COMMIT_MESSAGE
<commit message here>
END_COMMIT_MESSAGE

Use an imperative subject and a short explanatory body when useful. Do not edit files.\n"))

(defun my-codex-latest-commit-message-after (buffer start-point)
  "Return the commit message in BUFFER appearing after START-POINT, or nil."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (save-restriction
        (widen)
        (save-excursion
          (goto-char (point-max))
          (let ((bound (when (and start-point
                                  (integer-or-marker-p start-point)
                                  (<= (point-min) start-point)
                                  (< start-point (point)))
                         start-point)))
            ;; Relaxed regex to bypass terminal formatting quirks.
            (when (re-search-backward "BEGIN_COMMIT_MESSAGE" bound t)
              (let ((beg (match-end 0)))
                (when (re-search-forward "END_COMMIT_MESSAGE" nil t)
                  (let ((msg (string-trim
                              (buffer-substring-no-properties
                               beg
                               (match-beginning 0)))))
                    (unless (member msg '("" "..." "<commit message here>"))
                      msg)))))))))))

(defun my-codex-latest-commit-message ()
  "Return the latest marked commit message from the current project's Codex buffer, or nil."
  (when-let ((buffer (get-buffer (my-codex-current-buffer-name))))
    (when (get-buffer-process buffer)
      (my-codex-latest-commit-message-after buffer nil))))

(defun my-codex-git-commit-with-message (message root)
  "Run `git commit --edit -F FILE' using Git's configured editor."
  (let ((file (make-temp-file "my-codex-commit-" nil ".txt"))
        (output-buffer (get-buffer-create "*Codex git commit*")))
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
                            "--edit"
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
                     (message "Git commit failed with status %s" status))))))))
      (set-process-query-on-exit-flag process nil)
      (with-current-buffer output-buffer
        (setq default-directory root)))))

(defun my-codex--wait-for-commit-message (buffer start-point root &optional attempts)
  "Poll BUFFER after START-POINT for a finished commit message.
ROOT is the Git repository root used for the eventual commit.
ATTEMPTS tracks the number of polling cycles to prevent infinite loops."
  (let ((attempts (or attempts 0))
        (max-attempts 120))
    (if (> attempts max-attempts)
        (progn
          (when (markerp start-point)
            (set-marker start-point nil))
          (message "Timed out waiting for Codex commit message."))
      (if-let ((msg (my-codex-latest-commit-message-after buffer start-point)))
          (progn
            (when (markerp start-point)
              (set-marker start-point nil))
            (my-codex-git-commit-with-message msg root)
            (message "Codex commit message is ready; opened Git editor."))
        (run-with-timer
         0.5 nil
         #'my-codex--wait-for-commit-message
         buffer start-point root (1+ attempts))))))

(defun my-codex-git-commit-with-latest-message ()
  "Commit with the latest Codex message, or ask Codex for one and wait."
  (interactive)
  (let ((root (my-codex-project-root)))
    (let ((default-directory root))
      (my-codex--ensure-git-repository))
    (if-let ((message (my-codex-latest-commit-message)))
        (progn
          (my-codex-git-commit-with-message message root)
          (message "Opened Git editor with latest Codex commit message."))
      (let* ((buffer (my-codex-buffer))
             (start-point (with-current-buffer buffer
                            (copy-marker (point-max)))))
        (my-codex-commit-message-from-diff)
        (my-codex--wait-for-commit-message buffer start-point root)
        (message "Asked Codex to draft a commit message; waiting for it.")))))

(defun my-codex-explain-region-as-error ()
  "Ask Codex to explain the selected compiler or test error."
  (interactive)
  (unless (use-region-p)
    (user-error "No active region"))
  (my-codex-send-prompt
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

(defun my-codex-code-window ()
  "Return the most likely coding window associated with Codex."
  (let ((codex-window (get-buffer-window (my-codex-current-buffer-name) t)))
    (unless codex-window
      (user-error "No visible Codex window"))
    (let ((code-window (next-window codex-window nil t)))
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
  (let ((codex-window (get-buffer-window (my-codex-current-buffer-name) t)))
    (cond
     ((not codex-window) (user-error "No visible Codex window"))
     ((eq (selected-window) codex-window) (my-codex-back-to-code))
     (t (select-window codex-window)))))

(defun my-codex-selected-text ()
  "Return actively selected text from the visible Codex window."
  (let ((codex-window (get-buffer-window (my-codex-current-buffer-name) t)))
    (unless codex-window
      (user-error "No visible Codex window"))
    (with-selected-window codex-window
      (unless (use-region-p)
        (user-error "No active selection in the Codex buffer"))
      (prog1
          (filter-buffer-substring
           (region-beginning)
           (region-end))
        (deactivate-mark)))))

(defun my-codex-insert-selection-into-code ()
  "Insert selected Codex text into the coding window."
  (interactive)
  (let ((text (my-codex-selected-text))
        (code-window (my-codex-code-window)))
    (select-window code-window)
    (insert text)))

(defun my-codex-ask (prompt)
  "Prompt the user in the minibuffer and send the query straight to Codex."
  (interactive "sAsk Codex: ")
  (when (string-blank-p prompt)
    (user-error "Prompt cannot be empty"))
  (my-codex-send-prompt prompt))

(defun my-codex-help ()
  "Show Codex key bindings."
  (interactive)
  (message
   "Codex: F7=build, F8 o=show/start read-only, w=show/start workspace, r=resume, q=restore layout, a=ask, s/right=send region, left=insert selected Codex text, f=file, g=diff, G=staged diff, m=draft commit message, c=commit with Codex message, e=explain error, i=instructions, TAB=toggle focus, ?=help"))

;; Prefix keymap for Codex commands.
(defvar-keymap my-codex-map
  :doc "Prefix keymap for Codex commands."
  "o"       #'my-codex-read-only
  "w"       #'my-codex-workspace
  "r"       #'my-codex-resume
  "q"       #'my-codex-restore-layout
  "a"       #'my-codex-ask
  "s"       #'my-codex-send-region
  "<right>" #'my-codex-send-region
  "<left>"  #'my-codex-insert-selection-into-code
  "f"       #'my-codex-send-current-file
  "g"       #'my-codex-send-git-diff
  "G"       #'my-codex-send-git-staged-diff
  "m"       #'my-codex-commit-message-from-diff
  "c"       #'my-codex-git-commit-with-latest-message
  "e"       #'my-codex-explain-region-as-error
  "i"       #'my-codex-open-project-instructions
  "TAB"     #'my-codex-toggle-focus
  "<tab>"   #'my-codex-toggle-focus
  "?"       #'my-codex-help)

(with-eval-after-load 'vterm
  (when (boundp 'vterm-mode-map)
    (keymap-set vterm-mode-map "S-<insert>" #'vterm-yank)
    (keymap-set vterm-mode-map "C-c C-t"    #'vterm-copy-mode)
    (keymap-set vterm-mode-map "<prior>"    #'scroll-down-command)
    (keymap-set vterm-mode-map "<next>"     #'scroll-up-command)
    (keymap-set vterm-mode-map "<f8>"       my-codex-map)))

(defun my-codex-project-build ()
  "Run the project build command with `compile'."
  (interactive)
  (let ((default-directory (my-codex-project-root)))
    (compile my-codex-project-build-command)))

(defvar-keymap my-codex-global-mode-map
  :doc "Keymap for `my-codex-global-mode'."
  "<f7>" #'my-codex-project-build
  "<f8>" my-codex-map)

(easy-menu-define my-codex-menu my-codex-global-mode-map
  "Menu for Codex commands."
  '("Codex"
    ["Show/start read-only" my-codex-read-only
     :help "Show Codex, starting it in read-only mode if needed"]
    ["Show/start workspace-write" my-codex-workspace
     :help "Show Codex, starting it with workspace write access if needed"]
    ["Resume session" my-codex-resume
     :help "Resume a previous Codex session"]
    ["Restore window layout" my-codex-restore-layout
     :help "Restore the layout configuration to how it was before opening Codex"]
    ["Ask Codex..." my-codex-ask
     :help "Prompt for a question and send it to Codex"]
    "---"
    ["Send selected region" my-codex-send-region
     :active (use-region-p)
     :help "Send the selected region to Codex"]
    ["Explain selected error" my-codex-explain-region-as-error
     :active (use-region-p)
     :help "Ask Codex to explain the selected compiler/test error"]
    ["Inspect current file" my-codex-send-current-file
     :active buffer-file-name
     :help "Ask Codex to inspect the current file directly"]
    "---"
    ["Review Git diff" my-codex-send-git-diff
     :help "Ask Codex to review the current Git diff"]
    ["Review staged Git diff" my-codex-send-git-staged-diff
     :help "Ask Codex to review the staged Git diff"]
    ["Draft commit message" my-codex-commit-message-from-diff
     :help "Ask Codex to draft a commit message from the staged Git diff"]
    ["Commit with Codex message" my-codex-git-commit-with-latest-message
     :help "Use the latest Codex commit message, or ask Codex for one, then open Git's editor"]
    "---"
    ["Open project instructions" my-codex-open-project-instructions
     :help "Open AGENTS.md, CODEX.md, or .codex/instructions.md"]
    ["Show key bindings" my-codex-help
     :help "Show Codex key bindings"]
    "---"
    ["Compile project" my-codex-project-build
     :help "Run the project build command"]))

;;;###autoload
(define-minor-mode my-codex-global-mode
  "Global minor mode for seamless Codex integration."
  :global t
  :group 'my-codex
  :keymap my-codex-global-mode-map
  (when (and my-codex-global-mode
             my-codex-enable-global-auto-revert)
    (global-auto-revert-mode 1)))

(provide 'my-codex)

;;; my-codex.el ends here
