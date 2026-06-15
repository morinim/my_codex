;;; my-codex-git.el --- Git helpers for my-codex -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Manlio Morini

;; This file is not part of GNU Emacs.

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at https://mozilla.org/MPL/2.0/.

;;; Code:

(require 'ediff)
(require 'subr-x)

(defvar my-codex--commit-buffer-staged-signature)
(defvar my-codex--commit-message-request-marker)
(defvar my-codex--commit-message-request-signature)
(defvar my-codex-commit-message-fill-column)
(defvar my-codex-commit-message-poll-attempts)
(defvar my-codex-commit-message-poll-interval)
(defvar my-codex-commit-message-prompt-template)
(defvar my-codex-git-diff-review-prompt)
(defvar my-codex-git-staged-diff-review-prompt)
(defvar my-codex-project-overview-max-files)
(defvar my-codex-project-overview-tree-max-entries)
(defvar my-codex-session-summary-poll-attempts)
(defvar my-codex-session-summary-poll-interval)

(declare-function my-codex--preview-and-send-prompt "my-codex-prompts" (prompt))
(declare-function my-codex--safe-root-name "my-codex" (root))
(declare-function my-codex--session-export-mode "my-codex" ())
(declare-function my-codex--session-summary-buffer-name "my-codex" (root))
(declare-function my-codex-buffer "my-codex" ())
(declare-function my-codex-current-buffer-name "my-codex" ())
(declare-function my-codex-modified-project-buffers "my-codex" ())
(declare-function my-codex-project-root "my-codex" ())

(defun my-codex--ensure-main-package ()
  "Load `my-codex' when this file was entered through an autoload."
  (unless (featurep 'my-codex)
    (require 'my-codex)))

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

(defun my-codex--project-files-yaml (files)
  "Return project FILES as YAML for a project overview prompt."
  (cond
   ((not files)
    "mode: empty\nentries: []")
   ((> (length files) my-codex-project-overview-max-files)
    (format "mode: compact_tree\ntotal: %d\nentries:\n%s"
            (length files)
            (my-codex--yaml-list (my-codex--project-tree-lines files) 2)))
   (t
    (format "mode: full\nentries:\n%s"
            (my-codex--yaml-list files 2)))))

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

;;;###autoload
(defun my-codex-send-project-overview ()
  "Send a compact summary of the current project structure to Codex."
  (interactive)
  (my-codex--ensure-main-package)
  (let* ((root (my-codex-project-root))
         (default-directory root)
         (files (my-codex--project-files root))
         (files-yaml (my-codex--project-files-yaml files)))
    (my-codex--preview-and-send-prompt
     (format "Here is the current state and structure of my project as YAML. Use this as orientation context for subsequent requests. Do not inspect files, generate code, or make changes solely because of this message.

project:
  root: %s
project_files:
%s
git_status:
%s
unsaved_modified_project_buffers:
%s
"
             (my-codex--yaml-string root)
             (my-codex--yaml-literal-block files-yaml 2)
             (my-codex--yaml-list
              (split-string (my-codex--git-status-text root) "\n" t)
              2)
             (my-codex--yaml-list
              (split-string (my-codex--unsaved-project-buffer-text root) "\n" t)
              2)))))

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

;;;###autoload
(defun my-codex-send-git-diff ()
  "Ask Codex to review the current Git diff."
  (interactive)
  (my-codex--ensure-main-package)
  (my-codex--send-git-prompt (my-codex--git-diff-review-prompt)))

;;;###autoload
(defun my-codex-send-git-staged-diff ()
  "Ask Codex to review the staged Git diff."
  (interactive)
  (my-codex--ensure-main-package)
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

;;;###autoload
(defun my-codex-ediff-current-file-against-head ()
  "Review the current file's uncommitted changes against HEAD using Ediff.
When invoked from the Codex vterm, use the file in the window to its left."
  (interactive)
  (my-codex--ensure-main-package)
  (let ((file (my-codex--current-or-left-file-name))
        (root (my-codex-project-root)))
    (let ((default-directory root))
      (my-codex--ensure-git-repository))
    (my-codex--ediff-file-against-head file root)))

;;;###autoload
(defun my-codex-ediff-changed-file-against-head ()
  "Choose a tracked changed file and review it against HEAD using Ediff."
  (interactive)
  (my-codex--ensure-main-package)
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
  "Ask Codex to draft a commit message from the staged Git diff."
  (interactive)
  (my-codex--ensure-main-package)
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
    (my-codex-send-prompt (my-codex--commit-message-prompt))
    (message
     "Asked Codex to draft a commit message; use F8 c or M-x %s to edit and commit it."
     "my-codex-git-commit-with-latest-message")
    signature))

(defun my-codex--terminal-marker-regexp (marker)
  "Return a regexp matching MARKER with terminal whitespace artefacts."
  (mapconcat
   (lambda (char)
     (regexp-quote (char-to-string char)))
   marker
   "[[:space:]\r\n]*"))

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
    (when my-codex--commit-buffer-staged-signature
      (let ((default-directory root))
        (unless (equal my-codex--commit-buffer-staged-signature
                       (my-codex--staged-diff-signature))
          (user-error
           "Staged changes changed after the commit message was drafted"))))
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

(defun my-codex-edit-git-commit-with-message
    (message root &optional staged-signature)
  "Open an editable Git commit buffer with MESSAGE from ROOT.
STAGED-SIGNATURE is the staged diff signature MESSAGE was drafted for."
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

(defun my-codex--wait-for-commit-message
    (buffer start-point root &optional staged-signature attempts)
  "Poll BUFFER after START-POINT for a finished commit message.
ROOT is the Git repository root used for the eventual commit.
STAGED-SIGNATURE is the staged diff signature the message was requested for.
ATTEMPTS tracks the number of polling cycles to prevent infinite loops."
  (unless attempts
    (my-codex--clear-buffer-local-timer
     buffer 'my-codex--commit-message-wait-timer))
  (my-codex--wait-for-marked-output
   buffer start-point
   "BEGIN_COMMIT_MESSAGE"
   "END_COMMIT_MESSAGE"
   (lambda (msg)
     (my-codex-edit-git-commit-with-message msg root staged-signature))
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

;;;###autoload
(defun my-codex-git-commit-with-latest-message ()
  "Edit a commit with the latest Codex message, or ask Codex for one and wait."
  (interactive)
  (my-codex--ensure-main-package)
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
                (my-codex-edit-git-commit-with-message
                 message root request-signature)
                (message "Editing latest Codex commit message."))
            (my-codex--wait-for-commit-message
             buffer marker root request-signature)
            (message "Waiting for Codex commit message."))
        (let* ((start-point (with-current-buffer buffer
                              (copy-marker (point-max))))
               (request-signature (my-codex-commit-message-from-diff)))
          (my-codex--wait-for-commit-message
           buffer start-point root request-signature)
          (message "Asked Codex to draft a commit message; waiting to open editor."))))))

(provide 'my-codex-git)

;;; my-codex-git.el ends here
