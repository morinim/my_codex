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

(defcustom my-codex-commit-message-fill-column 76
  "Maximum line width for generated commit messages."
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

(defvar my-codex--saved-window-configuration nil
  "Window layout configuration captured before opening Codex.")

(defvar my-codex--auto-revert-enabled-by-mode nil
  "Non-nil when `my-codex-global-mode' enabled `global-auto-revert-mode'.")

(defvar my-codex--commit-message-request-marker nil
  "Marker for the start of the latest Codex commit message request.")

(defvar my-codex--commit-message-request-signature nil
  "Staged diff signature used for the latest Codex commit message request.")

(defun my-codex--shell-command-and-exit (command)
  "Return shell text that runs COMMAND, then exits with its status."
  (format "(%s); exit $?" command))

(defun my-codex--safe-root-name (root)
  "Return a buffer-name-safe representation of ROOT."
  (replace-regexp-in-string
   "[^[:alnum:]._-]+" "!"
   (directory-file-name (file-truename root))))

(defun my-codex-project-root ()
  "Return the current project root, or `default-directory' if not in a project."
  (file-name-as-directory
   (if-let ((project (project-current)))
       (project-root project)
     default-directory)))

(defun my-codex-current-buffer-name ()
  "Return a project-specific buffer name for the Codex session."
  (if-let* ((project (project-current))
            (root (project-root project)))
      (format "*codex:%s*" (my-codex--safe-root-name root))
    my-codex-buffer-name))

(defun my-codex-modified-project-buffers ()
  "Return modified file-visiting buffers belonging to the current project."
  (if-let ((project (project-current)))
      (seq-filter (lambda (buf)
                    (and (buffer-file-name buf)
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

    (let ((layout-before-delete (current-window-configuration)))
      (condition-case err
          (progn
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
                      (vterm-send-string (my-codex--shell-command-and-exit codex-command))
                      (vterm-send-return)))))
              (unless focus-term
                (select-window edit-window))))
        (error
         (set-window-configuration layout-before-delete)
         (signal (car err) (cdr err)))))))

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

(defun my-codex-send-region (beg end)
  "Send the region between BEG and END to Codex with exact file context."
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
          (push (my-codex--fill-commit-message-text (string-trim-right line))
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
  (let ((message (string-trim message)))
    (if (string-empty-p message)
        ""
      (let ((lines (split-string message "\n")))
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
    (my-codex-send-prompt prompt)))

(defun my-codex--git-diff-review-prompt ()
  "Return the prompt for reviewing the current Git diff."
  "Please review the current Git diff using `git diff -- .`. Focus on correctness, regressions, edge cases, naming, and maintainability. Do not edit files unless I explicitly ask.\n")

(defun my-codex--git-staged-diff-review-prompt ()
  "Return the prompt for reviewing the staged Git diff."
  "Please review the staged Git diff using `git diff --cached -- .`. Focus on correctness, regressions, edge cases, and commit readiness. Do not edit files unless I explicitly ask.\n")

(defun my-codex--commit-message-prompt ()
  "Return the prompt for drafting a commit message from staged changes."
  (format "Please inspect the staged Git diff using `git diff --cached -- .` and write a concise but comprehensive conventional commit message.

Put only the final commit message between these exact markers:

BEGIN_COMMIT_MESSAGE
<commit message here>
END_COMMIT_MESSAGE

Use an imperative subject and a short explanatory body when useful. Limit each line to %d columns. Do not edit files.\n"
          my-codex-commit-message-fill-column))

(defun my-codex-send-git-diff ()
  "Ask Codex to review the current Git diff."
  (interactive)
  (my-codex--send-git-prompt (my-codex--git-diff-review-prompt)))

(defun my-codex-send-git-staged-diff ()
  "Ask Codex to review the staged Git diff."
  (interactive)
  (my-codex--send-git-prompt (my-codex--git-staged-diff-review-prompt)))

(defun my-codex-commit-message-from-diff ()
  "Ask Codex to draft a commit message from the staged Git diff."
  (interactive)
  (let* ((buffer (my-codex-buffer))
         (root (my-codex-project-root))
         (default-directory root))
    (my-codex--ensure-git-repository)
    (setq my-codex--commit-message-request-signature
          (my-codex--staged-diff-signature))
    (setq my-codex--commit-message-request-marker
          (with-current-buffer buffer
            (copy-marker (point-max)))))
  (my-codex--send-git-prompt (my-codex--commit-message-prompt)))

(defun my-codex-latest-commit-message-after (buffer start-point)
  "Return the commit message in BUFFER appearing after START-POINT, or nil."
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
              ;; Relaxed regex to bypass terminal formatting quirks.
              (when (re-search-backward "BEGIN_COMMIT_MESSAGE" bound t)
                (let ((beg (match-end 0)))
                  (when (re-search-forward "END_COMMIT_MESSAGE" nil t)
                    (let ((msg (string-trim
                                (buffer-substring-no-properties
                                 beg
                                 (match-beginning 0)))))
                      (unless (member msg '("" "..." "<commit message here>"))
                        msg))))))))))))

