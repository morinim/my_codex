;;; my-codex-git-test.el --- Tests for my-codex-git -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Code:

(require 'ert)
(require 'my-codex-git)

(ert-deftest my-codex-clean-commit-message-body-lines-fills-paragraphs ()
  (let ((my-codex-commit-message-fill-column 34))
    (should
     (equal
      (my-codex--clean-commit-message-body-lines
       '("" "  first body line with extra space"
         "second body line that wraps"
         "" "- list item that wraps with hanging indentation"
         "    preformatted line  "))
      '("" "first body line with extra space\nsecond body line that wraps"
        "" "- list item that wraps with\n  hanging indentation"
        "    preformatted line")))))

(ert-deftest my-codex-clean-commit-message-trims-and-fills ()
  (let ((my-codex-commit-message-fill-column 30))
    (should
     (equal
      (my-codex-clean-commit-message
       "  fix: trim message  \n\n  body text with extra spaces that wraps  \n")
      "fix: trim message\n\nbody text with extra spaces\nthat wraps"))))

(ert-deftest my-codex-git-commit-latest-message-uses-request-markers ()
  (let ((buffer (generate-new-buffer "*my-codex-test-session*"))
        (root "/project/")
        edited-message)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq-local my-codex--commit-message-request-marker
                        (copy-marker (point)))
            (setq-local my-codex--commit-message-request-output-markers
                        '("BEGIN_COMMIT_MESSAGE_unique"
                          . "END_COMMIT_MESSAGE_unique"))
            (setq-local my-codex--commit-message-request-signature "sig")
            (insert "BEGIN_COMMIT_MESSAGE\n"
                    "<commit message here>\n"
                    "END_COMMIT_MESSAGE\n"
                    "BEGIN_COMMIT_MESSAGE_unique\n"
                    "fix: use unique markers\n"
                    "END_COMMIT_MESSAGE_unique\n"))
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'my-codex--ensure-git-repository)
                     #'ignore)
                    ((symbol-function 'my-codex--staged-changes-p)
                     (lambda () t))
                    ((symbol-function 'my-codex--staged-diff-signature)
                     (lambda () "sig"))
                    ((symbol-function 'my-codex-active-session-buffer)
                     (lambda (&optional _require-live) buffer))
                    ((symbol-function 'my-codex-edit-git-commit-with-message)
                     (lambda (message _root _signature _codex-buffer)
                       (setq edited-message message))))
            (my-codex-git-commit-with-latest-message)
            (should (equal edited-message "fix: use unique markers"))))
      (kill-buffer buffer))))

(ert-deftest my-codex-git-commit-latest-message-waits-on-echoed-placeholder ()
  (let ((buffer (generate-new-buffer "*my-codex-test-session*"))
        (root "/project/")
        waited edited-message)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq-local my-codex--commit-message-request-marker
                        (copy-marker (point)))
            (setq-local my-codex--commit-message-request-output-markers
                        '("BEGIN_COMMIT_MESSAGE_unique"
                          . "END_COMMIT_MESSAGE_unique"))
            (setq-local my-codex--commit-message-request-signature "sig")
            (insert "> Put only the final answer between these exact markers:\n\n"
                    "BEGIN_COMMIT_MESSAGE_unique\n"
                    "<commit message here>\n"
                    "END_COMMIT_MESSAGE_unique\n"))
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'my-codex--ensure-git-repository)
                     #'ignore)
                    ((symbol-function 'my-codex--staged-changes-p)
                     (lambda () t))
                    ((symbol-function 'my-codex--staged-diff-signature)
                     (lambda () "sig"))
                    ((symbol-function 'my-codex-active-session-buffer)
                     (lambda (&optional _require-live) buffer))
                    ((symbol-function 'my-codex-edit-git-commit-with-message)
                     (lambda (message _root _signature _codex-buffer)
                       (setq edited-message message)))
                    ((symbol-function 'my-codex--wait-for-commit-message)
                     (lambda (&rest _args)
                       (setq waited t))))
            (my-codex-git-commit-with-latest-message)
            (should waited)
            (should-not edited-message)))
      (kill-buffer buffer))))

