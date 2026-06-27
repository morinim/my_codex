;;; my-codex-git.el --- Git helpers for my-codex -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Manlio Morini

;; This file is not part of GNU Emacs.

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at https://mozilla.org/MPL/2.0/.

;;; Code:

(require 'ediff)
(require 'subr-x)
(require 'my-codex-core)
(require 'my-codex-prompts)

;; Commit message requests keep their own state so they can validate the
;; staged diff and reopen the latest generated message.
(defvar-local my-codex--commit-message-request-marker nil
  "Marker for the start of the latest agent commit message request.")

(defvar-local my-codex--commit-message-request-output-markers nil
  "Begin and end markers for the latest agent commit message request.")

(defvar-local my-codex--commit-message-request-signature nil
  "Staged diff signature used for the latest agent commit message request.")

(defvar-local my-codex--commit-buffer-staged-signature nil
  "Staged diff signature for the current editable commit message.")

(defvar-local my-codex--commit-buffer-codex-buffer nil
  "Agent session buffer associated with the current editable commit message.")

(defvar-local my-codex--commit-message-wait-timer nil
  "Active timer waiting for an agent commit message.")

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

(defcustom my-codex-commit-message-prompt-template
  "Inspect the staged Git diff using `git diff -U1 --cached -- .` and write a concise conventional commit message.

Use an imperative subject and a short explanatory body when useful. Limit each line to %d columns. Do not edit files.\n"
  "Prompt template used by `my-codex-commit-message-from-diff'.
The literal substring `%d' is replaced with
`my-codex-commit-message-fill-column'.  Marked-output instructions
are appended for each request."
  :type 'string
  :group 'my-codex)

(defcustom my-codex-commit-message-poll-interval 0.5
  "Seconds between checks for a generated agent commit message."
  :type 'number
  :group 'my-codex)

(defcustom my-codex-commit-message-poll-attempts 120
  "Maximum number of checks for a generated agent commit message."
  :type 'natnum
  :group 'my-codex)

(defcustom my-codex-session-summary-prompt
  "Summarise our conversation so far into useful project notes.

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

(declare-function my-codex--preview-and-send-prompt "my-codex-prompts" (prompt))
(declare-function my-codex--request-marked-output "my-codex-prompts" (&rest args))
(declare-function my-codex-send-prompt "my-codex-prompts" (prompt &optional target-buffer))
(declare-function my-codex--active-agent-label "my-codex-core" (&optional root))
(declare-function my-codex--process-output-lines "my-codex-core" (program &rest args))
(declare-function my-codex--safe-root-name "my-codex-core" (root))
(declare-function my-codex--session-export-mode "my-codex-core" ())
(declare-function my-codex--session-summary-buffer-name "my-codex-core" (root))
(declare-function my-codex-active-session-buffer "my-codex-core" (&optional require-live))
(declare-function my-codex-current-buffer-name "my-codex-core" ())
(declare-function my-codex-project-root "my-codex-core" ())

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
               (ignore-errors
                 (mapcar (lambda (file)
                           (file-relative-name file root))
                         (project-files project)))))))
      (sort (or files nil) #'string<))))

;;;###autoload
(defun my-codex-send-project-overview ()
  "Ask the agent to inspect the current project for orientation."
  (interactive)
  (my-codex--preview-and-send-prompt
   "Inspect the repository structure, Git status, and applicable instruction files.
Build a concise working map for future requests in this thread.
Do not modify files."))

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
  "Send PROMPT to the agent from the project root after checking Git."
  (let ((default-directory (my-codex-project-root)))
    (my-codex--ensure-git-repository)
    (my-codex--preview-and-send-prompt prompt)))

(defun my-codex--commit-message-prompt (&optional begin-marker end-marker)
  "Return the prompt for drafting a commit message from staged changes."
  (let ((prompt
         (replace-regexp-in-string
          "%d" (number-to-string my-codex-commit-message-fill-column)
          my-codex-commit-message-prompt-template t t)))
    (if (and begin-marker end-marker)
        (format "%s\n\n%s"
                prompt
                (my-codex--marked-output-instructions
                 begin-marker end-marker "<commit message here>"))
      prompt)))

(defun my-codex--git-diff-buffer-name (root staged)
  "Return the diff buffer name for ROOT.
When STAGED is non-nil, return the staged diff buffer name."
  (format "*Codex diff:%s:%s*"
          (my-codex--safe-root-name root)
          (if staged "staged" "worktree")))

(defun my-codex--show-git-diff (staged)
  "Show a persistent `diff-mode' buffer for the current Git diff.
When STAGED is non-nil, show the staged diff."
  (let* ((root (my-codex-project-root))
         (default-directory root))
    (my-codex--ensure-git-repository)
    (setq root (my-codex--git-toplevel))
    (let* ((default-directory root)
           (buffer (get-buffer-create
                    (my-codex--git-diff-buffer-name root staged)))
           (args (if staged
                     '("diff" "--cached" "--" ".")
                   '("diff" "--" "."))))
      (with-current-buffer buffer
        (let ((inhibit-read-only t)
              (previous-point (point)))
          (setq-local default-directory root)
          (erase-buffer)
          (unless (eq 0 (apply #'process-file "git" nil t nil args))
            (user-error "Unable to inspect Git diff"))
          (goto-char (min previous-point (point-max)))
          (diff-mode)
          (setq buffer-read-only t)))
      (display-buffer buffer))))

;;;###autoload
(defun my-codex-send-git-diff ()
  "Ask the agent to review the current Git diff."
  (interactive)
  (my-codex--send-git-prompt my-codex-git-diff-review-prompt))

;;;###autoload
(defun my-codex-send-git-staged-diff ()
  "Ask the agent to review the staged Git diff."
  (interactive)
  (my-codex--send-git-prompt my-codex-git-staged-diff-review-prompt))

;;;###autoload
(defun my-codex-show-git-diff ()
  "Show the current Git diff in a persistent `diff-mode' buffer."
  (interactive)
  (my-codex--show-git-diff nil))

;;;###autoload
(defun my-codex-show-git-staged-diff ()
  "Show the staged Git diff in a persistent `diff-mode' buffer."
  (interactive)
  (my-codex--show-git-diff t))

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

(defun my-codex--selected-agent-vterm-window-p ()
  "Return non-nil when the selected window is the active agent vterm."
  (let ((buffer (window-buffer (selected-window))))
    (and (eq buffer (ignore-errors
                      (my-codex-active-session-buffer)))
         (with-current-buffer buffer
           (derived-mode-p 'vterm-mode)))))

(defun my-codex--left-window-file-name ()
  "Return the file visited by the window to the left, or nil."
  (when-let* ((window (window-in-direction 'left (selected-window)))
              (buffer (window-buffer window)))
    (buffer-file-name buffer)))

(defun my-codex--current-or-left-file-name ()
  "Return the current file, using the left window from the agent vterm."
  (cond
   (buffer-file-name)
   ((my-codex--selected-agent-vterm-window-p)
    (or (my-codex--left-window-file-name)
        (user-error "No file-visiting buffer to the left of agent")))
   (t
    (user-error "Current buffer is not visiting a file"))))

(defun my-codex--current-or-left-file-available-p ()
  "Return non-nil when a file target is available for current-file commands."
  (or buffer-file-name
      (and (my-codex--selected-agent-vterm-window-p)
           (my-codex--left-window-file-name))))

;;;###autoload
(defun my-codex-ediff-current-file-against-head ()
  "Review the current file's uncommitted changes against HEAD using Ediff.
When invoked from the agent vterm, use the file in the window to its left."
  (interactive)
  (let ((file (my-codex--current-or-left-file-name))
        (root (my-codex-project-root)))
    (let ((default-directory root))
      (my-codex--ensure-git-repository))
    (my-codex--ediff-file-against-head file root)))

;;;###autoload
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

;;;###autoload
(defun my-codex-commit-message-from-diff ()
  "Ask the agent to draft a commit message from the staged Git diff."
  (interactive)
  (let* ((buffer (my-codex-active-session-buffer t))
         (root (my-codex-project-root))
         (default-directory root)
         (markers (my-codex--unique-output-markers "COMMIT_MESSAGE"))
         (begin-marker (car markers))
         (end-marker (cdr markers))
         (signature nil))
    (my-codex--ensure-git-repository)
    (unless (my-codex--staged-changes-p)
      (user-error "No staged Git changes to draft a commit message from"))
    (setq signature (my-codex--staged-diff-signature))
    (with-current-buffer buffer
      (setq my-codex--commit-message-request-signature signature)
      (setq my-codex--commit-message-request-output-markers markers)
      (setq my-codex--commit-message-request-marker
            (copy-marker (point-max))))
    (my-codex-send-prompt
     (my-codex--commit-message-prompt begin-marker end-marker)
     buffer)
    (message
     "Asked %s to draft a commit message; use F8 c or M-x %s to edit and commit it."
     (my-codex--active-agent-label root)
     "my-codex-git-commit-with-latest-message")
    signature))

(defun my-codex-latest-commit-message-after
    (buffer start-point &optional output-markers)
  "Return the commit message in BUFFER appearing after START-POINT, or nil."
  (let ((markers (or output-markers
                     '("BEGIN_COMMIT_MESSAGE" . "END_COMMIT_MESSAGE"))))
    (my-codex--latest-marked-output-after
     buffer start-point
     (car markers)
     (cdr markers)
     '("..." "<commit message here>"))))

(defun my-codex-latest-commit-message ()
  "Return latest requested commit message from current agent buffer.
Return nil when no matching message is available."
  (when-let ((buffer (or (ignore-errors
                           (my-codex-active-session-buffer))
                         (get-buffer (my-codex-current-buffer-name)))))
    (with-current-buffer buffer
      (when-let* ((marker my-codex--commit-message-request-marker)
                  ((markerp marker))
                  ((eq (marker-buffer marker) buffer)))
        (my-codex-latest-commit-message-after
         buffer marker my-codex--commit-message-request-output-markers)))))

(defun my-codex--commit-message-buffer-name (root)
  "Return the commit message buffer name for ROOT."
  (format "*%s commit message:%s*"
          (my-codex--active-agent-label root)
          (my-codex--safe-root-name root)))

(defun my-codex-edit-session-summary (summary root)
  "Open an editable Markdown buffer with agent session SUMMARY from ROOT."
  (let ((buffer (get-buffer-create (my-codex--session-summary-buffer-name root))))
    (pop-to-buffer buffer)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (string-trim summary))
      (goto-char (point-min)))
    (setq default-directory root)
    (my-codex--session-export-mode)
    (setq-local header-line-format "Edit agent session summary Markdown.")
    (message "%s session summary is ready for editing."
             (my-codex--active-agent-label root))))

(defun my-codex--finish-git-commit ()
  "Commit staged changes using the current buffer as the commit message."
  (interactive)
  (let* ((root default-directory)
         (raw-message (buffer-substring-no-properties (point-min) (point-max)))
         (message (my-codex-clean-commit-message
                   (my-codex--strip-commit-template-section raw-message))))
    (when (string-empty-p message)
      (user-error "Commit message is empty"))
    (when my-codex--commit-buffer-staged-signature
      (let ((default-directory root))
        (unless (equal my-codex--commit-buffer-staged-signature
                       (my-codex--staged-diff-signature))
          (user-error
           "Staged changes changed after the commit message was drafted"))))
    (my-codex-git-commit-with-message
     message root (current-buffer) my-codex--commit-buffer-codex-buffer)))

(defun my-codex--cancel-git-commit ()
  "Cancel the current agent commit message buffer."
  (interactive)
  (quit-window 'kill)
  (message "Git commit canceled."))

(defun my-codex--quit-commit-buffer (buffer)
  "Kill BUFFER and quit any windows that were opened for it."
  (when (buffer-live-p buffer)
    (quit-windows-on buffer t)))

(defun my-codex-edit-git-commit-with-message
    (message root &optional staged-signature codex-buffer)
  "Open an editable Git commit buffer with MESSAGE from ROOT.
STAGED-SIGNATURE is the staged diff signature MESSAGE was drafted for.
CODEX-BUFFER is the agent session buffer that requested MESSAGE."
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
    (setq-local my-codex--commit-buffer-staged-signature
                (or staged-signature
                    (let ((default-directory root))
                      (my-codex--staged-diff-signature))))
    (setq-local my-codex--commit-buffer-codex-buffer codex-buffer)
    (setq-local header-line-format
                "Edit commit message. C-c C-c commits staged changes; C-c C-k cancels.")
    (let ((map (define-keymap :parent (current-local-map)
                 "C-c C-c" #'my-codex--finish-git-commit
                 "C-c C-k" #'my-codex--cancel-git-commit)))
      (use-local-map map))
    (message "Edit the commit message, then press C-c C-c to commit.")))

(defun my-codex-git-commit-with-message
    (message root &optional commit-buffer codex-buffer)
  "Run `git commit -F FILE' with MESSAGE from ROOT.
Kill COMMIT-BUFFER after a successful commit when it is non-nil.
Clear request state in CODEX-BUFFER after a successful commit when it is live."
  (let ((file (make-temp-file "my-codex-commit-" nil ".txt"))
        (output-buffer (get-buffer-create "*Codex git commit*"))
        (codex-buffer (or codex-buffer
                          (let ((default-directory root))
                            (ignore-errors
                              (my-codex-active-session-buffer))))))
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
                         (my-codex--delete-temp-file file)
                         (if (zerop status)
                             (progn
                               (when (buffer-live-p commit-buffer)
                                 (my-codex--quit-commit-buffer commit-buffer))
                               (when (buffer-live-p buffer)
                                 (kill-buffer buffer))
                               (when (buffer-live-p codex-buffer)
                                 (with-current-buffer codex-buffer
                                   (setq my-codex--commit-message-request-output-markers nil)
                                   (setq my-codex--commit-message-request-signature nil)
                                   (my-codex--clear-marker my-codex--commit-message-request-marker)))
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
       (my-codex--delete-temp-file file)
       (signal (car err) (cdr err))))))

(defun my-codex--delete-temp-file (file)
  "Delete temporary FILE, reporting cleanup failures as messages."
  (when file
    (with-demoted-errors "Failed to delete temporary file: %S"
      (delete-file file))))

(defun my-codex--wait-for-commit-message
    (buffer start-point root &optional staged-signature attempts)
  "Poll BUFFER after START-POINT for a finished commit message.
ROOT is the Git repository root used for the eventual commit.
STAGED-SIGNATURE is the staged diff signature the message was requested for.
ATTEMPTS tracks the number of polling cycles to prevent infinite loops."
  (unless attempts
    (my-codex--clear-buffer-local-timer
     buffer 'my-codex--commit-message-wait-timer))
  (let ((markers
         (with-current-buffer buffer
           (or my-codex--commit-message-request-output-markers
               '("BEGIN_COMMIT_MESSAGE" . "END_COMMIT_MESSAGE")))))
    (my-codex--wait-for-marked-output
     buffer start-point
     (car markers)
     (cdr markers)
     (lambda (msg)
       (my-codex-edit-git-commit-with-message msg root staged-signature buffer))
     "Timed out waiting for agent commit message."
     "Agent commit message is ready for editing."
     my-codex-commit-message-poll-interval
     my-codex-commit-message-poll-attempts
     '("..." "<commit message here>")
     attempts
     'my-codex--commit-message-wait-timer)))

(defun my-codex--request-commit-message-and-wait
    (buffer root staged-signature)
  "Ask for a commit message in BUFFER and open an editor when ready."
  (my-codex--request-marked-output
   :name "COMMIT_MESSAGE"
   :buffer buffer
   :prompt (my-codex--commit-message-prompt)
   :placeholder "<commit message here>"
   :parser #'my-codex-clean-commit-message
   :callback (lambda (message)
               (my-codex-edit-git-commit-with-message
                message root staged-signature buffer))
   :timeout-message "Timed out waiting for agent commit message."
   :ready-message "Agent commit message is ready for editing."
   :poll-interval my-codex-commit-message-poll-interval
   :poll-attempts my-codex-commit-message-poll-attempts
   :timer-var 'my-codex--commit-message-wait-timer
   :start-callback
   (lambda (start-point begin-marker end-marker)
     (with-current-buffer buffer
       (setq my-codex--commit-message-request-signature staged-signature)
       (setq my-codex--commit-message-request-output-markers
             (cons begin-marker end-marker))
       (setq my-codex--commit-message-request-marker start-point)))))

;;;###autoload
(defun my-codex-git-commit-with-latest-message ()
  "Edit a commit with the latest agent message, or ask the agent for one."
  (interactive)
  (let ((root (my-codex-project-root))
        current-signature)
    (let ((default-directory root))
      (my-codex--ensure-git-repository)
      (unless (my-codex--staged-changes-p)
        (user-error "No staged Git changes to commit"))
      (setq current-signature (my-codex--staged-diff-signature)))
    (let* ((buffer (my-codex-active-session-buffer t))
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
                (my-codex-edit-git-commit-with-message
                 message root request-signature buffer)
                (message "Editing latest agent commit message."))
            (my-codex--wait-for-commit-message
             buffer marker root request-signature)
            (message "Waiting for agent commit message."))
        (progn
          (my-codex--request-commit-message-and-wait
           buffer root current-signature)
          (message "Asked %s to draft a commit message; waiting to open editor."
                   (my-codex--active-agent-label root)))))))

(provide 'my-codex-git)

;;; my-codex-git.el ends here