(defun my-codex-latest-commit-message ()
  "Return the latest requested commit message from the current Codex buffer, or nil."
  (when-let* ((buffer (get-buffer (my-codex-current-buffer-name)))
              (marker my-codex--commit-message-request-marker)
              ((markerp marker))
              ((eq (marker-buffer marker) buffer)))
    (my-codex-latest-commit-message-after buffer marker)))

(defun my-codex--commit-message-buffer-name (root)
  "Return the commit message buffer name for ROOT."
  (format "*Codex commit message:%s*" (my-codex--safe-root-name root)))

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
  (kill-buffer (current-buffer))
  (message "Git commit canceled."))

(defun my-codex-edit-git-commit-with-message (message root)
  "Open an editable Git commit buffer with MESSAGE from ROOT."
  (let ((buffer (get-buffer-create (my-codex--commit-message-buffer-name root))))
    (pop-to-buffer buffer)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (my-codex-clean-commit-message message))
      (when-let ((template (my-codex--git-commit-template root)))
        (insert "\n\n")
        (insert (my-codex--commit-template-section
                 template
                 (my-codex--git-comment-char root))))
      (goto-char (point-min)))
    (setq default-directory root)
    (text-mode)
    (setq-local header-line-format
                "Edit commit message. C-c C-c commits staged changes; C-c C-k cancels.")
    (let ((map (make-sparse-keymap)))
      (set-keymap-parent map (current-local-map))
      (keymap-set map "C-c C-c" #'my-codex--finish-git-commit)
      (keymap-set map "C-c C-k" #'my-codex--cancel-git-commit)
      (use-local-map map))
    (message "Edit the commit message, then press C-c C-c to commit.")))

(defun my-codex-git-commit-with-message (message root &optional commit-buffer)
  "Run `git commit -F FILE' with MESSAGE from ROOT.
Kill COMMIT-BUFFER after a successful commit when it is non-nil."
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
                           (kill-buffer commit-buffer))
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

(defun my-codex--clear-marker (marker)
  "Detach MARKER from its buffer when MARKER is a marker."
  (when (markerp marker)
    (set-marker marker nil)))

(defun my-codex--wait-for-commit-message (buffer start-point root &optional attempts)
  "Poll BUFFER after START-POINT for a finished commit message.
ROOT is the Git repository root used for the eventual commit.
ATTEMPTS tracks the number of polling cycles to prevent infinite loops."
  (let ((attempts (or attempts 0))
        (max-attempts 120)
        (msg (my-codex-latest-commit-message-after buffer start-point)))
    (cond
     ((> attempts max-attempts)
      (my-codex--clear-marker start-point)
      (message "Timed out waiting for Codex commit message."))
     (msg
      (my-codex--clear-marker start-point)
      (my-codex-edit-git-commit-with-message msg root)
      (message "Codex commit message is ready for editing."))
     (t
      (run-with-timer
       0.5 nil
       #'my-codex--wait-for-commit-message
       buffer start-point root (1+ attempts))))))

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
           (marker my-codex--commit-message-request-marker)
           (current-request-p
            (and (markerp marker)
                 (eq (marker-buffer marker) buffer)
                 (equal my-codex--commit-message-request-signature
                        current-signature))))
      (if current-request-p
          (if-let ((message (my-codex-latest-commit-message-after buffer marker)))
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

(defun my-codex-visible-window ()
  "Return the visible Codex window, or raise an error."
  (or (get-buffer-window (my-codex-current-buffer-name) t)
      (user-error "No visible Codex window")))

(defun my-codex-code-window ()
  "Return the most likely coding window associated with Codex."
  (let ((codex-window (my-codex-visible-window)))
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
  (let ((codex-window (my-codex-visible-window)))
    (cond
     ((eq (selected-window) codex-window) (my-codex-back-to-code))
     (t (select-window codex-window)))))

(defun my-codex-selected-text ()
  "Return actively selected text from the visible Codex window."
  (let ((codex-window (my-codex-visible-window)))
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
  "Read PROMPT in the minibuffer and send it straight to Codex."
  (interactive "sAsk Codex: ")
  (when (string-blank-p prompt)
    (user-error "Prompt cannot be empty"))
  (my-codex-send-prompt prompt))

(defun my-codex-help ()
  "Show Codex key bindings."
  (interactive)
  (message
   "Codex: F7=build, F8 o=show/start read-only, w=show/start workspace, r=resume, q=restore layout, a=ask, s/right=send region, left=insert selected Codex text, f=file, g=diff, G=staged diff, m=draft commit message, c=edit commit with Codex message, e=explain error, i=instructions, TAB=toggle focus, ?=help"))

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
    ["Edit commit with Codex message" my-codex-git-commit-with-latest-message
     :help "Use the latest Codex commit message, or ask Codex for one, then edit before committing"]
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
  (if my-codex-global-mode
      (when (and my-codex-enable-global-auto-revert
                 (not my-codex--auto-revert-enabled-by-mode)
                 (not (bound-and-true-p global-auto-revert-mode)))
        (setq my-codex--auto-revert-enabled-by-mode t)
        (global-auto-revert-mode 1))
    (when my-codex--auto-revert-enabled-by-mode
      (global-auto-revert-mode -1))
    (setq my-codex--auto-revert-enabled-by-mode nil)))

(provide 'my-codex)

;;; my-codex.el ends here