(ert-deftest my-codex-git-command-does-not-load-main-package ()
  (let* ((script '(progn
                    (setq load-prefer-newer t)
                    (require 'my-codex-git)
                    (condition-case err
                        (my-codex-send-git-diff)
                      (error (princ (format "%S\n" err))))
                    (princ (if (featurep 'my-codex)
                               "feature-loaded"
                             "feature-missing"))))
         (output
          (with-temp-buffer
            (let ((exit-code
                   (call-process invocation-name nil t nil
                                 "--batch" "-Q" "-L" default-directory
                                 "--eval" (prin1-to-string script))))
              (unless (zerop exit-code)
                (error "Nested Emacs failed: %s" (buffer-string)))
              (buffer-string)))))
    (should (string-match-p "feature-missing" output))
    (should-not (string-match-p "void-function" output))
    (should-not (string-match-p "void-variable" output))))

(ert-deftest my-codex-git-command-sends-prompt-without-main-package ()
  (unless (executable-find "git")
    (ert-skip "Git executable not found"))
  (let ((load-path-root default-directory)
        (root (file-name-as-directory (make-temp-file "my-codex-git" t))))
    (unwind-protect
        (let* ((script
                `(progn
                   (setq load-prefer-newer t)
                   (setq default-directory ,root)
                   (require 'cl-lib)
                   (require 'my-codex-git)
                   (let ((buffer (get-buffer-create (my-codex-current-buffer-name))))
                     (my-codex--mark-default-session
                      buffer default-directory 'workspace-write 'codex)
                     (cl-letf (((symbol-function 'get-buffer-process)
                                (lambda (candidate)
                                  (eq candidate buffer)))
                               ((symbol-function 'process-live-p)
                                (lambda (process) process))
                               ((symbol-function 'pop-to-buffer)
                                #'ignore)
                               ((symbol-function 'vterm-send-string)
                                (lambda (prompt &optional paste)
                                  (when (and (stringp prompt) paste)
                                    (princ "sent\n"))))
                               ((symbol-function 'vterm-send-return)
                                #'ignore))
                       (my-codex-send-git-diff)))
                   (princ (if (featurep 'my-codex)
                              "feature-loaded"
                            "feature-missing"))))
               (output
                (with-temp-buffer
                  (let ((exit-code
                         (let ((default-directory root))
                           (call-process "git" nil nil nil "init")
                           (call-process invocation-name nil t nil
                                         "--batch" "-Q" "-L" load-path-root
                                         "--eval" (prin1-to-string script)))))
                    (unless (zerop exit-code)
                      (error "Nested Emacs failed: %s" (buffer-string)))
                    (buffer-string)))))
          (should (string-match-p "sent" output))
          (should (string-match-p "feature-missing" output))
          (should-not (string-match-p "void-function" output)))
      (delete-directory root t))))

(ert-deftest my-codex-review-current-file-diff-builds-focused-prompt ()
  (let ((root "/project/") captured)
    (with-temp-buffer
      (setq buffer-file-name "/project/src/file name.el")
      (cl-letf (((symbol-function 'my-codex-project-root) (lambda () root))
                ((symbol-function 'my-codex--ensure-git-repository) #'ignore)
                ((symbol-function 'my-codex--git-toplevel) (lambda () root))
                ((symbol-function 'my-codex--git-relative-file-name) #'ignore)
                ((symbol-function 'my-codex--send-git-prompt)
                 (lambda (prompt) (setq captured prompt))))
        (my-codex-review-current-file-diff)
        (should (string-match-p
                 (regexp-quote "git diff -- src/file\\ name.el") captured))
        (should (string-match-p "Do not edit unless asked" captured))))))

(ert-deftest my-codex-review-current-file-diff-prefix-selects-staged-diff ()
  (let ((root "/project/") captured)
    (with-temp-buffer
      (setq buffer-file-name "/project/example.el")
      (cl-letf (((symbol-function 'my-codex-project-root) (lambda () root))
                ((symbol-function 'my-codex--ensure-git-repository) #'ignore)
                ((symbol-function 'my-codex--git-toplevel) (lambda () root))
                ((symbol-function 'my-codex--git-relative-file-name) #'ignore)
                ((symbol-function 'my-codex--send-git-prompt)
                 (lambda (prompt) (setq captured prompt))))
        (my-codex-review-current-file-diff t)
        (should (string-match-p
                 (regexp-quote "git diff --cached -- example.el") captured))))))

(ert-deftest my-codex-review-current-file-diff-preserves-literal-percent-signs ()
  (let ((root "/project/")
        (my-codex-git-current-file-diff-review-prompt-template
         "Review 100% of changes using %s")
        captured)
    (with-temp-buffer
      (setq buffer-file-name "/project/example.el")
      (cl-letf (((symbol-function 'my-codex-project-root) (lambda () root))
                ((symbol-function 'my-codex--ensure-git-repository) #'ignore)
                ((symbol-function 'my-codex--git-toplevel) (lambda () root))
                ((symbol-function 'my-codex--git-relative-file-name) #'ignore)
                ((symbol-function 'my-codex--send-git-prompt)
                 (lambda (prompt) (setq captured prompt))))
        (my-codex-review-current-file-diff)
        (should (equal captured
                       "Review 100% of changes using git diff -- example.el"))))))

(ert-deftest my-codex-current-file-git-commands-use-left-file-from-eat ()
  (let ((edit-buffer (generate-new-buffer " *my-codex-eat-edit*"))
        (agent-buffer (generate-new-buffer " *my-codex-eat-agent*"))
        edit-window agent-window)
    (unwind-protect
        (progn
          (delete-other-windows)
          (setq edit-window (selected-window))
          (set-window-buffer edit-window edit-buffer)
          (setq agent-window (split-window-right))
          (set-window-buffer agent-window agent-buffer)
          (with-current-buffer edit-buffer
            (setq buffer-file-name "/project/src/example.el"))
          (with-current-buffer agent-buffer
            (setq major-mode 'eat-mode))
          (select-window agent-window)
          (cl-letf (((symbol-function 'my-codex-active-session-buffer)
                     (lambda (&optional _require-live) agent-buffer)))
            (should (equal (my-codex--current-or-left-file-name)
                           "/project/src/example.el"))
            (should (my-codex--current-or-left-file-available-p))))
      (when (window-live-p agent-window)
        (delete-window agent-window))
      (when (buffer-live-p edit-buffer)
        (kill-buffer edit-buffer))
      (when (buffer-live-p agent-buffer)
        (kill-buffer agent-buffer)))))

(ert-deftest my-codex-preset-command-loads-git-helpers-without-main-package ()
  (let ((load-path-root default-directory)
        (root (file-name-as-directory (make-temp-file "my-codex-preset" t))))
    (unwind-protect
        (let* ((script
                `(progn
                   (setq load-prefer-newer t)
                   (setq default-directory ,root)
                   (require 'cl-lib)
                   (require 'my-codex-prompts)
                   (setq my-codex-prompt-presets
                         '(("Refactor" . "Refactor prompt")))
                   (cl-letf (((symbol-function 'completing-read)
                              (lambda (&rest _args) "Refactor"))
                             ((symbol-function 'read-string)
                              (lambda (&rest _args) ""))
                             ((symbol-function 'my-codex-project-root)
                              (lambda () default-directory))
                             ((symbol-function 'my-codex--preview-and-send-prompt)
                              (lambda (prompt &optional _sent-message)
                                (princ prompt)))
                             ((symbol-function 'use-region-p)
                              (lambda () nil)))
                     (my-codex-ask-with-preset))
                   (princ (if (featurep 'my-codex-git)
                              "git-loaded"
                            "git-missing"))
                   (princ (if (featurep 'my-codex)
                              " feature-loaded"
                            " feature-missing"))))
               (output
                (with-temp-buffer
                  (let ((exit-code
                         (let ((default-directory root))
                           (call-process invocation-name nil t nil
                                         "--batch" "-Q" "-L" load-path-root
                                         "--eval" (prin1-to-string script)))))
                    (unless (zerop exit-code)
                      (error "Nested Emacs failed: %s" (buffer-string)))
                    (buffer-string)))))
          (should (string-match-p "Refactor prompt" output))
          (should (string-match-p "git-loaded" output))
          (should (string-match-p "feature-missing" output))
          (should-not (string-match-p "void-function" output)))
      (delete-directory root t))))

(defun my-codex-test--init-git-repository ()
  "Initialize a Git repository in `default-directory'."
  (unless (executable-find "git")
    (ert-skip "Git executable missing"))
  (should (eq 0 (process-file "git" nil nil nil "init" "-q"))))

(defun my-codex-test--write-file (file text)
  "Write TEXT to FILE under `default-directory'."
  (with-temp-file (expand-file-name file default-directory)
    (insert text)))

(ert-deftest my-codex-ediff-uses-side-by-side-layout-and-restores-windows ()
  (let ((head-buffer (generate-new-buffer " *my-codex-head-test*"))
        (worktree-buffer (generate-new-buffer " *my-codex-worktree-test*"))
        (control-buffer (generate-new-buffer " *my-codex-ediff-test*"))
        (saved-window-configuration (current-window-configuration))
        captured-layout captured-split captured-head captured-after-quit-hook
        restored-window-configuration)
    (unwind-protect
        (progn
          (with-current-buffer worktree-buffer
            (emacs-lisp-mode))
          (cl-letf (((symbol-function 'my-codex--git-toplevel)
                     (lambda () "/project/"))
                    ((symbol-function 'my-codex--git-relative-file-name)
                     (lambda (&rest _args) "example.el"))
                    ((symbol-function 'my-codex--git-head-buffer)
                     (lambda (&rest _args) head-buffer))
                    ((symbol-function 'find-file-noselect)
                     (lambda (&rest _args) worktree-buffer))
                    ((symbol-function 'current-window-configuration)
                     (lambda (&rest _args) saved-window-configuration))
                    ((symbol-function 'set-window-configuration)
                     (lambda (configuration)
                       (setq restored-window-configuration configuration)))
                    ((symbol-function 'ediff-buffers)
                     (lambda (head _worktree startup-hooks &rest _args)
                       (setq captured-layout ediff-window-setup-function
                             captured-split ediff-split-window-function
                             captured-head head)
                       (with-current-buffer control-buffer
                         (mapc #'funcall startup-hooks)))))
            (my-codex--ediff-file-against-head
             "/project/example.el" "/project/")
            (with-current-buffer control-buffer
              (setq captured-after-quit-hook
                    (remq t ediff-after-quit-hook-internal))
              (setq-local ediff-quit-hook
                          (list (lambda ()
                                  (setq restored-window-configuration
                                        'overwritten)))))
          (should (eq captured-layout #'ediff-setup-windows-plain))
          (should (eq captured-split #'split-window-horizontally))
          (should (eq captured-head head-buffer))
          (with-current-buffer head-buffer
            (should (derived-mode-p 'emacs-lisp-mode)))
          (with-current-buffer control-buffer
            (run-hooks 'ediff-cleanup-hook)
            (run-hooks 'ediff-quit-hook))
          (mapc #'funcall captured-after-quit-hook))
          (should (eq restored-window-configuration saved-window-configuration))
          (should-not (buffer-live-p head-buffer)))
      (dolist (buffer (list head-buffer worktree-buffer control-buffer))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest my-codex-show-git-diff-populates-diff-mode-buffer ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-diff" t)))
        warned)
    (let ((default-directory root))
      (my-codex-test--init-git-repository)
      (my-codex-test--write-file "tracked.txt" "old\n")
      (should (eq 0 (process-file "git" nil nil nil "add" "--" "tracked.txt")))
      (my-codex-test--write-file "tracked.txt" "new\n")
      (let ((buffer-name (my-codex--git-diff-buffer-name root nil)))
        (unwind-protect
            (cl-letf (((symbol-function 'my-codex-project-root)
                       (lambda () root))
                      ((symbol-function 'my-codex--warn-about-unsaved-project-buffers)
                       (lambda () (setq warned t)))
                      ((symbol-function 'display-buffer)
                       (lambda (buffer &rest _args) buffer)))
              (my-codex-show-git-diff)
              (should warned)
              (with-current-buffer buffer-name
                (should (derived-mode-p 'diff-mode))
                (should buffer-read-only)
                (should (equal default-directory root))
                (should (string-match-p "^-old" (buffer-string)))
                (should (string-match-p "^\\+new" (buffer-string)))))
          (when-let ((buffer (get-buffer buffer-name)))
            (kill-buffer buffer)))))))

(ert-deftest my-codex-show-git-diff-reports-empty-worktree-diff ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-diff" t))))
    (let ((default-directory root))
      (my-codex-test--init-git-repository)
      (cl-letf (((symbol-function 'my-codex-project-root) (lambda () root))
                ((symbol-function 'display-buffer)
                 (lambda (&rest _) (ert-fail "Displayed an empty diff"))))
        (let ((error (should-error (my-codex-show-git-diff)
                                   :type 'user-error)))
          (should (string-match-p "No unstaged tracked changes"
                                  (error-message-string error))))))))

(ert-deftest my-codex-show-git-staged-diff-populates-diff-mode-buffer ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-diff" t))))
    (let ((default-directory root))
      (my-codex-test--init-git-repository)
      (my-codex-test--write-file "staged.txt" "staged\n")
      (should (eq 0 (process-file "git" nil nil nil "add" "--" "staged.txt")))
      (let ((buffer-name (my-codex--git-diff-buffer-name root t)))
        (unwind-protect
            (cl-letf (((symbol-function 'my-codex-project-root)
                       (lambda () root))
                      ((symbol-function 'display-buffer)
                       (lambda (buffer &rest _args) buffer)))
              (my-codex-show-git-staged-diff)
              (with-current-buffer buffer-name
                (should (derived-mode-p 'diff-mode))
                (should buffer-read-only)
                (should (equal default-directory root))
                (should (string-match-p "^\\+staged" (buffer-string)))))
          (when-let ((buffer (get-buffer buffer-name)))
            (kill-buffer buffer)))))))

(ert-deftest my-codex-show-git-staged-diff-reports-empty-staged-diff ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-diff" t))))
    (let ((default-directory root))
      (my-codex-test--init-git-repository)
      (cl-letf (((symbol-function 'my-codex-project-root) (lambda () root))
                ((symbol-function 'display-buffer)
                 (lambda (&rest _) (ert-fail "Displayed an empty diff"))))
        (let ((error (should-error (my-codex-show-git-staged-diff)
                                   :type 'user-error)))
          (should (string-match-p "No staged Git changes"
                                  (error-message-string error))))))))

(ert-deftest my-codex-project-overview-sends-orientation-instructions ()
  (let (prompt)
    (cl-letf (((symbol-function 'my-codex--preview-and-send-prompt)
               (lambda (text) (setq prompt text))))
      (my-codex-send-project-overview))
    (should
     (equal
      prompt
      "Inspect the repository structure, Git status, and applicable instruction files.
Build a concise working map for future requests in this thread.
Do not modify files."))))


(provide 'my-codex-git-test)

;;; my-codex-git-test.el ends here
