;;; my-codex-github.el --- GitHub helpers for my-codex -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Manlio Morini

;; This file is not part of GNU Emacs.

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at https://mozilla.org/MPL/2.0/.

;;; Commentary:

;; GitHub helpers for creating issue drafts from agent sessions.

;;; Code:

(require 'browse-url)
(require 'json)
(require 'subr-x)
(require 'tabulated-list)
(require 'my-codex-core)
(require 'my-codex-prompts)

(defvar-local my-codex--github-issue-creation-in-progress nil
  "Non-nil while the current GitHub issue draft is being submitted.")

(defvar-local my-codex--github-issue-repository nil
  "GitHub repository selected for the current issue draft.")

(defvar-local my-codex--github-issue-list-process nil
  "Current refresh process for a GitHub issue list buffer.")

(defvar-local my-codex--github-issue-list-items nil
  "Alist of issue numbers and data in a GitHub issue list buffer.")

(defvar-local my-codex--github-issue-view-process nil
  "Current `gh issue view' process for a GitHub issue buffer.")

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
  :group 'my-codex-git)

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

(defun my-codex--github-issue-list-entry (issue)
  "Return a tabulated list entry for ISSUE."
  (let* ((number (alist-get 'number issue))
         (author (alist-get 'author issue))
         (updated (or (alist-get 'updatedAt issue) "")))
    (list number
          (vector (number-to-string number)
                  (or (alist-get 'title issue) "")
                  (or (alist-get 'login author) "")
                  (substring updated 0 (min 10 (length updated)))))))

(defun my-codex--github-parse-issue-list-buffer ()
  "Parse issue data in the current JSON buffer."
  (goto-char (point-min))
  (json-parse-buffer :object-type 'alist :array-type 'list
                     :null-object nil :false-object nil))

(defun my-codex--github-issue-list-show-error (buffer status stderr)
  "Display failed issue-list output from BUFFER with exit STATUS and STDERR."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (goto-char (point-max))
      (when (and (buffer-live-p stderr)
                 (not (with-current-buffer stderr (= (buffer-size) 0))))
        (insert "\nstderr:\n"
                (with-current-buffer stderr (buffer-string))))
      (insert (format "\nProcess exited with status %s\n" status))
      (special-mode)
      (rename-buffer "*my-codex open issues error*" t))
    (display-buffer buffer)))

(defun my-codex--github-issue-list-sentinel (proc _event)
  "Handle completion of open issue list process PROC."
  (when-let ((result (my-codex--process-result proc)))
    (let ((status (car result))
          (output (cdr result))
          (target (process-get proc 'my-codex-target-buffer))
          (stderr (process-get proc 'my-codex-stderr-buffer))
          keep-output)
      (when (and (buffer-live-p target)
                 (with-current-buffer target
                   (eq proc my-codex--github-issue-list-process)))
        (with-current-buffer target
          (setq my-codex--github-issue-list-process nil))
        (if (zerop status)
            (condition-case err
                (let ((issues (with-current-buffer output
                                (my-codex--github-parse-issue-list-buffer))))
                  (with-current-buffer target
                    (setq my-codex--github-issue-list-items
                          (mapcar (lambda (issue)
                                    (cons (alist-get 'number issue) issue))
                                  issues))
                    (setq tabulated-list-entries
                          (mapcar #'my-codex--github-issue-list-entry issues))
                    (tabulated-list-print t))
                  (message "Open issue list updated."))
              (error
               (setq keep-output t)
               (my-codex--github-issue-list-show-error
                output "invalid JSON" stderr)
               (message "Unable to parse open issue list: %s"
                        (error-message-string err))))
          (setq keep-output t)
          (my-codex--github-issue-list-show-error output status stderr)
          (message "Open issue list failed.")))
      (unless keep-output
        (when (buffer-live-p output)
          (kill-buffer output)))
      (when (buffer-live-p stderr)
        (kill-buffer stderr)))))

(defun my-codex--github-issue-at-point ()
  "Return issue data for the tabulated row at point."
  (or (alist-get (tabulated-list-get-id)
                 my-codex--github-issue-list-items)
      (user-error "No GitHub issue on this row")))

(defun my-codex-github-browse-issue ()
  "Open the GitHub issue at point in a browser."
  (interactive)
  (browse-url (alist-get 'url (my-codex--github-issue-at-point))))

(defun my-codex--github-issue-view-sentinel (proc _event)
  "Finish displaying the issue viewed by PROC."
  (when-let ((result (my-codex--process-result proc)))
    (let ((status (car result))
          (buffer (cdr result)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (eq proc my-codex--github-issue-view-process)
            (setq my-codex--github-issue-view-process nil)
            (let ((inhibit-read-only t))
              (goto-char (point-max))
              (unless (zerop status)
                (insert (format "\nProcess exited with status %s\n" status))))
            (goto-char (point-min))
            (special-mode)
            (message "GitHub issue view %s."
                     (if (zerop status) "updated" "failed"))))))))

(defun my-codex-github-view-issue ()
  "View the GitHub issue at point in an Emacs buffer."
  (interactive)
  (let* ((issue (my-codex--github-issue-at-point))
         (number (alist-get 'number issue))
         (root default-directory)
         (buffer (get-buffer-create
                  (format "*GitHub issue #%s:%s*" number
                          (my-codex--safe-root-name root)))))
    (with-current-buffer buffer
      (when-let ((old-process my-codex--github-issue-view-process))
        (setq my-codex--github-issue-view-process nil)
        (when (process-live-p old-process)
          (delete-process old-process)))
      (let ((inhibit-read-only t))
        (erase-buffer))
      (setq default-directory root))
    (pop-to-buffer buffer)
    (let ((process
           (let ((default-directory root))
             (make-process
              :name (format "my-codex-github-issue-%s" number)
              :buffer buffer
              :command (list "gh" "issue" "view" (number-to-string number)
                             "--comments")
              :connection-type 'pipe
              :noquery t
              :sentinel #'my-codex--github-issue-view-sentinel))))
      (with-current-buffer buffer
        (setq my-codex--github-issue-view-process process))
      process)))

(defun my-codex--github-issue-number-less-p (first second)
  "Return non-nil when issue entry FIRST has a lower number than SECOND."
  (< (string-to-number (aref (cadr first) 0))
     (string-to-number (aref (cadr second) 0))))

(defvar-keymap my-codex-github-issue-list-mode-map
  :parent tabulated-list-mode-map
  "RET" #'my-codex-github-view-issue
  "b" #'my-codex-github-browse-issue)

(define-derived-mode my-codex-github-issue-list-mode tabulated-list-mode
  "GitHub Issues"
  "Major mode for browsing open GitHub issues."
  (setq tabulated-list-format
        [("#" 7 my-codex--github-issue-number-less-p)
         ("Title" 50 t)
         ("Author" 20 t)
         ("Updated" 10 t)])
  (setq tabulated-list-padding 1)
  (setq revert-buffer-function #'my-codex--github-refresh-issue-list)
  (setq-local header-line-format
              "Open GitHub issues  [RET:View  b:Browser  g:Refresh]")
  (tabulated-list-init-header))

(defun my-codex--github-refresh-issue-list (&rest _)
  "Refresh open issues in the current GitHub issue list buffer."
  (unless (derived-mode-p 'my-codex-github-issue-list-mode)
    (user-error "Not in a GitHub issue list buffer"))
  (when-let ((old-process my-codex--github-issue-list-process))
    (setq my-codex--github-issue-list-process nil)
    (when (process-live-p old-process)
      (delete-process old-process)))
  (let* ((target (current-buffer))
         (root default-directory)
         (output (generate-new-buffer " *my-codex open issues output*"))
         (stderr (generate-new-buffer " *my-codex open issues stderr*"))
         (default-directory root)
         (process
          (make-process
           :name "my-codex-open-issues"
           :buffer output
           :stderr stderr
           :command (list "gh" "issue" "list"
                          "--state" "open"
                          "--limit" "100"
                          "--json" "number,title,url,author,updatedAt")
           :connection-type 'pipe
           :noquery t
           :sentinel #'my-codex--github-issue-list-sentinel)))
    (process-put process 'my-codex-target-buffer target)
    (process-put process 'my-codex-stderr-buffer stderr)
    (setq my-codex--github-issue-list-process process)
    (message "Listing open issues with gh...")
    process))

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
      (setq default-directory root)
      (unless (derived-mode-p 'my-codex-github-issue-list-mode)
        (my-codex-github-issue-list-mode)))
    (pop-to-buffer buffer)
    (with-current-buffer buffer
      (my-codex--github-refresh-issue-list))))

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
