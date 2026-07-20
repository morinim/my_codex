;;; my-codex-github.el --- GitHub helpers for my-codex -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Manlio Morini

;; This file is not part of GNU Emacs.

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at https://mozilla.org/MPL/2.0/.

;;; Commentary:

;; GitHub helpers for creating issue drafts from Codex sessions.

;;; Code:

(require 'subr-x)
(require 'my-codex-core)
(require 'my-codex-prompts)

(defvar-local my-codex--github-issue-creation-in-progress nil
  "Non-nil while the current GitHub issue draft is being submitted.")

(defvar-local my-codex--github-issue-repository nil
  "GitHub repository selected for the current issue draft.")

(defcustom my-codex-github-issue-summary-prompt
  "Summarise our conversation so far as a GitHub issue draft.

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
  "Prompt used by `my-codex-summarise-session-to-github-issue'."
  :type 'string
  :group 'my-codex)

(defun my-codex--github-buffer-name (root purpose)
  "Return the GitHub buffer name for ROOT and PURPOSE."
  (let* ((agent (my-codex--active-agent root))
         (label (my-codex--agent-label agent))
         (description (pcase purpose
                        ('issue "GitHub issue")
                        ('issue-list "open issues")
                        ('issue-draft "GitHub issue draft")
                        (_ (error "Unknown GitHub buffer purpose: %S"
                                  purpose)))))
    (format "*%s %s:%s*" label description (my-codex--safe-root-name root))))

(defun my-codex--github-issue-list-sentinel (proc _event)
  "Handle completion of open issue list process PROC."
  (when-let ((result (my-codex--process-result proc)))
    (let ((status (car result))
          (buffer (cdr result))
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
(defun my-codex-list-open-issues ()
  "List open GitHub issues for the current repository in a buffer."
  (interactive)
  (unless (executable-find "gh")
    (user-error "GitHub CLI `gh' not found in exec-path"))
  (let* ((root (my-codex-project-root))
         (buffer
          (get-buffer-create (my-codex--github-buffer-name root 'issue-list))))
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
              :name "my-codex-open-issues"
              :buffer buffer
              :command (list "gh" "issue" "list"
                             "--state" "open"
                             "--limit" "100")
              :connection-type 'pipe
              :noquery t
              :sentinel #'my-codex--github-issue-list-sentinel))))
      (process-put process 'my-codex-content-start
                   (with-current-buffer buffer (point-max)))
      (message "Listing open issues with gh...")
      process)))

(defun my-codex--github-repository-name (root)
  "Return the GitHub repository name resolved by `gh' from ROOT."
  (unless (executable-find "gh")
    (user-error "GitHub CLI `gh' not found in exec-path"))
  (with-temp-buffer
    (let ((default-directory root))
      (unless (eq 0 (process-file "gh" nil t nil
                                  "repo" "view"
                                  "--json" "nameWithOwner"
                                  "--jq" ".nameWithOwner"))
        (user-error "Unable to determine GitHub repository with gh")))
    (let ((repository (string-trim (buffer-string))))
      (when (string-empty-p repository)
        (user-error "GitHub repository name is empty"))
      repository)))

(defun my-codex--parse-github-issue-draft (draft)
  "Return issue fields parsed from DRAFT as a plist."
  (let ((text (string-trim draft)))
    (unless (string-match
             (concat "\\`[ \t\n]*"
                     "\\(?:Repository:[ \t]*\\([^\n]+\\)\n+[ \t]*\\)?"
                     "Title:[ \t]*\\([^\n]+\\)\n+[ \t]*Body:[ \t]*\n*")
             text)
      (user-error "Could not parse GitHub issue draft"))
    (let ((repository (when-let (repository (match-string 1 text))
                        (string-trim repository)))
          (title (string-trim (match-string 2 text)))
          (body (string-trim (substring text (match-end 0)))))
      (when (string-empty-p title)
        (user-error "GitHub issue title is empty"))
      (when (string-empty-p body)
        (user-error "GitHub issue body is empty"))
      (list :repository repository :title title :body body))))

(defun my-codex--github-issue-draft-text (repository title body)
  "Return editable GitHub issue draft text for REPOSITORY, TITLE, and BODY."
  (format "Repository: %s\n\nTitle: %s\n\nBody:\n%s\n"
          repository title (string-trim body)))

(defun my-codex--github-issue-draft-header-line (&optional repository)
  "Return the GitHub issue draft header line for REPOSITORY."
  (if repository
      (format
       "Edit GitHub issue draft for %s. C-c C-c creates issue; C-c C-k cancels."
       repository)
    "Edit GitHub issue draft. C-c C-c creates issue; C-c C-k cancels."))

(defun my-codex--github-issue-process-sentinel (proc _event)
  "Handle completion of GitHub issue creation process PROC."
  (when-let ((result (my-codex--process-result proc)))
    (let ((status (car result))
          (buffer (cdr result))
          (file (process-get proc 'my-codex-temp-file))
          (draft-buffer (process-get proc 'my-codex-draft-buffer)))
      (my-codex--delete-temp-file file)
      (if (zerop status)
          (progn
            (when (buffer-live-p buffer)
              (with-current-buffer buffer
                (goto-char (point-min))
                (message "GitHub issue created: %s"
                         (string-trim (buffer-string)))))
            (when (buffer-live-p draft-buffer)
              (with-current-buffer draft-buffer
                (setq my-codex--github-issue-creation-in-progress nil))
              (quit-windows-on draft-buffer t)))
        (when (buffer-live-p draft-buffer)
          (with-current-buffer draft-buffer
            (setq my-codex--github-issue-creation-in-progress nil)
            (setq-local header-line-format
                        (my-codex--github-issue-draft-header-line
                         my-codex--github-issue-repository))))
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
         (get-buffer-create (my-codex--github-buffer-name root 'issue))))
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
       (my-codex--delete-temp-file file)
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
  (let* ((fields (my-codex--github-issue-draft-fields))
         (repository (plist-get fields :repository))
         (title (plist-get fields :title))
         (body (plist-get fields :body))
         (expected-repository my-codex--github-issue-repository)
         (current-repository
          (my-codex--github-repository-name default-directory)))
    (unless repository
      (user-error "GitHub issue repository is missing from draft"))
    (unless (equal repository expected-repository)
      (user-error "GitHub issue repository changed from %s to %s"
                  expected-repository repository))
    (unless (equal repository current-repository)
      (user-error "GitHub repository changed from %s to %s"
                  repository current-repository))
    (setq my-codex--github-issue-creation-in-progress t)
    (setq-local header-line-format
                "Creating GitHub issue with gh; wait for completion.")
    (condition-case err
        (my-codex--create-github-issue-with-body
         title body default-directory (current-buffer))
      (error
       (setq my-codex--github-issue-creation-in-progress nil)
       (setq-local header-line-format
                   (my-codex--github-issue-draft-header-line
                    my-codex--github-issue-repository))
       (signal (car err) (cdr err))))))

(defun my-codex--cancel-github-issue-draft ()
  "Cancel the current GitHub issue draft buffer."
  (interactive)
  (when my-codex--github-issue-creation-in-progress
    (user-error "GitHub issue creation is already in progress"))
  (quit-window 'kill)
  (message "GitHub issue draft cancelled."))

(defun my-codex-edit-github-issue-draft (draft root)
  "Open an editable GitHub issue DRAFT for ROOT."
  (let* ((repository (my-codex--github-repository-name root))
         (fields (my-codex--parse-github-issue-draft draft))
         (title (plist-get fields :title))
         (body (plist-get fields :body))
         (buffer
          (get-buffer-create
           (my-codex--github-buffer-name root 'issue-draft))))
    (pop-to-buffer buffer)
    (my-codex--prepare-edit-buffer
     (my-codex--github-issue-draft-text repository title body)
     root #'my-codex--session-export-mode
     (my-codex--github-issue-draft-header-line repository)
     #'my-codex--create-github-issue-from-draft
     #'my-codex--cancel-github-issue-draft)
    (setq my-codex--github-issue-repository repository)
    (message "Edit the GitHub issue draft, then press C-c C-c to create it.")))

;;;###autoload
(defun my-codex-summarise-session-to-github-issue ()
  "Ask the agent to draft a GitHub issue from the current conversation.
Open an editable issue draft before running `gh issue create'."
  (interactive)
  (let* ((buffer (my-codex-active-session-buffer t))
         (root (with-current-buffer buffer
                 (or my-codex-session-project-root
                     (my-codex-project-root)))))
    (unless (executable-find "gh")
      (user-error "GitHub CLI `gh' not found in exec-path"))
    (my-codex--request-marked-output
     :name "GITHUB_ISSUE_DRAFT"
     :buffer buffer
     :prompt my-codex-github-issue-summary-prompt
     :placeholder "<GitHub issue draft here>"
     :callback (lambda (draft)
                 (my-codex-edit-github-issue-draft draft root))
     :timeout-message "Timed out waiting for agent GitHub issue draft."
     :ready-message "Agent GitHub issue draft is ready for editing."
     :poll-interval my-codex-generated-output-poll-interval
     :poll-attempts my-codex-generated-output-poll-attempts
     :timer-var 'my-codex--generated-artefact-wait-timer)
    (message "Asked %s to draft a GitHub issue; waiting to open editor."
             (my-codex--active-agent-label root))))

(provide 'my-codex-github)

;;; my-codex-github.el ends here
