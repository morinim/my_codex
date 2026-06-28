;;; my-codex-test.el --- Tests for my-codex -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Code:

(require 'ert)
(require 'my-codex)
(require 'my-codex-prompts)
(require 'my-codex-git)
(require 'my-codex-github)
(require 'my-codex-links)
(require 'my-codex-doctor)
(require 'my-codex-vterm)

(defvar flycheck-current-errors)
(defvar flycheck-mode)
(defvar vterm-copy-mode-hook)
(defvar vterm-mode-hook)

(ert-deftest my-codex-require-keeps-optional-modules-lazy ()
  (let* ((script '(progn
                    (setq load-prefer-newer t)
                    (require 'my-codex)
                    (prin1
                     (mapcar #'featurep
                             '(my-codex-prompts my-codex-git
                               my-codex-github my-codex-links
                               my-codex-doctor my-codex-vterm)))))
         (output
          (with-temp-buffer
            (let ((exit-code
                   (call-process invocation-name nil t nil
                                 "--batch" "-Q" "-L" default-directory
                                 "--eval" (prin1-to-string script))))
              (unless (zerop exit-code)
                (error "Nested Emacs failed: %s" (buffer-string)))
              (buffer-string)))))
    (should (equal output "(nil nil nil nil nil nil)"))))

(ert-deftest my-codex-require-autoloads-main-prompt-dependencies ()
  (let* ((script '(progn
                    (setq load-prefer-newer t)
                    (require 'my-codex)
                    (prin1
                     (mapcar
                      (lambda (function)
                        (and (autoloadp (symbol-function function))
                             (nth 1 (symbol-function function))))
                      '(my-codex--request-marked-output
                        my-codex-send-prompt
                        my-codex-visible-window)))))
         (output
          (with-temp-buffer
            (let ((exit-code
                   (call-process invocation-name nil t nil
                                 "--batch" "-Q" "-L" default-directory
                                 "--eval" (prin1-to-string script))))
              (unless (zerop exit-code)
                (error "Nested Emacs failed: %s" (buffer-string)))
              (buffer-string)))))
    (should (equal output
                   "(\"my-codex-prompts\" \"my-codex-prompts\" \"my-codex-prompts\")"))))

(ert-deftest my-codex-command-catalogue-commands-exist ()
  (dolist (entry my-codex-command-catalogue)
    (should (fboundp (car entry)))))

(ert-deftest my-codex-command-catalogue-commands-exist-after-clean-require ()
  (let* ((script '(progn
                    (setq load-prefer-newer t)
                    (require 'my-codex)
                    (prin1
                     (cl-every (lambda (entry) (fboundp (car entry)))
                               my-codex-command-catalogue))))
         (output
          (with-temp-buffer
            (let ((exit-code
                   (call-process invocation-name nil t nil
                                 "--batch" "-Q" "-L" default-directory
                                 "--eval" (prin1-to-string script))))
              (unless (zerop exit-code)
                (error "Nested Emacs failed: %s" (buffer-string)))
              (buffer-string)))))
    (should (equal output "t"))))

(ert-deftest my-codex-command-catalogue-bindings-do-not-conflict ()
  (let ((bindings (make-hash-table :test #'equal)))
    (dolist (entry my-codex-command-catalogue)
      (let* ((command (car entry))
             (properties (nthcdr 4 entry))
             (prefix (or (plist-get properties :prefix)
                         'my-codex-transient))
             (binding (cons prefix (key-description (kbd (nth 1 entry)))))
             (existing (gethash binding bindings)))
        (should (or (not existing) (eq existing command)))
        (puthash binding command bindings)))))

(ert-deftest my-codex-command-catalogue-menu-entries-have-help ()
  (dolist (entry my-codex-command-catalogue)
    (let ((properties (nthcdr 4 entry)))
      (when (plist-get properties :menu)
        (should (plist-get properties :help))))))

(ert-deftest my-codex-transient-groups-use-columns ()
  (let* ((expansion
          (macroexpand-1
           '(my-codex--define-catalogue-transient my-codex-transient
              "Show agent commands.")))
         (layout (nth 4 expansion)))
    (should (vectorp layout))
    (should (seq-every-p #'vectorp layout))))

(ert-deftest my-codex-transient-target-description-uses-session-buffer ()
  (let ((root (file-name-as-directory (file-truename default-directory)))
        (buffer (generate-new-buffer " *my-codex-target*")))
    (unwind-protect
        (progn
          (my-codex--mark-named-session
           buffer "feature-x" root 'workspace-write 'codex)
          (cl-letf (((symbol-function 'transient-scope) (lambda () buffer)))
            (should
             (equal (my-codex--transient-target-description)
                    "Target: Codex · feature-x · workspace-write"))))
      (kill-buffer buffer))))

(ert-deftest my-codex-active-session-buffer-prefers-transient-target ()
  (let ((root (file-name-as-directory (file-truename default-directory)))
        (target (generate-new-buffer " *my-codex-captured-target*"))
        (other (generate-new-buffer " *my-codex-other-target*")))
    (unwind-protect
        (progn
          (my-codex--mark-named-session
           target "feature-x" root 'workspace-write 'codex)
          (my-codex--mark-default-session other root 'read-only 'codex)
          (cl-letf (((symbol-function 'transient-scope) (lambda () target))
                    ((symbol-function 'my-codex--session-buffer-for-window)
                     (lambda (&rest _) other)))
            (should (eq (my-codex-active-session-buffer) target))))
      (kill-buffer target)
      (kill-buffer other))))

(ert-deftest my-codex-session-transient-opens-without-session-buffer ()
  (let (setup-arguments)
    (cl-letf (((symbol-function 'my-codex-active-session-buffer)
               (lambda (&rest _) (user-error "No session")))
              ((symbol-function 'transient-setup)
               (lambda (&rest arguments)
                 (setq setup-arguments arguments))))
      (my-codex-session-transient)
      (should (equal setup-arguments
                     '(my-codex-session-transient nil nil :scope nil))))))

(defmacro my-codex-test--with-mock-flycheck (diagnostics &rest body)
  "Run BODY with mocked Flycheck DIAGNOSTICS."
  (declare (indent 1))
  `(let ((flycheck-mode t)
         (flycheck-current-errors ,diagnostics))
     (cl-letf (((symbol-function 'flycheck-error-<)
                (lambda (left right)
                  (let ((left-line (or (plist-get left :line) 1))
                        (right-line (or (plist-get right :line) 1))
                        (left-column (or (plist-get left :column) 1))
                        (right-column (or (plist-get right :column) 1)))
                    (if (/= left-line right-line)
                        (< left-line right-line)
                      (< left-column right-column)))))
               ((symbol-function 'flycheck-error-checker)
                (lambda (diagnostic) (plist-get diagnostic :checker)))
               ((symbol-function 'flycheck-error-column)
                (lambda (diagnostic) (plist-get diagnostic :column)))
               ((symbol-function 'flycheck-error-filename)
                (lambda (diagnostic) (plist-get diagnostic :filename)))
               ((symbol-function 'flycheck-error-id)
                (lambda (diagnostic) (plist-get diagnostic :id)))
               ((symbol-function 'flycheck-error-level)
                (lambda (diagnostic) (plist-get diagnostic :level)))
               ((symbol-function 'flycheck-error-line)
                (lambda (diagnostic) (plist-get diagnostic :line)))
               ((symbol-function 'flycheck-error-message)
                (lambda (diagnostic) (plist-get diagnostic :message))))
       ,@body)))

(ert-deftest my-codex-project-instruction-files-follow-codex-scope ()
  (let* ((root (file-name-as-directory
                (make-temp-file "my-codex-instructions" t)))
         (nested (expand-file-name "src/lib" root))
         (my-codex-agent-profiles
          '((codex
             :instruction-files
             ("AGENTS.override.md" "AGENTS.md" "CODEX.md")
             :instruction-strategy hierarchical-first))))
    (unwind-protect
        (progn
          (make-directory nested t)
          (write-region "root" nil (expand-file-name "AGENTS.md" root))
          (write-region "ignored" nil
                        (expand-file-name "AGENTS.md"
                                          (expand-file-name "src" root)))
          (write-region "override" nil
                        (expand-file-name "AGENTS.override.md"
                                          (expand-file-name "src" root)))
          (write-region "fallback" nil (expand-file-name "CODEX.md" nested))
          (should
           (equal (my-codex-project-instruction-files
                   root nested 'codex)
                  (list (expand-file-name "AGENTS.md" root)
                        (expand-file-name "AGENTS.override.md"
                                          (expand-file-name "src" root))
                        (expand-file-name "CODEX.md" nested)))))
      (delete-directory root t))))

(ert-deftest my-codex-project-instruction-files-separate-antigravity ()
  (let* ((root (file-name-as-directory
                (make-temp-file "my-codex-instructions" t)))
         (my-codex-agent-profiles
          '((antigravity
             :instruction-files
             ("ANTIGRAVITY.md" ".antigravity/instructions.md")
             :instruction-strategy root-all))))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".antigravity" root))
          (write-region "codex" nil (expand-file-name "AGENTS.md" root))
          (write-region "antigravity" nil
                        (expand-file-name "ANTIGRAVITY.md" root))
          (should
           (equal (my-codex-project-instruction-files
                   root root 'antigravity)
                  (list (expand-file-name "ANTIGRAVITY.md" root)))))
      (delete-directory root t))))

(ert-deftest my-codex-open-project-instructions-prompts-for-multiple-files ()
  (let ((root "/project/")
        selected opened)
    (cl-letf (((symbol-function 'my-codex-project-root) (lambda () root))
              ((symbol-function 'my-codex-project-instruction-files)
               (lambda (&rest _args)
                 '("/project/AGENTS.md" "/project/src/AGENTS.md")))
              ((symbol-function 'completing-read)
               (lambda (_prompt candidates &rest _args)
                 (setq selected candidates)
                 "src/AGENTS.md"))
              ((symbol-function 'find-file)
               (lambda (file) (setq opened file))))
      (my-codex-open-project-instructions)
      (should (equal selected '("AGENTS.md" "src/AGENTS.md")))
      (should (equal opened "/project/src/AGENTS.md")))))

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

(ert-deftest my-codex-parse-github-issue-draft-with-repository ()
  (should
   (equal
    (my-codex--parse-github-issue-draft
     "Repository: owner/repo\n\nTitle: Bug report\n\nBody:\nDetails here.\n")
    '(:repository "owner/repo" :title "Bug report" :body "Details here."))))

(ert-deftest my-codex-parse-github-issue-draft-without-repository ()
  (should
   (equal
    (my-codex--parse-github-issue-draft
     "Title: Feature request\n\nBody:\nAdd the thing.\n")
    '(:repository nil :title "Feature request" :body "Add the thing."))))

(ert-deftest my-codex-terminal-marker-regexp-allows-terminal-space ()
  (let ((regexp (my-codex--terminal-marker-regexp "END")))
    (should (string-match-p regexp "E \r\nN\tD"))
    (should-not (string-match-p regexp "ENX"))))

(ert-deftest my-codex-normalize-marked-output-removes-layout-indentation ()
  (should
   (equal
    (my-codex--normalize-marked-output "\r\n    first\n      second\n\n")
    "first\n  second")))

(ert-deftest my-codex-latest-marked-output-after-finds-output-after-marker ()
  (with-temp-buffer
    (insert "old output\n")
    (let ((start (copy-marker (point))))
      (insert "BEGIN_COMMIT_MESSAGE\n"
              "fix: extract latest commit message\n"
              "END_COMMIT_MESSAGE\n")
      (should
       (equal
        (my-codex-latest-commit-message-after (current-buffer) start)
        "fix: extract latest commit message")))))

(ert-deftest my-codex-latest-marked-output-after-ignores-before-marker ()
  (with-temp-buffer
    (insert "BEGIN_COMMIT_MESSAGE\n"
            "fix: stale message\n"
            "END_COMMIT_MESSAGE\n")
    (let ((start (copy-marker (point))))
      (insert "no generated output yet\n")
      (should-not
       (my-codex-latest-commit-message-after (current-buffer) start)))))

(ert-deftest my-codex-latest-marked-output-after-ignores-overlapping-marker ()
  (with-temp-buffer
    (insert "BEGIN_COMMIT_MESSAGE\n"
            "fix: stale message\n")
    (let ((start (copy-marker (point))))
      (insert "END_COMMIT_MESSAGE\n")
      (should-not
       (my-codex-latest-commit-message-after (current-buffer) start)))))

(ert-deftest my-codex-wait-for-marked-output-clears-only-wait-marker ()
  (with-temp-buffer
    (let ((request-marker (copy-marker (point)))
          received)
      (insert "BEGIN_COMMIT_MESSAGE\n"
              "fix: preserve request marker\n"
              "END_COMMIT_MESSAGE\n")
      (my-codex--wait-for-marked-output
       (current-buffer)
       (copy-marker request-marker)
       "BEGIN_COMMIT_MESSAGE"
       "END_COMMIT_MESSAGE"
       (lambda (message)
         (setq received message))
       "Timed out."
       "Ready."
       0.1
       1)
      (should (equal received "fix: preserve request marker"))
      (should (eq (marker-buffer request-marker) (current-buffer))))))

(ert-deftest my-codex-wait-for-marked-output-accepts-final-attempt ()
  (with-temp-buffer
    (let ((request-marker (copy-marker (point)))
          received)
      (insert "BEGIN_COMMIT_MESSAGE\n"
              "fix: accept final poll\n"
              "END_COMMIT_MESSAGE\n")
      (my-codex--wait-for-marked-output
       (current-buffer)
       (copy-marker request-marker)
       "BEGIN_COMMIT_MESSAGE"
       "END_COMMIT_MESSAGE"
       (lambda (message)
         (setq received message))
       "Timed out."
       "Ready."
       0.1
       1
       nil
       1)
      (should (equal received "fix: accept final poll")))))

(ert-deftest my-codex-latest-marked-output-after-uses-latest-block ()
  (with-temp-buffer
    (let ((start (copy-marker (point))))
      (insert "BEGIN_COMMIT_MESSAGE\n"
              "fix: first message\n"
              "END_COMMIT_MESSAGE\n"
              "BEGIN_COMMIT_MESSAGE\n"
              "fix: latest message\n"
              "END_COMMIT_MESSAGE\n")
      (should
       (equal
        (my-codex-latest-commit-message-after (current-buffer) start)
        "fix: latest message")))))

(ert-deftest my-codex-latest-commit-message-ignores-before-request-marker ()
  (let ((buffer (generate-new-buffer "*my-codex-test-session*")))
    (unwind-protect
        (with-current-buffer buffer
          (insert "BEGIN_COMMIT_MESSAGE\n"
                  "fix: stale message\n"
                  "END_COMMIT_MESSAGE\n")
          (setq-local my-codex--commit-message-request-marker (copy-marker (point)))
          (insert "request sent\n")
          (cl-letf (((symbol-function 'my-codex-current-buffer-name)
                     (lambda () (buffer-name buffer))))
            (should-not (my-codex-latest-commit-message))))
      (kill-buffer buffer))))

(ert-deftest my-codex-latest-commit-message-uses-request-markers ()
  (let ((buffer (generate-new-buffer "*my-codex-test-session*")))
    (unwind-protect
        (with-current-buffer buffer
          (setq-local my-codex--commit-message-request-marker
                      (copy-marker (point)))
          (setq-local my-codex--commit-message-request-output-markers
                      '("BEGIN_COMMIT_MESSAGE_unique"
                        . "END_COMMIT_MESSAGE_unique"))
          (insert "BEGIN_COMMIT_MESSAGE\n"
                  "fix: stale fixed-marker message\n"
                  "END_COMMIT_MESSAGE\n"
                  "BEGIN_COMMIT_MESSAGE_unique\n"
                  "fix: use unique markers\n"
                  "END_COMMIT_MESSAGE_unique\n")
          (cl-letf (((symbol-function 'my-codex-current-buffer-name)
                     (lambda () (buffer-name buffer))))
            (should
             (equal (my-codex-latest-commit-message)
                    "fix: use unique markers"))))
      (kill-buffer buffer))))

(ert-deftest my-codex-latest-marked-output-after-ignores-placeholders ()
  (with-temp-buffer
    (let ((start (copy-marker (point))))
      (insert "BEGIN_COMMIT_MESSAGE\n"
              "...\n"
              "END_COMMIT_MESSAGE\n")
      (should-not
       (my-codex-latest-commit-message-after (current-buffer) start)))))

(ert-deftest my-codex-latest-marked-output-after-tolerates-terminal-spacing ()
  (with-temp-buffer
    (let ((start (copy-marker (point))))
      (insert "B \r\nE\tG I N_COMMIT_MESSAGE\n"
              "    fix: tolerate terminal spacing\r\n"
              "E \r\nN\tD_COMMIT_MESSAGE\n")
      (should
       (equal
        (my-codex-latest-commit-message-after (current-buffer) start)
        "fix: tolerate terminal spacing")))))

(ert-deftest my-codex-approx-token-count-rounds-up ()
  (should (= (my-codex--approx-token-count "") 0))
  (should (= (my-codex--approx-token-count "abc") 1))
  (should (= (my-codex--approx-token-count "abcd") 2))
  (should (= (my-codex--approx-token-count "abcde") 2))
  (should (= (my-codex--approx-token-count "é") 1)))

(ert-deftest my-codex-session-access-mode-recognizes-default-commands ()
  (should
   (eq (my-codex--session-access-mode
        (my-codex--agent-command 'codex 'read-only))
       'read-only))
  (should
   (eq (my-codex--session-access-mode
        (my-codex--agent-command 'codex 'workspace-write))
       'workspace-write))
  (should
   (eq (my-codex--session-access-mode
        (my-codex--agent-command 'codex 'resume))
       'resume))
  (should
   (eq (my-codex--session-access-mode "codex --custom")
       'custom)))

(ert-deftest my-codex-access-mode-labels-highlight-risk ()
  (should (equal (my-codex--access-mode-label 'workspace-write t)
                 "WORKSPACE WRITE"))
  (should (equal (my-codex--access-mode-label 'read-only t)
                 "read-only [lock]")))

(ert-deftest my-codex-agent-command-reads-profile-commands ()
  (let ((my-codex-agent-profiles
         '((codex :commands
                  ((read-only . "codex-ro")
                   (workspace . "codex-ww")
                   (resume . "codex-resume")))
           (antigravity :commands
                        ((read-only . "agy-ro")
                         (workspace . "agy-ww")
                         (resume . "agy-resume"))))))
    (should
     (equal (my-codex--agent-command 'codex 'read-only)
            "codex-ro"))
    (should
     (equal (my-codex--agent-command 'codex 'workspace-write)
            "codex-ww"))
    (should
     (equal (my-codex--agent-command 'codex 'resume)
            "codex-resume"))
    (should
     (equal (my-codex--agent-command 'antigravity 'read-only)
            "agy-ro"))
    (should
     (equal (my-codex--agent-command 'antigravity 'workspace-write)
            "agy-ww"))
    (should
     (equal (my-codex--agent-command 'antigravity 'resume)
            "agy-resume"))))

(ert-deftest my-codex-agent-buffer-name-supports-mixed-agents ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-buffer" t))))
    (unwind-protect
        (let ((default-directory root)
              (my-codex-agent 'codex))
          (should
           (string-match-p
            (rx bos "*codex:" (+ anything) ":" (= 8 xdigit) "*")
            (my-codex-current-buffer-name)))
          (should
           (string-match-p
            (rx bos "*agy:" (+ anything) ":" (= 8 xdigit) "*")
            (my-codex-current-buffer-name 'antigravity))))
      (delete-directory root t))))

(ert-deftest my-codex-current-buffer-name-uses-project-active-agent ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-buffer" t))))
    (unwind-protect
        (let ((default-directory root)
              (my-codex-agent 'codex)
              (my-codex--project-active-agents
               (make-hash-table :test #'equal)))
          (cl-letf (((symbol-function 'project-current)
                     (lambda (&optional _maybe-prompt _directory)
                       nil)))
            (my-codex--set-active-agent 'antigravity root)
            (should
             (string-match-p
              (rx bos "*agy:" (+ anything) ":" (= 8 xdigit) "*")
              (my-codex-current-buffer-name)))))
      (delete-directory root t))))

(ert-deftest my-codex-buffer-resolves-project-active-agent-session ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-buffer" t)))
        buffer)
    (unwind-protect
        (let ((default-directory root)
              (my-codex-agent 'codex)
              (my-codex--project-active-agents
               (make-hash-table :test #'equal)))
          (cl-letf (((symbol-function 'project-current)
                     (lambda (&optional _maybe-prompt _directory)
                       nil))
                    ((symbol-function 'get-buffer-process)
                     (lambda (candidate)
                       (eq candidate buffer)))
                    ((symbol-function 'process-live-p)
                     (lambda (process) process)))
            (setq buffer
                  (get-buffer-create
                   (my-codex-current-buffer-name 'antigravity)))
            (my-codex--mark-default-session
             buffer root 'workspace-write 'antigravity)
            (my-codex--set-active-agent 'antigravity root)
            (should (eq (my-codex-buffer) buffer))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest my-codex-mark-default-session-sets-buffer-local-metadata ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-session" t))))
    (unwind-protect
        (with-temp-buffer
          (my-codex--mark-default-session
           (current-buffer) root 'workspace-write)
          (should (local-variable-p 'my-codex-session-id))
          (should
           (string-prefix-p "codex:default:" my-codex-session-id))
          (should (equal my-codex-session-name "default"))
          (should
           (equal my-codex-session-project-root
                  (file-name-as-directory (file-truename root))))
          (should (eq my-codex-session-access-mode 'workspace-write))
          (should (eq my-codex-session-agent 'codex))
          (should (string-match-p "Codex · WORKSPACE WRITE · default"
                                  header-line-format))
          (let ((footer (my-codex--session-footer)))
            (should (string-match-p
                     (regexp-quote (directory-file-name
                                    (abbreviate-file-name root)))
                     footer))
            (should (string-match-p "idle" footer))
            (should (string-match-p "last -" footer))
            (should-not (string-match-p "\\(^\\| · \\)default\\( · \\|$\\)" footer))
            (should-not (string-match-p "WORKSPACE WRITE" footer)))
          (should-not (memq 'mode-line-position mode-line-format)))
      (delete-directory root t))))

(ert-deftest my-codex-session-footer-shows-last-output-time ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-session" t))))
    (unwind-protect
        (with-temp-buffer
          (my-codex--mark-default-session
           (current-buffer) root 'read-only)
          (setq-local my-codex-session-last-output-time
                      (encode-time 0 42 15 25 6 2026))
          (should (string-match-p "last 15:42"
                                  (my-codex--session-footer))))
      (delete-directory root t))))

(ert-deftest my-codex-track-process-output-time-preserves-filter ()
  (let* ((buffer (generate-new-buffer "*my-codex-output-time*"))
         (process (make-pipe-process :name "my-codex-output-time"
                                     :buffer buffer))
         seen)
    (unwind-protect
        (with-current-buffer buffer
          (set-process-filter process
                              (lambda (_proc output)
                                (setq seen output)))
          (my-codex--track-process-output-time process)
          (funcall (process-filter process) process "hello")
          (should (equal seen "hello"))
          (should my-codex-session-last-output-time))
      (when (process-live-p process)
        (delete-process process))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest my-codex-mark-named-session-sets-buffer-local-metadata ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-session" t))))
    (unwind-protect
        (with-temp-buffer
          (my-codex--mark-named-session
           (current-buffer) "plan" root 'read-only 'antigravity)
          (should (local-variable-p 'my-codex-session-id))
          (should
           (string-prefix-p "antigravity:session:" my-codex-session-id))
          (should (string-match-p ":plan-[[:xdigit:]]\\{8\\}\\'"
                                  my-codex-session-id))
          (should (equal my-codex-session-name "plan"))
          (should
           (equal my-codex-session-project-root
                  (file-name-as-directory (file-truename root))))
          (should (eq my-codex-session-access-mode 'read-only))
          (should (eq my-codex-session-agent 'antigravity)))
      (delete-directory root t))))

(ert-deftest my-codex-session-buffer-name-appends-safe-session-name ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-buffer" t))))
    (unwind-protect
        (let ((default-directory root))
          (should
           (string-match-p
            (rx bos "*codex:" (+ anything)
                ":review!docs-" (= 8 xdigit) "*")
            (my-codex-session-buffer-name "review docs"))))
      (delete-directory root t))))

(ert-deftest my-codex-session-buffer-name-includes-agent-prefix ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-buffer" t))))
    (unwind-protect
        (let ((default-directory root))
          (should
           (string-match-p
            (rx bos "*agy:" (+ anything)
                ":review!docs-" (= 8 xdigit) "*")
            (my-codex-session-buffer-name "review docs" 'antigravity))))
      (delete-directory root t))))

(ert-deftest my-codex-safe-session-name-preserves-distinct-names ()
  (let ((names '("review docs" "review:docs" "review!docs")))
    (should
     (equal (length (delete-dups
                     (mapcar #'my-codex--safe-session-name names)))
            (length names)))))

(ert-deftest my-codex-top-renders-dashboard-buffer ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-top" t)))
        (session-buffer (get-buffer-create "*codex-top-render*")))
    (unwind-protect
        (progn
          (my-codex--mark-named-session
           session-buffer "review" root 'workspace-write)
          (cl-letf (((symbol-function 'get-buffer-process)
                     (lambda (buffer)
                       (eq buffer session-buffer)))
                    ((symbol-function 'process-live-p)
                     (lambda (process) process))
                    ((symbol-function 'process-id)
                     (lambda (_) 9999))
                    ((symbol-function 'my-codex--process-output-result)
                     (lambda (program &rest args)
                       (cond
                        ((and (equal program "git") (member "branch" args))
                         '(0 "feature-x"))
                        ((and (equal program "git") (member "status" args))
                         '(0 " M my-codex.el"))
                        (t '(1)))))
                    ((symbol-function 'pop-to-buffer) #'ignore))
            (my-codex-top))
          (with-current-buffer "*Agents Top*"
            (should (derived-mode-p 'my-codex-top-mode))
            (should (string-match-p "review" (buffer-string)))
            (should (string-match-p "Codex" (buffer-string)))
            (should (string-match-p "\\*codex-top-render\\*" (buffer-string)))
            (should (string-match-p "WORKSPACE WRITE" (buffer-string)))
            (should (string-match-p "feature-x" (buffer-string)))
            (should (string-match-p "dirty" (buffer-string)))
            (should (string-match-p "9999" (buffer-string)))
            (should (string-match-p "live" (buffer-string)))))
      (delete-directory root t)
      (when (buffer-live-p session-buffer)
        (kill-buffer session-buffer))
      (when-let ((buffer (get-buffer "*Agents Top*")))
        (kill-buffer buffer)))))

(ert-deftest my-codex-top-header-scrolls-horizontally ()
  (with-temp-buffer
    (my-codex-top-mode)
    (let ((my-codex--header-string "Project Session"))
      (cl-letf (((symbol-function 'window-hscroll) (lambda (&rest _) 8)))
        (should (equal (eval (cadr (nth 2 header-line-format)) t)
                       "Session"))))))

(ert-deftest my-codex-top-sort-refreshes-custom-header ()
  (with-temp-buffer
    (my-codex-top-mode)
    (setq tabulated-list-entries
          '((one ["b" "" "" "" "" "" "" "" "" "" "" "" "" ""])
            (two ["a" "" "" "" "" "" "" "" "" "" "" "" "" ""])))
    (tabulated-list-print)
    (should (eq (command-remapping 'tabulated-list-sort)
                #'my-codex-top-sort))
    (my-codex-top-sort 0)
    (should (eq (caar tabulated-list-entries) 'two))
    (should (eq (car header-line-format) ""))
    (should (memq 'header-line-indent header-line-format))))

(ert-deftest my-codex-top-mouse-sort-refreshes-custom-header ()
  (with-temp-buffer
    (my-codex-top-mode)
    (save-window-excursion
      (let ((window (selected-window)))
        (set-window-buffer window (current-buffer))
        (cl-letf (((symbol-function 'event-start) (lambda (_) 'position))
                  ((symbol-function 'posn-window) (lambda (_) window))
                  ((symbol-function 'tabulated-list-col-sort)
                   (lambda (_) (tabulated-list-init-header))))
          (my-codex-top-col-sort 'event))))
    (should (eq (lookup-key my-codex-top-sort-button-map
                            [header-line mouse-1])
                #'my-codex-top-col-sort))
    (should (eq (car header-line-format) ""))
    (should (memq 'header-line-indent header-line-format))))

(ert-deftest my-codex-top-column-resizing-refreshes-custom-header ()
  (with-temp-buffer
    (my-codex-top-mode)
    (setq tabulated-list-entries
          '((one ["project" "" "" "" "" "" "" "" "" "" "" "" "" ""])))
    (tabulated-list-print)
    (goto-char (point-min))
    (should (eq (command-remapping 'tabulated-list-widen-current-column)
                #'my-codex-top-widen-current-column))
    (should (eq (command-remapping 'tabulated-list-narrow-current-column)
                #'my-codex-top-narrow-current-column))
    (my-codex-top-widen-current-column 2)
    (should (= (cadr (aref tabulated-list-format 0)) 8))
    (should (eq (car header-line-format) ""))
    (my-codex-top-narrow-current-column 1)
    (should (= (cadr (aref tabulated-list-format 0)) 7))
    (should (eq (car header-line-format) ""))
    (should (memq 'header-line-indent header-line-format))))

(ert-deftest my-codex-top-git-info-reports-status-failure ()
  (cl-letf (((symbol-function 'my-codex--process-output-result)
             (lambda (_program &rest args)
               (if (member "branch" args)
                   '(0 "feature-x")
                 '(128)))))
    (should (equal (my-codex-top--git-info default-directory)
                   '("feature-x" . "error")))))

(ert-deftest my-codex-top-caches-git-info-by-project-root ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-top" t)))
        (first (get-buffer-create "*codex-top-cache-1*"))
        (second (get-buffer-create "*codex-top-cache-2*"))
        (calls 0))
    (unwind-protect
        (progn
          (my-codex--mark-named-session first "first" root 'read-only)
          (my-codex--mark-named-session second "second" root 'read-only)
          (cl-letf (((symbol-function 'my-codex--all-session-buffers)
                     (lambda () (list first second)))
                    ((symbol-function 'my-codex-top--git-info)
                     (lambda (_root)
                       (setq calls (1+ calls))
                       '("main" . "clean"))))
            (my-codex-top--make-entries)
            (should (= calls 1))))
      (delete-directory root t)
      (kill-buffer first)
      (kill-buffer second))))

(ert-deftest my-codex-top-marks-the-project-active-session ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-top" t)))
        (session (get-buffer-create "*codex-top-active*"))
        (my-codex--project-active-sessions
         (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (my-codex--mark-named-session session "active" root 'read-only)
          (my-codex--set-active-session session)
          (cl-letf (((symbol-function 'my-codex--all-session-buffers)
                     (lambda () (list session)))
                    ((symbol-function 'my-codex-top--cached-git-info)
                     (lambda (_root) '("main" . "clean"))))
            (should (equal (aref (cadar (my-codex-top--make-entries)) 0)
                           "*"))))
      (delete-directory root t)
      (when (buffer-live-p session) (kill-buffer session)))))

(ert-deftest my-codex-top-labels-session-with-removed-agent-profile ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-top" t)))
        (session (get-buffer-create "*codex-top-removed-agent*")))
    (unwind-protect
        (progn
          (my-codex--mark-named-session session "legacy" root 'read-only)
          (with-current-buffer session
            (setq-local my-codex-session-agent 'legacy-agent))
          (let ((my-codex-agent-profiles nil))
            (cl-letf (((symbol-function 'my-codex--all-session-buffers)
                       (lambda () (list session)))
                      ((symbol-function 'my-codex-top--cached-git-info)
                       (lambda (_root) '("main" . "clean"))))
              (should
               (equal (aref (cadar (my-codex-top--make-entries)) 1)
                      "legacy-agent")))))
      (delete-directory root t)
      (when (buffer-live-p session) (kill-buffer session)))))

(ert-deftest my-codex-top-reuses-git-info-across-refreshes ()
  (let ((my-codex-top--git-cache (make-hash-table :test #'equal))
        (my-codex-top-git-cache-ttl 5)
        (calls 0))
    (cl-letf (((symbol-function 'float-time) (lambda (&optional _) 10.0))
              ((symbol-function 'my-codex-top--git-info)
               (lambda (_root)
                 (setq calls (1+ calls))
                 '("main" . "clean"))))
      (my-codex-top--cached-git-info "/project/")
      (my-codex-top--cached-git-info "/project/")
      (should (= calls 1)))))

(ert-deftest my-codex-top-git-cache-expires ()
  (let ((my-codex-top--git-cache (make-hash-table :test #'equal))
        (my-codex-top-git-cache-ttl 5)
        (now 10.0)
        (calls 0))
    (cl-letf (((symbol-function 'float-time) (lambda (&optional _) now))
              ((symbol-function 'my-codex-top--git-info)
               (lambda (_root)
                 (setq calls (1+ calls))
                 (cons (number-to-string calls) "clean"))))
      (my-codex-top--cached-git-info "/project/")
      (setq now 15.0)
      (should (equal (my-codex-top--cached-git-info "/project/")
                     '("2" . "clean"))))))

(ert-deftest my-codex-top-kill-dead-sessions-preserves-live-buffers ()
  (let ((live (get-buffer-create "*codex-top-live*"))
        (dead (get-buffer-create "*codex-top-dead*")))
    (unwind-protect
        (cl-letf (((symbol-function 'my-codex--all-session-buffers)
                   (lambda () (list live dead)))
                  ((symbol-function 'my-codex--session-buffer-live-p)
                   (lambda (buffer) (eq buffer live)))
                  ((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                  ((symbol-function 'revert-buffer) #'ignore))
          (my-codex-top-kill-dead-sessions)
          (should (buffer-live-p live))
          (should-not (buffer-live-p dead)))
      (when (buffer-live-p live) (kill-buffer live))
      (when (buffer-live-p dead) (kill-buffer dead)))))

(ert-deftest my-codex-top-rename-session-refreshes-session-title ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-top" t)))
        (session-buffer (get-buffer-create "*codex-top-rename*"))
        collision-buffer)
    (unwind-protect
        (progn
          (my-codex--mark-named-session
           session-buffer "before" root 'workspace-write)
          (setq collision-buffer
                (get-buffer-create
                 (with-current-buffer session-buffer
                   (my-codex-session-buffer-name
                    "after" my-codex-session-agent))))
          (cl-letf (((symbol-function 'get-buffer-process)
                       (lambda (buffer)
                         (eq buffer session-buffer)))
                      ((symbol-function 'process-live-p)
                       (lambda (process) process))
                      ((symbol-function 'process-id)
                       (lambda (_) 9999))
                      ((symbol-function 'my-codex--process-output-lines)
                       (lambda (&rest _) nil))
                      ((symbol-function 'pop-to-buffer) #'ignore)
                      ((symbol-function 'read-string)
                       (lambda (&rest _) "after")))
              (my-codex-top)
              (with-current-buffer "*Agents Top*"
                (goto-char (point-min))
                (search-forward "*codex-top-rename*")
                (beginning-of-line)
                (my-codex-top-rename-session)))
          (should (string-suffix-p "<2>" (buffer-name session-buffer)))
          (with-current-buffer session-buffer
            (should (equal my-codex-session-name "after"))
            (should (string-match-p "Codex · WORKSPACE WRITE · after"
                                    header-line-format))
            (let ((footer (my-codex--session-footer)))
              (should (string-match-p
                       (regexp-quote (directory-file-name
                                      (abbreviate-file-name root)))
                       footer))
              (should-not (string-match-p "WORKSPACE WRITE" footer))
              (should-not (string-match-p "\\(^\\| · \\)after\\( · \\|$\\)" footer))
              (should (string-match-p "idle" footer)))
            (should-not (memq 'mode-line-position mode-line-format))))
      (delete-directory root t)
      (when (buffer-live-p session-buffer)
        (kill-buffer session-buffer))
      (when (buffer-live-p collision-buffer)
        (kill-buffer collision-buffer))
      (when-let ((buffer (get-buffer "*Agents Top*")))
        (kill-buffer buffer)))))

(ert-deftest my-codex-top-rejects-renaming-default-session ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-default" t)))
        (session-buffer (get-buffer-create "*codex-default-rename*")))
    (unwind-protect
        (progn
          (my-codex--mark-default-session session-buffer root 'read-only)
          (cl-letf (((symbol-function 'tabulated-list-get-id)
                     (lambda () (buffer-name session-buffer))))
            (should-error (my-codex-top-rename-session)
                          :type 'user-error)))
      (delete-directory root t)
      (when (buffer-live-p session-buffer)
        (kill-buffer session-buffer)))))

(ert-deftest my-codex-top-visit-edit-window-selects-associated-window ()
  (let ((session-buffer (get-buffer-create "*codex-top-edit*"))
        dashboard-window)
    (unwind-protect
        (let ((edit-window (selected-window)))
          (setq dashboard-window (split-window-right))
          (set-window-parameter
           edit-window 'my-codex-term-buffer session-buffer)
          (set-window-buffer dashboard-window (get-buffer-create "*Agents Top*"))
          (with-current-buffer "*Agents Top*"
            (my-codex-top-mode)
            (setq tabulated-list-entries
                  `((,(buffer-name session-buffer)
                     ["" "" "project" "session" ,(buffer-name session-buffer)
                      "" "" "" "" "" "" "" "" ""])))
            (tabulated-list-print)
            (goto-char (point-min))
            (search-forward (buffer-name session-buffer))
            (beginning-of-line))
          (select-window dashboard-window)
          (my-codex-top-visit-edit-window)
          (should (eq (selected-window) edit-window)))
      (when (window-live-p dashboard-window)
        (delete-window dashboard-window))
      (when (buffer-live-p session-buffer)
        (kill-buffer session-buffer))
      (when-let ((buffer (get-buffer "*Agents Top*")))
        (kill-buffer buffer)))))

(ert-deftest my-codex-top-visit-edit-window-searches-all-frames ()
  (let ((session-buffer (get-buffer-create "*codex-top-other-frame*"))
        (edit-window (selected-window)))
    (unwind-protect
        (progn
          (set-window-parameter
           edit-window 'my-codex-term-buffer session-buffer)
          (with-temp-buffer
            (my-codex-top-mode)
            (setq tabulated-list-entries
                  `((,(buffer-name session-buffer)
                     ["" "" "project" "session" ,(buffer-name session-buffer)
                      "" "" "" "" "" "" "" "" ""])))
            (tabulated-list-print)
            (goto-char (point-min))
            (search-forward (buffer-name session-buffer))
            (beginning-of-line)
            (cl-letf (((symbol-function 'frame-list)
                       (lambda () '(dashboard-frame edit-frame)))
                      ((symbol-function 'window-list)
                       (lambda (frame &rest _)
                         (and (eq frame 'edit-frame)
                              (list edit-window)))))
              (my-codex-top-visit-edit-window)
              (should (eq (selected-window) edit-window)))))
      (set-window-parameter edit-window 'my-codex-term-buffer nil)
      (kill-buffer session-buffer))))

(ert-deftest my-codex-edit-windows-for-session-buffer-stays-frame-local ()
  (let ((session-buffer (get-buffer-create "*codex-frame-local*"))
        (edit-window (selected-window)))
    (unwind-protect
        (progn
          (set-window-parameter
           edit-window 'my-codex-term-buffer session-buffer)
          (cl-letf (((symbol-function 'window-list)
                     (lambda (frame &rest _)
                       (and (eq frame 'other-frame)
                            (list edit-window)))))
            (should-not
             (my-codex--edit-windows-for-session-buffer session-buffer))))
      (set-window-parameter edit-window 'my-codex-term-buffer nil)
      (kill-buffer session-buffer))))

(ert-deftest my-codex-top-visit-edit-window-requires-association ()
  (let ((session-buffer (get-buffer-create "*codex-top-no-edit*")))
    (unwind-protect
        (with-temp-buffer
          (my-codex-top-mode)
          (setq tabulated-list-entries
                `((,(buffer-name session-buffer)
                   ["" "" "project" "session" ,(buffer-name session-buffer)
                    "" "" "" "" "" "" "" "" ""])))
          (tabulated-list-print)
          (goto-char (point-min))
          (search-forward (buffer-name session-buffer))
          (beginning-of-line)
          (should-error (my-codex-top-visit-edit-window)
                        :type 'user-error))
      (kill-buffer session-buffer))))

(ert-deftest my-codex-top-visit-switches-session-window ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-sessions" t)))
        (old-buffer (get-buffer-create "*codex-sessions-old*"))
        (session-buffer (get-buffer-create "*codex-sessions-select*"))
        term-window)
    (unwind-protect
        (let ((edit-window (selected-window)))
          (setq term-window (split-window-right))
          (set-window-buffer term-window old-buffer)
          (set-window-parameter
           edit-window 'my-codex-term-buffer old-buffer)
          (my-codex--mark-named-session
           old-buffer "old" root 'workspace-write)
          (my-codex--mark-named-session
           session-buffer "plan" root 'read-only)
          (cl-letf (((symbol-function 'get-buffer-process)
                     (lambda (buffer)
                       (memq buffer (list old-buffer session-buffer))))
                    ((symbol-function 'process-live-p)
                     (lambda (process) process))
                    ((symbol-function 'process-id) (lambda (_) 9999))
                    ((symbol-function 'my-codex--process-output-lines)
                     (lambda (&rest _) nil))
                    ((symbol-function 'pop-to-buffer)
                     (lambda (buffer-or-name &rest _args)
                       (set-window-buffer
                        (selected-window)
                        (get-buffer buffer-or-name))
                       (selected-window))))
            (my-codex-top)
            (with-current-buffer "*Agents Top*"
              (goto-char (point-min))
              (search-forward "*codex-sessions-select*")
              (beginning-of-line)
              (my-codex-top-visit))
            (should (eq (window-buffer term-window) session-buffer))
            (should (eq (selected-window) term-window))
            (should
             (eq (window-parameter edit-window 'my-codex-term-buffer)
                 session-buffer))))
      (delete-directory root t)
      (when (window-live-p term-window)
        (delete-window term-window))
      (when (buffer-live-p old-buffer)
        (kill-buffer old-buffer))
      (when (buffer-live-p session-buffer)
        (kill-buffer session-buffer))
      (when-let ((buffer (get-buffer "*Agents Top*")))
        (kill-buffer buffer)))))

(ert-deftest my-codex-top-visit-from-terminal-updates-edit-window ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-sessions" t)))
        (old-buffer (get-buffer-create "*codex-sessions-terminal-old*"))
        (session-buffer (get-buffer-create "*codex-sessions-terminal-new*"))
        term-window)
    (unwind-protect
        (let ((edit-window (selected-window)))
          (setq term-window (split-window-right))
          (set-window-buffer term-window old-buffer)
          (set-window-parameter
           edit-window 'my-codex-term-buffer old-buffer)
          (my-codex--mark-named-session
           old-buffer "old" root 'workspace-write)
          (my-codex--mark-named-session
           session-buffer "plan" root 'read-only)
          (select-window term-window)
          (cl-letf (((symbol-function 'get-buffer-process)
                     (lambda (buffer)
                       (memq buffer (list old-buffer session-buffer))))
                    ((symbol-function 'process-live-p)
                     (lambda (process) process))
                    ((symbol-function 'process-id) (lambda (_) 9999))
                    ((symbol-function 'my-codex--process-output-lines)
                     (lambda (&rest _) nil))
                    ((symbol-function 'pop-to-buffer) #'ignore))
            (my-codex-top)
            (with-current-buffer "*Agents Top*"
              (goto-char (point-min))
              (search-forward "*codex-sessions-terminal-new*")
              (beginning-of-line)
              (my-codex-top-visit))
            (should (eq (window-buffer term-window) session-buffer))
            (should
             (eq (window-parameter edit-window 'my-codex-term-buffer)
                 session-buffer))
            (should-not
             (eq (window-parameter term-window 'my-codex-term-buffer)
                 session-buffer))))
      (delete-directory root t)
      (when (window-live-p term-window)
        (delete-window term-window))
      (when (buffer-live-p old-buffer)
        (kill-buffer old-buffer))
      (when (buffer-live-p session-buffer)
        (kill-buffer session-buffer))
      (when-let ((buffer (get-buffer "*Agents Top*")))
        (kill-buffer buffer)))))

(ert-deftest my-codex-default-session-commands-use-selected-agent ()
  (let (called)
    (cl-letf (((symbol-function 'my-codex-two-column-layout-with-command)
               (lambda (command focus-term session-name agent access-mode)
                 (setq called
                       (list command focus-term session-name
                             agent access-mode)))))
      (my-codex-default-read-only 'antigravity)
      (should
       (equal called
              (list (my-codex--agent-command 'antigravity 'read-only)
                    nil nil 'antigravity 'read-only))))
    (cl-letf (((symbol-function 'my-codex-two-column-layout-with-command)
               (lambda (command focus-term session-name agent access-mode)
                 (setq called
                       (list command focus-term session-name
                             agent access-mode)))))
      (my-codex-default-workspace 'antigravity)
      (should
       (equal called
              (list (my-codex--agent-command
                     'antigravity 'workspace-write)
                    nil nil 'antigravity 'workspace-write))))))

(ert-deftest my-codex-default-session-layout-records-active-agent ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-active" t))))
    (unwind-protect
        (let ((default-directory root)
              (my-codex-agent 'codex)
              (my-codex--project-active-agents
               (make-hash-table :test #'equal)))
          (cl-letf (((symbol-function 'my-codex--fit-frame-to-right-layout)
                     #'ignore)
                    ((symbol-function 'my-codex--apply-display-window-width)
                     #'ignore)
                    ((symbol-function 'my-codex--resize-edit-window-for-right-layout)
                     #'ignore)
                    ((symbol-function 'my-codex--enable-edit-fill-column-indicator)
                     #'ignore)
                    ((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'my-codex-backend-start)
                     (lambda (&rest _args) nil))
                    ((symbol-function 'display-buffer)
                     (lambda (buf &rest _args)
                       (set-window-buffer (selected-window) buf)
                       (selected-window))))
            (my-codex-default-workspace 'antigravity)
            (should (eq (my-codex--active-agent root) 'antigravity))
            (should
             (string-match-p
              "\\`\\*agy:"
              (my-codex-current-buffer-name)))))
      (delete-directory root t))))

(ert-deftest my-codex-named-session-layout-starts-session-buffer ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-named" t)))
        started)
    (unwind-protect
        (let ((default-directory root))
          (cl-letf (((symbol-function 'my-codex--fit-frame-to-right-layout)
                     #'ignore)
                    ((symbol-function 'my-codex--apply-display-window-width)
                     #'ignore)
                    ((symbol-function 'my-codex--resize-edit-window-for-right-layout)
                     #'ignore)
                    ((symbol-function 'my-codex--enable-edit-fill-column-indicator)
                     #'ignore)
                    ((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'my-codex-backend-start)
                     (lambda (backend project-root command
                              &optional session-name agent access-mode)
                       (setq started
                             (list
                              (my-codex--backend-buffer-name backend)
                              project-root command session-name
                              agent access-mode))))
                    ((symbol-function 'display-buffer)
                     (lambda (buf &rest _args)
                       (set-window-buffer (selected-window) buf)
                       (selected-window))))
            (my-codex-two-column-layout-with-command
             (my-codex--agent-command 'codex 'read-only) nil "plan")
            (should (equal (nth 1 started) root))
            (should
             (equal (nth 2 started)
                    (my-codex--agent-command 'codex 'read-only)))
            (should (equal (nth 3 started) "plan"))
            (should (eq (nth 4 started) 'codex))
            (should-not (nth 5 started))
            (should
             (string-match-p ":plan-[[:xdigit:]]\\{8\\}\\*\\'"
                             (car started)))))
      (delete-directory root t))))

(ert-deftest my-codex-named-session-layout-starts-selected-agent-buffer ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-named" t)))
        started)
    (unwind-protect
        (let ((default-directory root))
          (cl-letf (((symbol-function 'my-codex--fit-frame-to-right-layout)
                     #'ignore)
                    ((symbol-function 'my-codex--apply-display-window-width)
                     #'ignore)
                    ((symbol-function 'my-codex--resize-edit-window-for-right-layout)
                     #'ignore)
                    ((symbol-function 'my-codex--enable-edit-fill-column-indicator)
                     #'ignore)
                    ((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'my-codex-backend-start)
                     (lambda (backend project-root command
                              &optional session-name agent access-mode)
                       (setq started
                             (list
                              (my-codex--backend-buffer-name backend)
                              project-root command session-name
                              agent access-mode))))
                    ((symbol-function 'display-buffer)
                     (lambda (buf &rest _args)
                       (set-window-buffer (selected-window) buf)
                       (selected-window))))
            (my-codex-new-session "plan" 'antigravity 'workspace-write)
            (should (equal (nth 1 started) root))
            (should (equal (nth 2 started) "agy"))
            (should (equal (nth 3 started) "plan"))
            (should (eq (nth 4 started) 'antigravity))
            (should (eq (nth 5 started) 'workspace-write))
            (should
             (string-match-p "\\`\\*agy:.*:plan-[[:xdigit:]]\\{8\\}\\*\\'"
                             (car started)))))
      (delete-directory root t))))

(ert-deftest my-codex-new-session-from-handoff-starts-fresh-session ()
  (let* ((root (file-name-as-directory (make-temp-file "my-codex-handoff" t)))
         (source (get-buffer-create "*codex-handoff-source*"))
         requested started sent)
    (unwind-protect
        (let ((default-directory root))
          (my-codex--mark-default-session source root 'read-only)
          (cl-letf (((symbol-function 'my-codex-active-session-buffer)
                     (lambda (&optional _require-live) source))
                    ((symbol-function 'my-codex--request-marked-output)
                     (lambda (&rest args)
                       (setq requested args)
                       (funcall (plist-get args :callback) "# Handoff\n\nNext step.")))
                    ((symbol-function 'my-codex-new-session)
                     (lambda (name agent access-mode)
                       (setq started (list name agent access-mode))
                       (get-buffer-create
                        (my-codex-session-buffer-name name agent))))
                    ((symbol-function 'my-codex-send-prompt)
                     (lambda (prompt buffer)
                       (setq sent (list prompt (buffer-name buffer))))))
            (my-codex-new-session-from-handoff
             "follow-up" 'antigravity 'workspace-write)
            (should (equal (plist-get requested :name) "SESSION_HANDOFF"))
            (should (eq (plist-get requested :timer-var)
                        'my-codex--handoff-wait-timer))
            (should (equal started
                           '("follow-up" antigravity workspace-write)))
            (should (equal (car sent) "# Handoff\n\nNext step."))
            (should (equal (cadr sent)
                           (my-codex-session-buffer-name
                            "follow-up" 'antigravity)))))
      (when (buffer-live-p source)
        (kill-buffer source))
      (when-let ((target (get-buffer
                          (let ((default-directory root))
                            (my-codex-session-buffer-name
                             "follow-up" 'antigravity)))))
        (kill-buffer target))
      (delete-directory root t))))

(ert-deftest my-codex-new-session-from-handoff-rechecks-freshness ()
  (let* ((root (file-name-as-directory (make-temp-file "my-codex-handoff" t)))
         (source (get-buffer-create "*codex-handoff-source*"))
         callback target started sent)
    (unwind-protect
        (let ((default-directory root))
          (my-codex--mark-default-session source root 'read-only)
          (cl-letf (((symbol-function 'my-codex-active-session-buffer)
                     (lambda (&optional _require-live) source))
                    ((symbol-function 'my-codex--request-marked-output)
                     (lambda (&rest args)
                       (setq callback (plist-get args :callback))))
                    ((symbol-function 'my-codex-new-session)
                     (lambda (&rest _) (setq started t)))
                    ((symbol-function 'my-codex-send-prompt)
                     (lambda (&rest _) (setq sent t))))
            (my-codex-new-session-from-handoff
             "raced" 'codex 'read-only)
            (setq target
                  (get-buffer-create
                   (my-codex-session-buffer-name "raced" 'codex)))
            (should-error (funcall callback "# Handoff") :type 'user-error)
            (should-not started)
            (should-not sent)))
      (when (buffer-live-p source)
        (kill-buffer source))
      (when (buffer-live-p target)
        (kill-buffer target))
      (delete-directory root t))))

(ert-deftest my-codex-new-session-from-handoff-rejects-existing-session ()
  (let* ((root (file-name-as-directory (make-temp-file "my-codex-handoff" t)))
         (source (get-buffer-create "*codex-handoff-source*"))
         target)
    (unwind-protect
        (let ((default-directory root))
          (my-codex--mark-default-session source root 'read-only)
          (setq target
                (get-buffer-create
                 (my-codex-session-buffer-name "existing" 'codex)))
          (cl-letf (((symbol-function 'my-codex-active-session-buffer)
                     (lambda (&optional _require-live) source)))
            (should-error
             (my-codex-new-session-from-handoff
              "existing" 'codex 'read-only)
             :type 'user-error)))
      (when (buffer-live-p source)
        (kill-buffer source))
      (when (buffer-live-p target)
        (kill-buffer target))
      (delete-directory root t))))

(ert-deftest my-codex-new-session-from-handoff-rejects-concurrent-handoff ()
  (let* ((root (file-name-as-directory (make-temp-file "my-codex-handoff" t)))
         (source (get-buffer-create "*codex-handoff-source*"))
         timer)
    (unwind-protect
        (let ((default-directory root))
          (my-codex--mark-default-session source root 'read-only)
          (setq timer (run-with-timer 60 nil #'ignore))
          (with-current-buffer source
            (setq-local my-codex--handoff-wait-timer timer))
          (cl-letf (((symbol-function 'my-codex-active-session-buffer)
                     (lambda (&optional _require-live) source)))
            (should-error
             (my-codex-new-session-from-handoff
              "second" 'codex 'read-only)
             :type 'user-error)))
      (when (timerp timer)
        (cancel-timer timer))
      (when (buffer-live-p source)
        (kill-buffer source))
      (delete-directory root t))))

(ert-deftest my-codex-hide-window-hides-associated-session ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-hide" t)))
        (default-buffer (get-buffer-create "*codex-default-test*"))
        (session-buffer (get-buffer-create "*codex-session-test*"))
        term-window
        hidden)
    (unwind-protect
        (let ((default-directory root)
              (edit-window (selected-window)))
          (my-codex--mark-default-session default-buffer root 'workspace-write)
          (my-codex--mark-named-session
           session-buffer "review" root 'workspace-write)
          (setq term-window (split-window-right))
          (set-window-buffer term-window session-buffer)
          (set-window-parameter
           edit-window 'my-codex-term-buffer session-buffer)
          (select-window edit-window)
          (cl-letf (((symbol-function 'my-codex-current-buffer-name)
                     (lambda () (buffer-name default-buffer)))
                    ((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'quit-window)
                     (lambda (&optional _kill window)
                       (setq hidden (window-buffer window)))))
            (my-codex-hide-window)
            (should (eq hidden session-buffer))))
      (set-window-parameter
       (selected-window) 'my-codex-term-buffer nil)
      (when (window-live-p term-window)
        (delete-window term-window))
      (kill-buffer default-buffer)
      (kill-buffer session-buffer)
      (delete-directory root t))))

(ert-deftest my-codex-reused-live-buffer-preserves-session-metadata ()
  (let ((root-a (file-name-as-directory (make-temp-file "my-codex-a" t)))
        (root-b (file-name-as-directory (make-temp-file "my-codex-b" t)))
        (buffer-name "*codex-shared-test*"))
    (unwind-protect
        (let ((buffer (get-buffer-create buffer-name))
              (my-codex-buffer-name buffer-name))
          (my-codex--mark-default-session buffer root-a 'read-only)
          (let ((expected-id (with-current-buffer buffer my-codex-session-id))
                (expected-root
                 (with-current-buffer buffer my-codex-session-project-root)))
            (let ((default-directory root-b))
              (cl-letf (((symbol-function 'my-codex--fit-frame-to-right-layout)
                         #'ignore)
                        ((symbol-function 'my-codex--apply-display-window-width)
                         #'ignore)
                        ((symbol-function 'my-codex--resize-edit-window-for-right-layout)
                         #'ignore)
                        ((symbol-function 'my-codex--enable-edit-fill-column-indicator)
                         #'ignore)
                        ((symbol-function 'my-codex-project-root)
                         (lambda () root-b))
                        ((symbol-function 'my-codex-current-buffer-name)
                         (lambda (&optional _agent) buffer-name))
                        ((symbol-function 'my-codex-backend-live-p)
                         (lambda (_backend) t))
                        ((symbol-function 'my-codex-backend-start)
                         (lambda (&rest _args)
                           (error "Should not restart a live buffer")))
                        ((symbol-function 'display-buffer)
                         (lambda (buf &rest _args)
                           (set-window-buffer (selected-window) buf)
                           (selected-window))))
                (my-codex-two-column-layout-with-command
                 (my-codex--agent-command 'codex 'workspace-write))))
            (with-current-buffer buffer
              (should (equal my-codex-session-id expected-id))
              (should (equal my-codex-session-project-root expected-root))
              (should (eq my-codex-session-access-mode 'read-only)))))
      (when-let ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer))
      (delete-directory root-a t)
      (delete-directory root-b t))))

(defmacro my-codex-test-with-vterm-shell (shell &rest body)
  "Bind `vterm-shell' to SHELL while running BODY."
  (declare (indent 1))
  `(let ((was-bound (boundp 'vterm-shell))
         (original-value (and (boundp 'vterm-shell)
                              (symbol-value 'vterm-shell))))
     (unwind-protect
         (progn
           (set 'vterm-shell ,shell)
           ,@body)
       (if was-bound
           (set 'vterm-shell original-value)
         (makunbound 'vterm-shell)))))

(ert-deftest my-codex-shell-command-and-exit-uses-posix-status ()
  (my-codex-test-with-vterm-shell "/bin/bash"
    (should
     (equal
      (my-codex--shell-command-and-exit "codex")
      "codex\nstatus=$?\nexit $status"))))

(ert-deftest my-codex-shell-command-and-exit-uses-cmd-errorlevel ()
  (my-codex-test-with-vterm-shell "C:\\Windows\\System32\\cmd.exe"
    (should
     (equal
      (my-codex--shell-command-and-exit "codex")
      "codex\nexit %ERRORLEVEL%"))))

(ert-deftest my-codex-shell-command-and-exit-uses-powershell-status ()
  (my-codex-test-with-vterm-shell "C:\\Program Files\\PowerShell\\7\\pwsh.exe"
    (should
     (equal
      (my-codex--shell-command-and-exit "codex")
      (concat "codex\n"
              "if ($LASTEXITCODE -ne $null) { exit $LASTEXITCODE }\n"
              "if ($?) { exit 0 } else { exit 1 }")))))

(ert-deftest my-codex-ensure-vterm-scrollback-raises-low-value-locally ()
  (let ((was-bound (boundp 'vterm-max-scrollback))
        (original-value (and (boundp 'vterm-max-scrollback)
                             (symbol-value 'vterm-max-scrollback)))
        (my-codex-vterm-min-scrollback 10000))
    (unwind-protect
        (progn
          (set 'vterm-max-scrollback 100)
          (with-temp-buffer
            (my-codex--ensure-vterm-scrollback)
            (should (equal vterm-max-scrollback 10000))
            (should (local-variable-p 'vterm-max-scrollback))))
      (if was-bound
          (set 'vterm-max-scrollback original-value)
        (makunbound 'vterm-max-scrollback)))))

(ert-deftest my-codex-ensure-vterm-scrollback-preserves-higher-value ()
  (let ((was-bound (boundp 'vterm-max-scrollback))
        (original-value (and (boundp 'vterm-max-scrollback)
                             (symbol-value 'vterm-max-scrollback)))
        (my-codex-vterm-min-scrollback 10000))
    (unwind-protect
        (progn
          (set 'vterm-max-scrollback 20000)
          (with-temp-buffer
            (my-codex--ensure-vterm-scrollback)
            (should (equal vterm-max-scrollback 20000))
            (should-not (local-variable-p 'vterm-max-scrollback))))
      (if was-bound
          (set 'vterm-max-scrollback original-value)
        (makunbound 'vterm-max-scrollback)))))

(ert-deftest my-codex-vterm-scrollback-floor-raises-low-value ()
  (let ((my-codex-vterm-min-scrollback 10000))
    (should (equal (my-codex--vterm-scrollback-floor 100) 10000))))

(ert-deftest my-codex-vterm-mode-with-scrollback-floor-floors-vterm-new-arg ()
  (let ((my-codex-vterm-min-scrollback 10000)
        captured-scrollback)
    (cl-letf (((symbol-function 'require) #'ignore)
              ((symbol-function 'vterm-mode)
               (lambda ()
                 (vterm--new 24 80 100 nil nil nil nil nil nil)))
              ((symbol-function 'vterm--new)
               (lambda (_height _width scrollback &rest _args)
                 (setq captured-scrollback scrollback))))
      (my-codex--vterm-mode-with-scrollback-floor)
      (should (equal captured-scrollback 10000)))))

(ert-deftest my-codex-vterm-integration-does-not-mutate-vterm-keymaps ()
  (let* ((vterm-mode-map (make-sparse-keymap))
         (vterm-copy-mode-map (make-sparse-keymap))
         (vterm-mode-hook nil)
         (vterm-copy-mode-hook nil)
         (after-change-major-mode-hook nil)
         (my-codex--vterm-copy-mode-lighter :unset))
    (keymap-set vterm-mode-map "<f8>" #'ignore)
    (keymap-set vterm-copy-mode-map "<f8>" #'ignore)
    (my-codex--enable-vterm-integration)
    (keymap-set vterm-mode-map "<f8>" #'next-line)
    (keymap-set vterm-copy-mode-map "<f8>" #'previous-line)
    (my-codex--disable-vterm-integration)
    (should (eq (keymap-lookup vterm-mode-map "<f8>") #'next-line))
    (should (eq (keymap-lookup vterm-copy-mode-map "<f8>") #'previous-line))))

(ert-deftest my-codex-vterm-override-mode-provides-local-keys ()
  (let ((copy-map (make-sparse-keymap))
        (vterm-copy-mode t))
    (keymap-set copy-map "<f8>" #'ignore)
    (with-temp-buffer
      (let ((major-mode 'vterm-mode)
            (my-codex-session-id "test-session")
            (minor-mode-map-alist
             (cons (cons 'vterm-copy-mode copy-map) minor-mode-map-alist)))
        (unwind-protect
            (progn
              (my-codex--enable-vterm-buffer-integration)
              (should (bound-and-true-p my-codex-vterm-override-mode))
              (should (eq (key-binding (kbd "<f8>"))
                          #'my-codex-transient-preserve-selection))
              (should (eq (key-binding (kbd "S-<insert>"))
                          #'vterm-yank)))
          (my-codex--disable-vterm-buffer-integration))))))

(ert-deftest my-codex-vterm-integration-ignores-non-agent-vterms ()
  (with-temp-buffer
    (let ((major-mode 'vterm-mode)
          (company-mode t)
          (flyspell-mode t)
          (display-line-numbers-mode t)
          (vterm-copy-mode-hook nil))
      (my-codex--enable-vterm-buffer-integration)
      (should-not (bound-and-true-p my-codex-vterm-override-mode))
      (should company-mode)
      (should flyspell-mode)
      (should display-line-numbers-mode)
      (should-not (local-variable-p 'vterm-copy-mode-hook)))))

(ert-deftest my-codex-vterm-copy-mode-hook-is-buffer-local ()
  (let ((vterm-copy-mode-hook nil))
    (with-temp-buffer
      (let ((major-mode 'vterm-mode)
            (my-codex-session-id "test-session"))
        (my-codex--enable-vterm-buffer-integration)
        (should (local-variable-p 'vterm-copy-mode-hook))
        (should (memq #'my-codex--vterm-copy-mode-header-line
                      vterm-copy-mode-hook))))
    (should-not vterm-copy-mode-hook)))

(ert-deftest my-codex-does-not-prebind-vterm-shell ()
  (let* ((script '(progn
                    (setq load-prefer-newer t)
                    (package-initialize)
                    (require 'my-codex)
                    (require 'vterm)
                    (princ vterm-shell)))
         (output
          (with-temp-buffer
            (let ((exit-code
                   (call-process invocation-name nil t nil
                                 "--batch" "-Q" "-L" default-directory
                                 "--eval" (prin1-to-string script))))
              (unless (zerop exit-code)
                (error "Nested Emacs failed: %s" (buffer-string)))
              (buffer-string)))))
    (should (equal output shell-file-name))))

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

(ert-deftest my-codex-show-git-diff-populates-diff-mode-buffer ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-diff" t))))
    (let ((default-directory root))
      (my-codex-test--init-git-repository)
      (my-codex-test--write-file "tracked.txt" "old\n")
      (should (eq 0 (process-file "git" nil nil nil "add" "--" "tracked.txt")))
      (my-codex-test--write-file "tracked.txt" "new\n")
      (let ((buffer-name (my-codex--git-diff-buffer-name root nil)))
        (unwind-protect
            (cl-letf (((symbol-function 'my-codex-project-root)
                       (lambda () root))
                      ((symbol-function 'display-buffer)
                       (lambda (buffer &rest _args) buffer)))
              (my-codex-show-git-diff)
              (with-current-buffer buffer-name
                (should (derived-mode-p 'diff-mode))
                (should buffer-read-only)
                (should (equal default-directory root))
                (should (string-match-p "^-old" (buffer-string)))
                (should (string-match-p "^\\+new" (buffer-string)))))
          (when-let ((buffer (get-buffer buffer-name)))
            (kill-buffer buffer)))))))

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

(ert-deftest my-codex-prompt-preset-transient-suffixes-empty-keeps-chooser ()
  (let* ((my-codex-prompt-presets nil)
         (suffixes (my-codex--prompt-preset-transient-suffixes nil))
         (choose-suffix (cadr suffixes))
         (properties (nth 2 choose-suffix)))
    (should (equal (car suffixes) ""))
    (should
     (equal (plist-get properties :description)
            "Choose by name"))
    (should (eq (plist-get properties :command)
                'my-codex-ask-with-preset))
    (should-not
     (seq-some (lambda (suffix)
                 (and (consp suffix)
                      (eq (plist-get (nth 2 suffix) :command) 'ignore)))
               suffixes))))

(ert-deftest my-codex-prompt-preset-transient-suffixes-show-default-presets ()
  (let* ((my-codex-prompt-presets
          '(("Refactor" . "Refactor prompt")
            ("Document" . "Document prompt")))
         (suffixes (my-codex--prompt-preset-transient-suffixes nil))
         (first-properties (nth 2 (car suffixes)))
         (second-properties (nth 2 (cadr suffixes))))
    (should (equal (plist-get first-properties :key) "1"))
    (should (equal (plist-get first-properties :description) "Refactor"))
    (should (eq (plist-get first-properties :command)
                'my-codex--ask-with-transient-preset-0))
    (should (equal (plist-get second-properties :key) "2"))
    (should (equal (plist-get second-properties :description) "Document"))
    (should (eq (plist-get second-properties :command)
                'my-codex--ask-with-transient-preset-1))
    (should (equal my-codex--prompt-preset-transient-presets
                   my-codex-prompt-presets))))

(ert-deftest my-codex-prompt-preset-transient-installs-live-suffixes ()
  (let ((my-codex-prompt-presets '(("Refactor" . "Refactor prompt"))))
    (transient-setup 'my-codex-ask-preset-transient)
    (unwind-protect
        (let ((preset-suffix
               (seq-find
                (lambda (suffix)
                  (and (slot-exists-p suffix 'command)
                       (eq (oref suffix command)
                           'my-codex--ask-with-transient-preset-0)))
                transient--suffixes)))
          (should preset-suffix)
          (should (equal (oref preset-suffix key) "1"))
          (should (equal (oref preset-suffix description) "Refactor")))
      (transient-quit-all))))

(ert-deftest my-codex-display-buffer-action-alist-returns-action-alist ()
  (let ((my-codex-display-buffer-action
         '((display-buffer-in-side-window)
           (side . right)
           (window-width . 80))))
    (should
     (equal (my-codex--display-buffer-action-alist)
            '((side . right)
              (window-width . 80))))))

(ert-deftest my-codex-display-buffer-action-alist-handles-functions ()
  (let ((my-codex-display-buffer-action #'display-buffer-same-window))
    (should-not (my-codex--display-buffer-action-alist))
    (should-not (my-codex--right-side-action-p))))

(ert-deftest my-codex-display-buffer-action-alist-handles-symbols ()
  (let ((my-codex-display-buffer-action 'display-buffer-same-window))
    (should-not (my-codex--display-buffer-action-alist))
    (should-not (my-codex--right-side-action-p))))

(ert-deftest my-codex-prompt-preview-header-shows-size ()
  (should
   (equal
    (my-codex--prompt-preview-header "abcde")
    (concat "Target: Codex / default. "
            "Size: 5 chars; outbound prompt text: approximately 2 tokens. "
            "Edit if needed; "
            "C-c C-c sends to agent, C-c C-k cancels."))))

(ert-deftest my-codex-prompt-preview-header-shows-target-session ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-preview" t)))
        (buffer (get-buffer-create "*my-codex-preview-target*")))
    (unwind-protect
        (progn
          (my-codex--mark-named-session
           buffer "plan" root 'workspace-write 'antigravity)
          (should
           (equal
            (my-codex--prompt-preview-header "abcde" buffer)
            (concat "Target: Antigravity / plan / WORKSPACE WRITE. "
                    "Size: 5 chars; outbound prompt text: approximately 2 tokens. "
                    "Edit if needed; "
                    "C-c C-c sends to agent, C-c C-k cancels."))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest my-codex-update-prompt-preview-header-tracks-edits ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-preview" t)))
        (target (get-buffer-create "*my-codex-preview-target*")))
    (unwind-protect
        (progn
          (my-codex--mark-default-session target root 'read-only)
          (with-temp-buffer
            (setq-local my-codex--prompt-preview-target-buffer target)
            (insert "abcde")
            (my-codex--update-prompt-preview-header)
            (add-hook 'after-change-functions
                      #'my-codex--update-prompt-preview-header nil t)
            (goto-char (point-max))
            (insert "fghi")
            (should
             (equal
              header-line-format
              (concat "Target: Codex / default / read-only [lock]. "
                      "Size: 9 chars; outbound prompt text: approximately 3 tokens. "
                      "Edit if needed; "
                      "C-c C-c sends to agent, C-c C-k cancels.")))))
      (when (buffer-live-p target)
        (kill-buffer target))
      (delete-directory root t))))

(ert-deftest my-codex-prompt-preview-highlights-references ()
  (with-temp-buffer
    (insert "Selected region:\n\n@my-codex-prompts.el lines 1-5\n")
    (text-mode)
    (my-codex--setup-prompt-preview-font-lock)
    (font-lock-ensure)
    (goto-char (point-min))
    (search-forward "@my-codex-prompts.el")
    (should
     (eq (get-text-property (match-beginning 0) 'face)
         'my-codex-prompt-preview-reference-face))))

(ert-deftest my-codex-prompt-preview-highlights-xref-locations ()
  (with-temp-buffer
    (insert "reference_context:\n  - location: \"my-codex.el:12\"\n")
    (text-mode)
    (my-codex--setup-prompt-preview-font-lock)
    (font-lock-ensure)
    (goto-char (point-min))
    (search-forward "my-codex.el")
    (should
     (eq (get-text-property (match-beginning 0) 'face)
         'my-codex-prompt-preview-reference-face))))

(ert-deftest my-codex-prompt-preview-highlights-embedded-literal-blocks ()
  (with-temp-buffer
    (insert "symbol_context:\n  excerpt: |\n    (message \"hello\")\nnext: value\n")
    (text-mode)
    (my-codex--setup-prompt-preview-font-lock)
    (font-lock-ensure)
    (goto-char (point-min))
    (search-forward "(message")
    (should
     (eq (get-text-property (match-beginning 0) 'face)
         'my-codex-prompt-preview-embedded-face))
    (search-forward "next")
    (should-not (get-text-property (match-beginning 0) 'face))))

(ert-deftest my-codex-prompt-preview-highlights-embedded-review-text ()
  (with-temp-buffer
    (insert "Context\n\nReview this code and report findings:\n\n(defun x () 1)\n")
    (text-mode)
    (my-codex--setup-prompt-preview-font-lock)
    (font-lock-ensure)
    (goto-char (point-min))
    (search-forward "(defun")
    (should
     (eq (get-text-property (match-beginning 0) 'face)
         'my-codex-prompt-preview-embedded-face))))

(ert-deftest my-codex-ask-prompt-label-shows-target-session ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-ask" t)))
        (target (get-buffer-create "*my-codex-ask-target*")))
    (unwind-protect
        (let ((default-directory root))
          (my-codex--mark-named-session
           target "review" root 'workspace-write 'antigravity)
          (set-window-parameter (selected-window) 'my-codex-term-buffer target)
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root)))
            (should
             (equal (my-codex--ask-prompt-label)
                    "Antigravity [review/WORKSPACE WRITE]"))))
      (set-window-parameter (selected-window) 'my-codex-term-buffer nil)
      (when (buffer-live-p target)
        (kill-buffer target))
      (delete-directory root t))))

(ert-deftest my-codex-ask-prompt-label-falls-back-without-session ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-ask" t))))
    (unwind-protect
        (let ((default-directory root))
          (set-window-parameter (selected-window) 'my-codex-term-buffer nil)
          (cl-letf (((symbol-function 'my-codex-buffer)
                     (lambda () (user-error "No buffer"))))
            (should (equal (my-codex--ask-prompt-label) "Codex"))))
      (set-window-parameter (selected-window) 'my-codex-term-buffer nil)
      (delete-directory root t))))

(ert-deftest my-codex-preview-and-send-prompt-preserves-target-without-preview ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-send" t)))
        (target (get-buffer-create "*my-codex-no-preview-target*"))
        (my-codex-enable-prompt-preview nil)
        sent)
    (unwind-protect
        (let ((default-directory root))
          (my-codex--mark-named-session
           target "review" root 'workspace-write 'antigravity)
          (set-window-parameter (selected-window) 'my-codex-term-buffer target)
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'my-codex-send-prompt)
                     (lambda (prompt &optional target-buffer)
                       (setq sent (list prompt target-buffer)))))
            (my-codex--preview-and-send-prompt "hello")
            (should (equal sent (list "hello" target)))))
      (set-window-parameter (selected-window) 'my-codex-term-buffer nil)
      (when (buffer-live-p target)
        (kill-buffer target))
      (delete-directory root t))))

(ert-deftest my-codex-send-prompt-uses-explicit-target-session ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-send" t)))
        (target (get-buffer-create "*my-codex-send-target*"))
        sent)
    (unwind-protect
        (progn
          (my-codex--mark-named-session
           target "review" root 'workspace-write 'antigravity)
          (cl-letf (((symbol-function 'my-codex--warn-about-unsaved-project-buffers)
                     #'ignore)
                    ((symbol-function 'get-buffer-process)
                     (lambda (buffer) (eq buffer target)))
                    ((symbol-function 'process-live-p)
                     (lambda (process) process))
                    ((symbol-function 'pop-to-buffer)
                     #'ignore)
                    ((symbol-function 'my-codex-backend-send)
                     (lambda (backend prompt)
                       (setq sent
                             (list (my-codex--backend-buffer-name backend)
                                   prompt)))))
            (my-codex-send-prompt "hello" target)
            (should
             (equal sent '("*my-codex-send-target*" "hello")))))
      (when (buffer-live-p target)
        (kill-buffer target))
      (delete-directory root t))))

(ert-deftest my-codex-active-session-buffer-uses-window-session ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-active" t)))
        (target (get-buffer-create "*my-codex-active-target*")))
    (unwind-protect
        (let ((default-directory root))
          (cl-letf (((symbol-function 'project-current)
                     (lambda (&rest _args) nil)))
            (my-codex--mark-named-session
             target "review" root 'workspace-write 'antigravity)
            (set-window-parameter (selected-window) 'my-codex-term-buffer target)
            (should (eq (my-codex-active-session-buffer) target))))
      (set-window-parameter (selected-window) 'my-codex-term-buffer nil)
      (when (buffer-live-p target)
        (kill-buffer target))
      (delete-directory root t))))

(ert-deftest my-codex-active-session-buffer-uses-remembered-session ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-active" t)))
        (target (get-buffer-create "*my-codex-active-remembered*"))
        (my-codex--project-active-sessions (make-hash-table :test #'equal)))
    (unwind-protect
        (let ((default-directory root))
          (cl-letf (((symbol-function 'project-current)
                     (lambda (&rest _args) nil)))
            (my-codex--mark-named-session
             target "review" root 'workspace-write 'antigravity)
            (my-codex--set-active-session target)
            (should (eq (my-codex-active-session-buffer) target))))
      (when (buffer-live-p target)
        (kill-buffer target))
      (delete-directory root t))))

(ert-deftest my-codex-active-session-buffer-prefers-window-to-remembered-session ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-active" t)))
        (remembered (get-buffer-create "*my-codex-active-remembered*"))
        (window-target (get-buffer-create "*my-codex-active-window*"))
        (my-codex--project-active-sessions (make-hash-table :test #'equal)))
    (unwind-protect
        (let ((default-directory root))
          (cl-letf (((symbol-function 'project-current)
                     (lambda (&rest _args) nil)))
            (my-codex--mark-named-session
             remembered "remembered" root 'workspace-write 'antigravity)
            (my-codex--mark-named-session
             window-target "window" root 'workspace-write 'antigravity)
            (my-codex--set-active-session remembered)
            (set-window-parameter
             (selected-window) 'my-codex-term-buffer window-target)
            (should (eq (my-codex-active-session-buffer) window-target))))
      (set-window-parameter (selected-window) 'my-codex-term-buffer nil)
      (dolist (buffer (list remembered window-target))
        (when (buffer-live-p buffer)
          (kill-buffer buffer)))
      (delete-directory root t))))

(ert-deftest my-codex-active-session-buffer-ignores-foreign-window-session ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-active" t)))
        (foreign-root
         (file-name-as-directory (make-temp-file "my-codex-foreign" t)))
        default-buffer
        (foreign-buffer (get-buffer-create "*my-codex-active-foreign*")))
    (unwind-protect
        (let ((default-directory root))
          (setq default-buffer
                (get-buffer-create (my-codex-current-buffer-name)))
          (my-codex--mark-default-session
           default-buffer root 'workspace-write)
          (my-codex--mark-named-session
           foreign-buffer "review" foreign-root 'workspace-write)
          (set-window-parameter
           (selected-window) 'my-codex-term-buffer foreign-buffer)
          (should (eq (my-codex-active-session-buffer) default-buffer)))
      (set-window-parameter (selected-window) 'my-codex-term-buffer nil)
      (when (buffer-live-p default-buffer)
        (kill-buffer default-buffer))
      (when (buffer-live-p foreign-buffer)
        (kill-buffer foreign-buffer))
      (delete-directory root t)
      (delete-directory foreign-root t))))

(ert-deftest my-codex-active-session-buffer-requires-live-process ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-active" t)))
        (target (get-buffer-create "*my-codex-active-live*")))
    (unwind-protect
        (let ((default-directory root))
          (my-codex--mark-named-session
           target "review" root 'workspace-write 'antigravity)
          (set-window-parameter (selected-window) 'my-codex-term-buffer target)
          (cl-letf (((symbol-function 'get-buffer-process)
                     (lambda (_buffer) nil)))
            (should-error
             (my-codex-active-session-buffer t)
             :type 'user-error)))
      (set-window-parameter (selected-window) 'my-codex-term-buffer nil)
      (when (buffer-live-p target)
        (kill-buffer target))
      (delete-directory root t))))

(ert-deftest my-codex-send-prompt-uses-active-session-by-default ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-send" t)))
        (target (get-buffer-create "*my-codex-send-active*"))
        sent)
    (unwind-protect
        (let ((default-directory root))
          (my-codex--mark-named-session
           target "review" root 'workspace-write 'antigravity)
          (set-window-parameter (selected-window) 'my-codex-term-buffer target)
          (cl-letf (((symbol-function 'project-current)
                     (lambda (&rest _args) nil))
                    ((symbol-function 'my-codex--warn-about-unsaved-project-buffers)
                     #'ignore)
                    ((symbol-function 'get-buffer-process)
                     (lambda (buffer) (eq buffer target)))
                    ((symbol-function 'process-live-p)
                     (lambda (process) process))
                    ((symbol-function 'pop-to-buffer)
                     #'ignore)
                    ((symbol-function 'my-codex-backend-send)
                     (lambda (backend prompt)
                       (setq sent
                             (list (my-codex--backend-buffer-name backend)
                                   prompt)))))
            (my-codex-send-prompt "hello")
            (should
             (equal sent '("*my-codex-send-active*" "hello")))))
      (set-window-parameter (selected-window) 'my-codex-term-buffer nil)
      (when (buffer-live-p target)
        (kill-buffer target))
      (delete-directory root t))))

(ert-deftest my-codex-check-prompt-size-allows-small-prompts ()
  (let ((my-codex-prompt-warning-tokens 10)
        (my-codex-prompt-error-tokens nil))
    (should-not (my-codex--check-prompt-size "small"))))

(ert-deftest my-codex-check-prompt-size-can-disable-warning ()
  (let ((my-codex-prompt-warning-tokens nil)
        (my-codex-prompt-error-tokens nil))
    (should-not (my-codex--check-prompt-size "this is large"))))

(ert-deftest my-codex-check-prompt-size-confirms-large-prompts ()
  (let ((my-codex-prompt-warning-tokens 4)
        (my-codex-prompt-error-tokens nil))
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (_prompt) t)))
      (should-not (my-codex--check-prompt-size "this is large")))))

(ert-deftest my-codex-check-prompt-size-cancels-large-prompts ()
  (let ((my-codex-prompt-warning-tokens 4)
        (my-codex-prompt-error-tokens nil))
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (_prompt) nil)))
      (should-error
       (my-codex--check-prompt-size "this is large")
       :type 'user-error))))

(ert-deftest my-codex-check-prompt-size-enforces-hard-limit ()
  (let ((my-codex-prompt-warning-tokens nil)
        (my-codex-prompt-error-tokens 4))
    (should-error
     (my-codex--check-prompt-size "this is large")
     :type 'user-error)))

(ert-deftest my-codex-session-links-linkifies-hard-wrapped-file-reference ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-links" t))))
    (unwind-protect
        (progn
          (make-directory
           (expand-file-name "docs/references" root)
           t)
          (write-region
           "" nil
           (expand-file-name
            "docs/references/closing-the-loop.md"
            root)
           nil 'silent)
          (with-temp-buffer
            (insert "docs/references/closing-the-\n     loop.md:19")
            (cl-letf (((symbol-function 'my-codex-project-root)
                       (lambda () root)))
              (my-codex-session-links-mode 1)
              (goto-char (point-min))
              (should
               (eq (get-text-property
                    (point)
                    'my-codex-session-link-type)
                   'file))
              (let ((target (get-text-property
                             (point)
                             'my-codex-session-link-target)))
                (should
                 (equal
                  target
                  '(:file "docs/references/closing-the-loop.md"
                    :line 19
                    :column nil
                    :end-line nil)))))))
      (delete-directory root t))))

(ert-deftest my-codex-session-links-linkifies-directory-boundary-wrapped-file-reference ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-links" t))))
    (unwind-protect
        (progn
          (make-directory
           (expand-file-name "docs/references" root)
           t)
          (write-region
           "" nil
           (expand-file-name
            "docs/references/closing-the-loop.md"
            root)
           nil 'silent)
          (with-temp-buffer
            (insert "docs/references/\n     closing-the-loop.md:19")
            (cl-letf (((symbol-function 'my-codex-project-root)
                       (lambda () root)))
              (my-codex-session-links-mode 1)
              (goto-char (point-min))
              (should
               (eq (get-text-property
                    (point)
                    'my-codex-session-link-type)
                   'file))
              (let ((target (get-text-property
                             (point)
                             'my-codex-session-link-target)))
                (should
                 (equal
                  target
                  '(:file "docs/references/closing-the-loop.md"
                    :line 19
                    :column nil
                    :end-line nil)))))))
      (delete-directory root t))))

(ert-deftest my-codex-session-links-linkifies-streamed-hard-wrapped-file-reference ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-links" t))))
    (unwind-protect
        (progn
          (make-directory
           (expand-file-name "docs/references" root)
           t)
          (write-region
           "" nil
           (expand-file-name
            "docs/references/closing-the-loop.md"
            root)
           nil 'silent)
          (with-temp-buffer
            (cl-letf (((symbol-function 'my-codex-project-root)
                       (lambda () root)))
              (my-codex-session-links-mode 1)
              (insert "docs/references/closing-the-\n")
              (insert "     loop.md:19")
              (goto-char (point-min))
              (should
               (eq (get-text-property
                    (point)
                    'my-codex-session-link-type)
                   'file))
              (let ((target (get-text-property
                             (point)
                             'my-codex-session-link-target)))
                (should
                 (equal
                  target
                  '(:file "docs/references/closing-the-loop.md"
                    :line 19
                    :column nil
                    :end-line nil)))))))
      (delete-directory root t))))

(ert-deftest my-codex-session-links-linkifies-wrapped-absolute-file-reference ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-links" t))))
    (unwind-protect
        (progn
          (make-directory
           (expand-file-name "src/examples/whichlang" root)
           t)
          (write-region
           "" nil
           (expand-file-name
            "src/examples/whichlang/make_dataset.h"
            root)
           nil 'silent)
          (with-temp-buffer
            (insert "  - [P2] Fix labels -- "
                    (expand-file-name "src/" root)
                    "\n    examples/whichlang/make_dataset.h:31-34")
            (cl-letf (((symbol-function 'my-codex-project-root)
                       (lambda () root)))
              (my-codex-session-links-mode 1)
              (goto-char (point-min))
              (search-forward "make_dataset.h")
              (should
               (eq (get-text-property
                    (point)
                    'my-codex-session-link-type)
                   'file))
              (let ((target (get-text-property
                             (point)
                             'my-codex-session-link-target)))
                (should
                 (equal
                  target
                  '(:file "src/examples/whichlang/make_dataset.h"
                    :line 31
                    :column nil
                    :end-line 34)))))))
      (delete-directory root t))))

(ert-deftest my-codex-region-file-reference-formats-relative-lines ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-region" t))))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "src/example.el" root))
          (insert "first\nsecond\nthird\n")
          (set-buffer-modified-p nil)
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'verify-visited-file-modtime)
                     (lambda (_buffer) t)))
            (should
             (equal
              (my-codex--region-file-reference (point-min) (point-max))
              "@src/example.el lines 1-3"))))
      (delete-directory root t))))

(ert-deftest my-codex-region-file-reference-rejects-unsaved-files ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-region" t))))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "src/example.el" root))
          (insert "first\nsecond\nthird\n")
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root)))
            (should-error
             (my-codex--region-file-reference (point-min) (point-max))
             :type 'user-error)))
      (delete-directory root t))))

(ert-deftest my-codex-region-file-reference-rejects-stale-files ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-region" t))))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "src/example.el" root))
          (insert "first\nsecond\nthird\n")
          (set-buffer-modified-p nil)
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'verify-visited-file-modtime)
                     (lambda (_buffer) nil)))
            (should-error
             (my-codex--region-file-reference (point-min) (point-max))
             :type 'user-error)))
      (delete-directory root t))))

(ert-deftest my-codex-region-file-reference-rejects-outside-project-files ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-region" t)))
        (outside-root (file-name-as-directory
                       (make-temp-file "my-codex-outside" t))))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "example.el" outside-root))
          (insert "first\nsecond\nthird\n")
          (set-buffer-modified-p nil)
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'verify-visited-file-modtime)
                     (lambda (_buffer) t)))
            (should-error
             (my-codex--region-file-reference (point-min) (point-max))
             :type 'user-error)))
      (delete-directory root t)
      (delete-directory outside-root t))))

(ert-deftest my-codex-send-current-file-rejects-unsaved-files ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-file" t))))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "src/example.el" root))
          (insert "unsaved\n")
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root)))
            (should-error
             (my-codex-send-current-file)
             :type 'user-error)))
      (delete-directory root t))))

(ert-deftest my-codex-send-current-file-rejects-outside-project-files ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-file" t)))
        (outside-root (file-name-as-directory
                       (make-temp-file "my-codex-outside" t))))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "example.el" outside-root))
          (insert "saved\n")
          (set-buffer-modified-p nil)
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'verify-visited-file-modtime)
                     (lambda (_buffer) t)))
            (should-error
             (my-codex-send-current-file)
             :type 'user-error)))
      (delete-directory root t)
      (delete-directory outside-root t))))

(ert-deftest my-codex-region-review-prompt-references-small-file-regions-by-default ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-region" t)))
        (my-codex-region-reference-threshold-chars 100))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "src/example.el" root))
          (insert "small region")
          (set-buffer-modified-p nil)
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'verify-visited-file-modtime)
                     (lambda (_buffer) t)))
            (let ((prompt (my-codex--region-review-prompt
                           (point-min)
                           (point-max))))
              (should (string-match-p "@src/example\\.el lines 1-1" prompt))
              (should-not (string-match-p "small region" prompt)))))
      (delete-directory root t))))

(ert-deftest my-codex-region-review-prompt-pastes-small-regions-in-automatic-mode ()
  (let ((my-codex-region-send-policy 'automatic)
        (my-codex-region-reference-threshold-chars 100))
    (with-temp-buffer
      (insert "small region")
      (let ((prompt (my-codex--region-review-prompt
                     (point-min)
                     (point-max))))
        (should (string-match-p "small region" prompt))
        (should-not (string-match-p "@.* lines " prompt))))))

(ert-deftest my-codex-region-review-prompt-references-large-file-regions ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-region" t)))
        (my-codex-region-reference-threshold-chars 5))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "src/example.el" root))
          (insert "first\nsecond\nthird\n")
          (set-buffer-modified-p nil)
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'verify-visited-file-modtime)
                     (lambda (_buffer) t)))
            (let ((prompt (my-codex--region-review-prompt
                           (point-min)
                           (point-max))))
              (should (string-match-p "@src/example\\.el lines 1-3" prompt))
              (should-not (string-match-p "first\nsecond\nthird" prompt)))))
      (delete-directory root t))))

(ert-deftest my-codex-region-review-prompt-pastes-file-regions-in-inline-mode ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-region" t)))
        (my-codex-region-send-policy 'prefer-inline))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "src/example.el" root))
          (insert "first\nsecond\nthird\n")
          (set-buffer-modified-p nil)
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'verify-visited-file-modtime)
                     (lambda (_buffer) t)))
            (let ((prompt (my-codex--region-review-prompt
                           (point-min)
                           (point-max))))
              (should (string-match-p "first\nsecond\nthird" prompt))
              (should-not
               (string-match-p "@src/example\\.el lines 1-3" prompt)))))
      (delete-directory root t))))

(ert-deftest my-codex-region-review-prompt-pastes-stale-file-regions ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-region" t)))
        (my-codex-region-reference-threshold-chars 5))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "src/example.el" root))
          (insert "first\nsecond\nthird\n")
          (set-buffer-modified-p nil)
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'verify-visited-file-modtime)
                     (lambda (_buffer) nil)))
            (let ((prompt (my-codex--region-review-prompt
                           (point-min)
                           (point-max))))
              (should (string-match-p "first\nsecond\nthird" prompt))
              (should-not
               (string-match-p "@src/example\\.el lines 1-3" prompt)))))
      (delete-directory root t))))

(ert-deftest my-codex-region-review-prompt-pastes-unsaved-file-regions ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-region" t)))
        (my-codex-region-reference-threshold-chars 5))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "src/example.el" root))
          (insert "first\nsecond\nthird\n")
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root)))
            (let ((prompt (my-codex--region-review-prompt
                           (point-min)
                           (point-max))))
              (should (string-match-p "first\nsecond\nthird" prompt))
              (should-not
               (string-match-p "@src/example\\.el lines 1-3" prompt)))))
      (delete-directory root t))))

(ert-deftest my-codex-region-review-request-defaults-small-modified-regions-inline ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-region" t)))
        (my-codex-region-reference-threshold-chars 100)
        seen-default)
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "src/example.el" root))
          (insert "small region")
          (cl-letf (((symbol-function 'my-codex-project-root) (lambda () root))
                    ((symbol-function 'completing-read)
                     (lambda (_prompt _collection &rest args)
                       (setq seen-default (nth 4 args))
                       seen-default)))
            (pcase-let ((`(,prompt . ,sent-message)
                         (my-codex--region-review-request
                          (point-min) (point-max))))
              (should (equal seen-default "Send inline"))
              (should (string-match-p "small region" prompt))
              (should (string-match-p
                       (concat "Sent inline; outbound prompt text: "
                               "approximately [0-9]+ tokens")
                       sent-message)))))
      (delete-directory root t))))

(ert-deftest my-codex-region-review-request-defaults-large-modified-regions-to-save ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-region" t)))
        (my-codex-region-reference-threshold-chars 5)
        seen-default)
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "src/example.el" root))
          (insert "first\nsecond\n")
          (cl-letf (((symbol-function 'my-codex-project-root) (lambda () root))
                    ((symbol-function 'completing-read)
                     (lambda (_prompt _collection &rest args)
                       (setq seen-default (nth 4 args))
                       seen-default))
                    ((symbol-function 'save-buffer)
                     (lambda (&rest _) (set-buffer-modified-p nil)))
                    ((symbol-function 'verify-visited-file-modtime)
                     (lambda (_buffer) t)))
            (pcase-let ((`(,prompt . ,sent-message)
                         (my-codex--region-review-request
                          (point-min) (point-max))))
              (should (equal seen-default "Save and send reference"))
              (should (string-match-p "@src/example\\.el lines 1-2" prompt))
              (should (equal sent-message
                             "Sent by file reference: src/example.el lines 1-2")))))
      (delete-directory root t))))

(ert-deftest my-codex-region-review-request-preserves-bounds-across-save-hooks ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-region" t)))
        (my-codex-region-reference-threshold-chars 5))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "src/example.el" root))
          (insert "first\nsecond\n")
          (cl-letf (((symbol-function 'my-codex-project-root) (lambda () root))
                    ((symbol-function 'completing-read)
                     (lambda (&rest _) "Save and send reference"))
                    ((symbol-function 'save-buffer)
                     (lambda (&rest _)
                       (save-excursion
                         (goto-char (point-min))
                         (insert "formatted header\n"))
                       (set-buffer-modified-p nil)))
                    ((symbol-function 'verify-visited-file-modtime)
                     (lambda (_buffer) t)))
            (pcase-let ((`(,prompt . ,sent-message)
                         (my-codex--region-review-request
                          (point-min) (point-max))))
              (should (string-match-p "@src/example\\.el lines 2-3" prompt))
              (should (equal sent-message
                             "Sent by file reference: src/example.el lines 2-3")))))
      (delete-directory root t))))

(ert-deftest my-codex-region-review-request-allows-cancelling-modified-regions ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-region" t))))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "src/example.el" root))
          (insert "modified region")
          (cl-letf (((symbol-function 'my-codex-project-root) (lambda () root))
                    ((symbol-function 'completing-read)
                     (lambda (&rest _) "Cancel")))
            (should-error
             (my-codex--region-review-request (point-min) (point-max))
             :type 'user-error)))
      (delete-directory root t))))

(ert-deftest my-codex-plan-refactor-region-uses-region-context-delivery ()
  (let (sent-prompt sent-message)
    (cl-letf (((symbol-function 'use-region-p) (lambda () t))
              ((symbol-function 'my-codex--region-context-request)
               (lambda (_beg _end)
                 '("Selected region:\n\ninline context" . "Sent inline")))
              ((symbol-function 'my-codex--preview-and-send-prompt)
               (lambda (prompt &optional message)
                 (setq sent-prompt prompt
                       sent-message message))))
      (my-codex-plan-refactor-region 1 2)
      (should (equal sent-prompt
                     (format "%s\n\nSelected region:\n\ninline context"
                             my-codex-refactor-plan-prompt)))
      (should (equal sent-message "Sent inline")))))

(ert-deftest my-codex-region-review-prompt-pastes-unnamed-large-regions ()
  (let ((my-codex-region-reference-threshold-chars 5))
    (with-temp-buffer
      (insert "first\nsecond\nthird\n")
      (let ((prompt (my-codex--region-review-prompt
                     (point-min)
                     (point-max))))
        (should (string-match-p "first\nsecond\nthird" prompt))
        (should-not (string-match-p "@.* lines " prompt))))))

(ert-deftest my-codex-region-review-prompt-pastes-outside-project-regions ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-region" t)))
        (outside-root (file-name-as-directory
                       (make-temp-file "my-codex-outside" t)))
        (my-codex-region-reference-threshold-chars 5))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "example.el" outside-root))
          (insert "first\nsecond\nthird\n")
          (set-buffer-modified-p nil)
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'verify-visited-file-modtime)
                     (lambda (_buffer) t)))
            (let ((prompt (my-codex--region-review-prompt
                           (point-min)
                           (point-max))))
              (should (string-match-p "first\nsecond\nthird" prompt))
              (should-not (string-match-p "@.* lines " prompt)))))
      (delete-directory root t)
      (delete-directory outside-root t))))

(ert-deftest my-codex-region-prompt-context-references-large-file-regions ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-region" t)))
        (my-codex-region-reference-threshold-chars 5))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "src/example.el" root))
          (insert "first\nsecond\nthird\n")
          (set-buffer-modified-p nil)
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'verify-visited-file-modtime)
                     (lambda (_buffer) t)))
            (let ((context (my-codex--region-prompt-context
                            (point-min)
                            (point-max))))
              (should (string-match-p "@src/example\\.el lines 1-3" context))
              (should-not (string-match-p "first\nsecond\nthird" context)))))
      (delete-directory root t))))

(ert-deftest my-codex-region-prompt-context-pastes-stale-file-regions ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-region" t)))
        (my-codex-region-reference-threshold-chars 5))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "src/example.el" root))
          (insert "first\nsecond\nthird\n")
          (set-buffer-modified-p nil)
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'verify-visited-file-modtime)
                     (lambda (_buffer) nil)))
            (let ((context (my-codex--region-prompt-context
                            (point-min)
                            (point-max))))
              (should (string-match-p "first\nsecond\nthird" context))
              (should-not
               (string-match-p "@src/example\\.el lines 1-3" context)))))
      (delete-directory root t))))

(ert-deftest my-codex-region-prompt-context-pastes-unsaved-file-regions ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-region" t)))
        (my-codex-region-reference-threshold-chars 5))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "src/example.el" root))
          (insert "first\nsecond\nthird\n")
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root)))
            (let ((context (my-codex--region-prompt-context
                            (point-min)
                            (point-max))))
              (should (string-match-p "first\nsecond\nthird" context))
              (should-not
               (string-match-p "@src/example\\.el lines 1-3" context)))))
      (delete-directory root t))))

(ert-deftest my-codex-region-prompt-context-pastes-unnamed-regions ()
  (let ((my-codex-region-reference-threshold-chars 5))
    (with-temp-buffer
      (insert "first\nsecond\nthird\n")
      (let ((context (my-codex--region-prompt-context
                      (point-min)
                      (point-max))))
        (should (string-match-p "first\nsecond\nthird" context))
        (should-not (string-match-p "@.* lines " context))))))

(ert-deftest my-codex-region-prompt-context-pastes-outside-project-regions ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-region" t)))
        (outside-root (file-name-as-directory
                       (make-temp-file "my-codex-outside" t)))
        (my-codex-region-reference-threshold-chars 5))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "example.el" outside-root))
          (insert "first\nsecond\nthird\n")
          (set-buffer-modified-p nil)
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'verify-visited-file-modtime)
                     (lambda (_buffer) t)))
            (let ((context (my-codex--region-prompt-context
                            (point-min)
                            (point-max))))
              (should (string-match-p "first\nsecond\nthird" context))
              (should-not (string-match-p "@.* lines " context)))))
      (delete-directory root t)
      (delete-directory outside-root t))))

(ert-deftest my-codex-defun-bounds-at-point-finds-current-defun ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(defun first ()\n  1)\n\n(defun second ()\n  2)\n")
    (search-backward "2")
    (let ((bounds (my-codex--defun-bounds-at-point)))
      (should
       (equal (buffer-substring-no-properties (car bounds) (cdr bounds))
              "(defun second ()\n  2)\n")))))

(ert-deftest my-codex-defun-bounds-at-point-rejects-leading-text ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert ";; header\n\n(defun first ()\n  1)\n")
    (goto-char (point-min))
    (should-error (my-codex--defun-bounds-at-point) :type 'user-error)))

(ert-deftest my-codex-review-defun-at-point-reuses-region-review-prompt ()
  (let (sent-beg sent-end sent-prompt)
    (with-temp-buffer
      (emacs-lisp-mode)
      (insert "(defun reviewed ()\n  1)\n")
      (goto-char (point-min))
      (cl-letf (((symbol-function 'my-codex--region-review-prompt)
                 (lambda (beg end)
                   (setq sent-beg (marker-position beg)
                         sent-end (marker-position end))
                   "review prompt"))
                ((symbol-function 'my-codex--preview-and-send-prompt)
                 (lambda (prompt &optional _sent-message)
                   (setq sent-prompt prompt))))
        (my-codex-review-defun-at-point)
        (should (= sent-beg (point-min)))
        (should (= sent-end (point-max)))
        (should (equal sent-prompt "review prompt"))))))

(ert-deftest my-codex-test-coverage-prompt-puts-dynamic-context-late ()
  (let* ((my-codex-test-coverage-prompt "Stable coverage instructions.")
         (prompt (my-codex--test-coverage-prompt
                  "src/example.el"
                  "test/example-test.el")))
    (let ((instructions-pos
           (string-match "Stable coverage instructions\\." prompt))
          (context-pos (string-match "context:" prompt))
          (implementation-pos
           (string-match "implementation: @src/example\\.el" prompt))
          (test-pos
           (string-match "test: @test/example-test\\.el" prompt))
          (request-pos
           (string-match "request: Analyze test coverage now\\." prompt)))
      (should instructions-pos)
      (should context-pos)
      (should implementation-pos)
      (should test-pos)
      (should request-pos)
      (should (< instructions-pos context-pos))
      (should (< context-pos implementation-pos))
      (should (< implementation-pos test-pos))
      (should (< test-pos request-pos)))))

(ert-deftest my-codex-analyse-test-coverage-rejects-unsaved-implementation ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-coverage" t)))
        sent)
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "src/example.el" root))
          (insert "unsaved\n")
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'my-codex--read-test-file)
                     (lambda (_implementation-file _root)
                       (expand-file-name "test/example-test.el" root)))
                    ((symbol-function 'my-codex--preview-and-send-prompt)
                     (lambda (prompt) (setq sent prompt))))
            (should-error
             (my-codex-analyse-test-coverage)
             :type 'user-error)
            (should-not sent)))
      (delete-directory root t))))

(ert-deftest my-codex-analyse-test-coverage-rejects-unsaved-test-file ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-coverage" t)))
        (test-buffer (generate-new-buffer "example-test.el"))
        sent)
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "src/example.el" root))
          (insert "saved\n")
          (set-buffer-modified-p nil)
          (with-current-buffer test-buffer
            (setq default-directory root)
            (setq buffer-file-name
                  (expand-file-name "test/example-test.el" root))
            (insert "unsaved test\n")
            (set-buffer-modified-p t))
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'my-codex--read-test-file)
                     (lambda (_implementation-file _root)
                       (buffer-file-name test-buffer)))
                    ((symbol-function 'verify-visited-file-modtime)
                     (lambda (_buffer) t))
                    ((symbol-function 'my-codex--preview-and-send-prompt)
                     (lambda (prompt) (setq sent prompt))))
            (should-error
             (my-codex-analyse-test-coverage)
             :type 'user-error)
            (should-not sent)))
      (when (buffer-live-p test-buffer)
        (kill-buffer test-buffer))
      (delete-directory root t))))

(ert-deftest my-codex-doctor-command-executable-token-handles-shell-prefixes ()
  (should
   (equal
    (my-codex--doctor-command-executable-token
     "FOO=1 command -v env BAR=2 --unset BAZ codex exec")
    "codex")))

(ert-deftest my-codex-doctor-command-executable-token-returns-nil-for-blank ()
  (should-not (my-codex--doctor-command-executable-token "  ")))

(ert-deftest my-codex-doctor-vterm-scrollback-warns-when-disabled ()
  (let ((my-codex-vterm-min-scrollback nil))
    (should
     (equal
      (my-codex--doctor-vterm-scrollback t)
      '("Codex vterm scrollback" warn
        "Scrollback floor is disabled; marked output can be truncated")))))

(ert-deftest my-codex-doctor-vterm-scrollback-reports-local-raise ()
  (let ((was-bound (boundp 'vterm-max-scrollback))
        (original-value (and (boundp 'vterm-max-scrollback)
                             (symbol-value 'vterm-max-scrollback)))
        (my-codex-vterm-min-scrollback 10000))
    (unwind-protect
        (progn
          (set 'vterm-max-scrollback 1000)
          (should
           (equal
            (my-codex--doctor-vterm-scrollback t)
            '("Codex vterm scrollback" ok
              "Codex buffers raise 1000 to 10000 lines"))))
      (if was-bound
          (set 'vterm-max-scrollback original-value)
        (makunbound 'vterm-max-scrollback)))))

(ert-deftest my-codex-doctor-codex-service-tier-warns-for-fast ()
  (let ((config (make-temp-file "my-codex-config-" nil ".toml")))
    (unwind-protect
        (progn
          (with-temp-file config
            (insert "service_tier = \"fast\"\n"))
          (should
            (equal
             (my-codex--doctor-codex-service-tier config)
             '("Codex user config: service_tier" warn
              "fast in top level uses priority processing and increases costs; use it only when lower latency is worth it"))))
      (delete-file config))))

(ert-deftest my-codex-doctor-codex-service-tier-accepts-non-fast ()
  (let ((config (make-temp-file "my-codex-config-" nil ".toml")))
    (unwind-protect
        (progn
          (with-temp-file config
            (insert "service_tier = \"auto\"\n"))
          (should
           (equal
            (my-codex--doctor-codex-service-tier config)
            '("Codex user config: service_tier" ok
              "Configured as \"auto\" in top level"))))
      (delete-file config))))

(ert-deftest my-codex-doctor-codex-service-tier-respects-codex-home ()
  (let* ((codex-home (make-temp-file "my-codex-home-" t))
         (config (expand-file-name "config.toml" codex-home))
         (process-environment (cons (format "CODEX_HOME=%s" codex-home)
                                    process-environment)))
    (unwind-protect
        (progn
          (with-temp-file config
            (insert "service_tier = \"fast\"\n"))
          (should
            (equal
             (my-codex--doctor-codex-service-tier)
             '("Codex user config: service_tier" warn
              "fast in top level uses priority processing and increases costs; use it only when lower latency is worth it"))))
      (delete-directory codex-home t))))

(ert-deftest my-codex-doctor-codex-service-tier-ignores-inactive-profile ()
  (let ((config (make-temp-file "my-codex-config-" nil ".toml")))
    (unwind-protect
        (progn
          (with-temp-file config
            (insert "profile = \"default\"\n"
                    "\n"
                    "[profiles.default]\n"
                    "service_tier = \"auto\"\n"
                    "\n"
                    "[profiles.fast-profile]\n"
                    "service_tier = \"fast\"\n"))
          (should
           (equal
            (my-codex--doctor-codex-service-tier config)
            '("Codex user config: service_tier" ok
              "Configured as \"auto\" in profile \"default\""))))
      (delete-file config))))

(ert-deftest my-codex-doctor-codex-service-tier-honours-active-profile ()
  (let ((config (make-temp-file "my-codex-config-" nil ".toml")))
    (unwind-protect
        (progn
          (with-temp-file config
            (insert "profile = \"fast-profile\"\n"
                    "service_tier = \"auto\"\n"
                    "\n"
                    "[profiles.default]\n"
                    "service_tier = \"auto\"\n"
                    "\n"
                    "[profiles.fast-profile]\n"
                    "service_tier = \"fast\"\n"))
          (should
            (equal
             (my-codex--doctor-codex-service-tier config)
             '("Codex user config: service_tier" warn
              "fast in profile \"fast-profile\" uses priority processing and increases costs; use it only when lower latency is worth it"))))
      (delete-file config))))

(ert-deftest my-codex-doctor-codex-service-tier-accepts-missing-config ()
  (let ((config (make-temp-file "my-codex-config-" nil ".toml")))
    (delete-file config)
    (should
     (equal
      (my-codex--doctor-codex-service-tier config)
      '("Codex user config: service_tier" ok
        "Not found in user-level config; another configuration layer may override it")))))

(ert-deftest my-codex-doctor-codex-context-rows-report-configured-values ()
  (let ((config (make-temp-file "my-codex-config-" nil ".toml")))
    (unwind-protect
        (progn
          (with-temp-file config
            (insert "tool_output_token_limit = 8000\n"
                    "model_auto_compact_token_limit = 120_000\n"))
          (should
           (equal
            (my-codex--doctor-codex-context-rows config)
            '(("Codex user config: tool_output_token_limit" ok "8,000 tokens")
              ("Codex user config: model_auto_compact_token_limit" ok "120,000 tokens")
              ("Codex user config: project_doc_max_bytes" ok
               "Not found in user-level config; another configuration layer may override it")))))
      (delete-file config))))

(ert-deftest my-codex-doctor-codex-context-rows-honour-active-profile ()
  (let ((config (make-temp-file "my-codex-config-" nil ".toml")))
    (unwind-protect
        (progn
          (with-temp-file config
            (insert "profile = \"compact\"\n"
                    "tool_output_token_limit = 8000\n"
                    "\n"
                    "[profiles.compact]\n"
                    "tool_output_token_limit = 4000\n"))
          (should
           (equal
            (my-codex--doctor-codex-context-rows config)
            '(("Codex user config: tool_output_token_limit" ok "4,000 tokens")
              ("Codex user config: model_auto_compact_token_limit" ok
               "Not found in user-level config; another configuration layer may override it")
              ("Codex user config: project_doc_max_bytes" ok
               "Not found in user-level config; another configuration layer may override it")))))
      (delete-file config))))

(ert-deftest my-codex-doctor-agent-rows-use-profile-callback ()
  (let ((my-codex-agent-profiles
         '((codex :doctor-function my-codex-test--doctor-rows)
           (antigravity :label "Antigravity"))))
    (cl-letf (((symbol-function 'my-codex-test--doctor-rows)
               (lambda () '(("Codex setting" ok "configured")))))
      (should
       (equal (my-codex--doctor-agent-rows 'codex)
              '(("Codex setting" ok "configured"))))
      (should-not (my-codex--doctor-agent-rows 'antigravity)))))

(ert-deftest my-codex-doctor-project-instructions-reports-total-size ()
  (let ((root (make-temp-file "my-codex-project-" t))
        (my-codex-agent 'codex))
    (unwind-protect
        (let ((first (expand-file-name "AGENTS.md" root))
              (second (expand-file-name "CODEX.md" root)))
          (with-temp-file first (insert (make-string 1024 ?a)))
          (with-temp-file second (insert (make-string 512 ?b)))
          (cl-letf (((symbol-function
                      'my-codex--doctor-codex-integer-setting-value)
                     (lambda (&rest _) 2048)))
            (should
             (equal (my-codex--doctor-project-instructions-row
                     root (list first second))
                    '("Project instructions" ok
                      "1.5 KiB across 2 files; allowance 2.0 KiB: AGENTS.md, CODEX.md")))))
      (delete-directory root t))))

(ert-deftest my-codex-doctor-project-instructions-warns-near-allowance ()
  (let ((root (make-temp-file "my-codex-project-" t))
        (my-codex-agent 'codex))
    (unwind-protect
        (let ((file (expand-file-name "AGENTS.md" root)))
          (with-temp-file file (insert (make-string 820 ?a)))
          (cl-letf (((symbol-function
                      'my-codex--doctor-codex-integer-setting-value)
                     (lambda (&rest _) 1024)))
            (should
             (eq (cadr (my-codex--doctor-project-instructions-row
                        root (list file)))
                 'warn))))
      (delete-directory root t))))

(ert-deftest my-codex-doctor-project-instructions-uses-codex-default-allowance ()
  (let ((root (make-temp-file "my-codex-project-" t))
        (my-codex-agent 'codex))
    (unwind-protect
        (let ((file (expand-file-name "AGENTS.md" root)))
          (with-temp-file file (insert (make-string (* 27 1024) ?a)))
          (cl-letf (((symbol-function
                      'my-codex--doctor-codex-integer-setting-value)
                     (lambda (&rest _) nil)))
            (should
             (equal (my-codex--doctor-project-instructions-row
                     root (list file))
                    '("Project instructions" warn
                      "27.0 KiB across 1 file; allowance 32.0 KiB: AGENTS.md")))))
      (delete-directory root t))))

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

(ert-deftest my-codex-flycheck-diagnostics-sorts-current-errors ()
  (let ((diagnostics
         '((:line 10 :column 1 :message "third")
           (:line 2 :column 8 :message "second")
           (:line 2 :column 3 :message "first"))))
    (my-codex-test--with-mock-flycheck diagnostics
      (should
       (equal
        (mapcar (lambda (diagnostic)
                  (plist-get diagnostic :message))
                (my-codex--flycheck-diagnostics))
        '("first" "second" "third"))))))

(ert-deftest my-codex-flycheck-diagnostics-errors-when-inactive ()
  (let ((flycheck-mode nil)
        (flycheck-current-errors nil))
    (should-error
     (my-codex--flycheck-diagnostics)
     :type 'user-error)))

(ert-deftest my-codex-flycheck-diagnostic-at-point-selects-nearest-column ()
  (let ((diagnostics
         '((:line 2 :column 4 :message "left")
           (:line 2 :column 12 :message "right")
           (:line 3 :column 1 :message "other"))))
    (with-temp-buffer
      (insert "one\n012345678901234\nthree\n")
      (goto-char (point-min))
      (forward-line 1)
      (move-to-column 10)
      (my-codex-test--with-mock-flycheck diagnostics
        (should
         (equal
          (plist-get
           (my-codex--flycheck-diagnostic-at-point
            (my-codex--flycheck-diagnostics))
           :message)
          "right"))))))

(ert-deftest my-codex-flycheck-diagnostic-at-point-uses-absolute-line-in-narrowed-buffer ()
  (let ((diagnostics
         '((:line 2 :column 1 :message "wrong-relative-line")
           (:line 4 :column 1 :message "absolute-line"))))
    (with-temp-buffer
      (insert "one\ntwo\nthree\nfour\nfive\n")
      (narrow-to-region (save-excursion
                          (goto-char (point-min))
                          (forward-line 2)
                          (point))
                        (point-max))
      (goto-char (point-min))
      (forward-line 1)
      (my-codex-test--with-mock-flycheck diagnostics
        (should
         (equal
          (plist-get
           (my-codex--flycheck-diagnostic-at-point
            (my-codex--flycheck-diagnostics))
           :message)
          "absolute-line"))))))

(ert-deftest my-codex-flycheck-diagnostic-at-point-ignores-other-files ()
  (let* ((root (file-name-as-directory (make-temp-file "my-codex-flycheck" t)))
         (current-file (expand-file-name "src/current.el" root))
         (other-file (expand-file-name "src/other.el" root))
         (diagnostics
          `((:filename ,other-file
             :line 2
             :column 10
             :message "other-file")
            (:filename ,current-file
             :line 2
             :column 1
             :message "current-file"))))
    (unwind-protect
        (with-temp-buffer
          (setq buffer-file-name current-file)
          (insert "one\ntwo\n")
          (goto-char (point-min))
          (forward-line 1)
          (move-to-column 9)
          (my-codex-test--with-mock-flycheck diagnostics
            (should
             (equal
              (plist-get
               (my-codex--flycheck-diagnostic-at-point
                (my-codex--flycheck-diagnostics))
               :message)
              "current-file"))))
      (delete-directory root t))))

(ert-deftest my-codex-flycheck-diagnostic-at-point-errors-without-current-line-diagnostic ()
  (let ((diagnostics '((:line 3 :column 1 :message "other"))))
    (with-temp-buffer
      (insert "one\ntwo\nthree\n")
      (goto-char (point-min))
      (forward-line 1)
      (my-codex-test--with-mock-flycheck diagnostics
        (should-error
         (my-codex--flycheck-diagnostic-at-point
          (my-codex--flycheck-diagnostics))
         :type 'user-error)))))

(ert-deftest my-codex-flycheck-diagnostics-prompt-formats-diagnostics ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-flycheck" t))))
    (unwind-protect
        (with-temp-buffer
          (let ((file (expand-file-name "src/example.el" root)))
            (setq buffer-file-name file)
            (my-codex-test--with-mock-flycheck
                `((:filename ,file
                   :line 7
                   :column 11
                   :level warning
                   :checker emacs-lisp
                   :id "free-vars"
                   :message "reference to free variable `value'")
                  (:filename ,file
                   :line 8
                   :column 3
                   :level warning
                   :checker emacs-lisp
                   :message "unused lexical argument"))
              (cl-letf (((symbol-function 'my-codex-project-root)
                         (lambda () root)))
                (let* ((my-codex-flycheck-diagnostics-limit 100)
                       (prompt (my-codex--flycheck-diagnostics-prompt
                                (my-codex--flycheck-diagnostics))))
                  (should
                   (string-match-p
                    "Analyse these Flycheck diagnostics as a batch" prompt))
                  (should (string-match-p "source: Flycheck" prompt))
                  (should (string-match-p "diagnostic_count: 2" prompt))
                  (should (string-match-p "truncated: false" prompt))
                  (should (string-match-p "file: \"src/example\\.el\"" prompt))
                  (should (string-match-p "diagnostics:" prompt))
                  (should (string-match-p "- line: 7" prompt))
                  (should (string-match-p "  column: 11" prompt))
                  (should (string-match-p "  severity: \"warning\"" prompt))
                  (should (string-match-p "  checker: \"emacs-lisp\"" prompt))
                  (should (string-match-p "  id: \"free-vars\"" prompt))
                  (should
                   (string-match-p
                    "message: \"reference to free variable `value'\""
                    prompt))
                  (should (string-match-p "- line: 8" prompt))
                  (should
                   (string-match-p
                    "message: \"unused lexical argument\""
                    prompt))
                  (should
                   (= 1
                      (let ((start 0)
                            (count 0))
                        (while (string-match
                                "file: \"src/example\\.el\""
                                prompt start)
                          (setq count (1+ count)
                                start (match-end 0)))
                        count))))))))
      (delete-directory root t))))

(ert-deftest my-codex-explain-diagnostic-at-point-sends-single-flycheck-prompt ()
  (let ((diagnostics
         '((:line 1
            :column 2
            :level error
            :checker mock-checker
            :message "broken")
           (:line 2
            :column 1
            :level warning
            :checker mock-checker
            :message "other")))
        sent)
    (with-temp-buffer
      (insert "broken\nother\n")
      (goto-char (point-min))
      (my-codex-test--with-mock-flycheck diagnostics
        (cl-letf (((symbol-function 'my-codex-project-root)
                   (lambda () "/repo/"))
                  ((symbol-function 'my-codex--preview-and-send-prompt)
                   (lambda (prompt) (setq sent prompt))))
          (my-codex-explain-diagnostic-at-point)
          (should sent)
          (should
           (string-match-p
            "Explain this Flycheck diagnostic" sent))
          (should (string-match-p "source: Flycheck" sent))
          (should (string-match-p "message: \"broken\"" sent))
          (should-not (string-match-p "message: \"other\"" sent)))))))

(ert-deftest my-codex-flycheck-diagnostics-prompt-reports-truncation ()
  (let ((my-codex-flycheck-diagnostics-limit 2)
        (diagnostics
         '((:line 1 :column 1 :level error :checker mock :message "first")
           (:line 2 :column 1 :level error :checker mock :message "second")
           (:line 3 :column 1 :level error :checker mock :message "third"))))
    (my-codex-test--with-mock-flycheck diagnostics
      (cl-letf (((symbol-function 'my-codex-project-root)
                 (lambda () "/repo/")))
        (let ((prompt (my-codex--flycheck-diagnostics-prompt diagnostics)))
          (should (string-match-p "diagnostic_count: 3" prompt))
          (should (string-match-p "included_count: 2" prompt))
          (should (string-match-p "truncated: true" prompt))
          (should (string-match-p "message: \"first\"" prompt))
          (should (string-match-p "message: \"second\"" prompt))
          (should-not (string-match-p "message: \"third\"" prompt)))))))

(ert-deftest my-codex-flycheck-diagnostics-prompt-deduplicates-diagnostics ()
  (let ((diagnostics
         '((:line 1 :column 1 :level error :checker mock :message "same")
           (:line 1 :column 1 :level error :checker mock :message "same")
           (:line 2 :column 1 :level error :checker mock :message "other"))))
    (my-codex-test--with-mock-flycheck diagnostics
      (cl-letf (((symbol-function 'my-codex-project-root)
                 (lambda () "/repo/")))
        (let ((prompt (my-codex--flycheck-diagnostics-prompt diagnostics)))
          (should (string-match-p "diagnostic_count: 3" prompt))
          (should (string-match-p "unique_diagnostic_count: 2" prompt))
          (should (string-match-p "included_count: 2" prompt))
          (should (string-match-p "omitted_count: 1" prompt))
          (should (= 1
                     (let ((start 0)
                           (count 0))
                       (while (string-match "message: \"same\"" prompt start)
                         (setq count (1+ count)
                               start (match-end 0)))
                       count))))))))

(ert-deftest my-codex-flycheck-diagnostics-prompt-groups-repeated-messages ()
  (let ((diagnostics
         '((:line 1 :column 1 :level error :checker mock :message "repeat")
           (:line 2 :column 3 :level error :checker mock :message "repeat")
           (:line 4 :column 1 :level warning :checker mock :message "repeat"))))
    (my-codex-test--with-mock-flycheck diagnostics
      (cl-letf (((symbol-function 'my-codex-project-root)
                 (lambda () "/repo/")))
        (let ((prompt (my-codex--flycheck-diagnostics-prompt diagnostics)))
          (should (string-match-p "occurrence_count: 2" prompt))
          (should (string-match-p "locations:" prompt))
          (should (string-match-p "- line: 1" prompt))
          (should (string-match-p "- line: 2" prompt))
          (should (string-match-p "- line: 4" prompt)))))))

(ert-deftest my-codex-flycheck-diagnostics-prompt-obeys-context-budget ()
  (let ((my-codex-flycheck-diagnostics-limit 100)
        (my-codex-diagnostics-token-budget 80)
        (diagnostics
         '((:line 1 :column 1 :level error :checker mock :message "short")
           (:line 2 :column 1 :level error :checker mock
            :message "this diagnostic has a much longer message")
           (:line 3 :column 1 :level error :checker mock :message "later"))))
    (my-codex-test--with-mock-flycheck diagnostics
      (cl-letf (((symbol-function 'my-codex-project-root)
                 (lambda () "/repo/")))
        (let ((prompt (my-codex--flycheck-diagnostics-prompt diagnostics)))
          (should (string-match-p "diagnostic_count: 3" prompt))
          (should (string-match-p "included_count: 1" prompt))
          (should (string-match-p "omitted_count: 2" prompt))
          (should (string-match-p "context_budget_tokens: 80" prompt))
          (should (string-match-p "truncated: true" prompt))
          (should (string-match-p "message: \"short\"" prompt))
          (should-not (string-match-p "much longer message" prompt))
          (should-not (string-match-p "message: \"later\"" prompt)))))))

(ert-deftest my-codex-flycheck-diagnostics-prompt-keeps-one-tight-budget ()
  (let ((my-codex-flycheck-diagnostics-limit 100)
        (my-codex-diagnostics-token-budget 1)
        (diagnostics
         '((:line 1 :column 1 :level error :checker mock
            :message "verbose diagnostic that exceeds the tiny budget")
           (:line 2 :column 1 :level error :checker mock
            :message "later"))))
    (my-codex-test--with-mock-flycheck diagnostics
      (cl-letf (((symbol-function 'my-codex-project-root)
                 (lambda () "/repo/")))
        (let ((prompt (my-codex--flycheck-diagnostics-prompt diagnostics)))
          (should (string-match-p "diagnostic_count: 2" prompt))
          (should (string-match-p "included_count: 1" prompt))
          (should (string-match-p "omitted_count: 1" prompt))
          (should (string-match-p
                   "message: \"verbose diagnostic that exceeds the tiny budget\""
                   prompt))
          (should-not (string-match-p "message: \"later\"" prompt)))))))

(ert-deftest my-codex-flycheck-diagnostics-prompt-caps-first-repeated-group ()
  (let ((my-codex-flycheck-diagnostics-limit 100)
        (my-codex-diagnostics-token-budget 10)
        (diagnostics
         '((:line 1 :column 1 :level error :checker mock :message "repeat")
           (:line 2 :column 1 :level error :checker mock :message "repeat")
           (:line 3 :column 1 :level error :checker mock :message "repeat"))))
    (my-codex-test--with-mock-flycheck diagnostics
      (cl-letf (((symbol-function 'my-codex-project-root)
                 (lambda () "/repo/"))
                ((symbol-function 'my-codex--approx-token-count)
                 (lambda (text)
                   (if (string-match-p "- line: 2" text) 99 1))))
        (let ((prompt (my-codex--flycheck-diagnostics-prompt diagnostics)))
          (should (string-match-p "diagnostic_count: 3" prompt))
          (should (string-match-p "included_count: 1" prompt))
          (should (string-match-p "omitted_count: 2" prompt))
          (should (string-match-p "message: \"repeat\"" prompt))
          (should (string-match-p "- line: 1" prompt))
          (should-not (string-match-p "- line: 2" prompt))
          (should-not (string-match-p "- line: 3" prompt)))))))

(ert-deftest my-codex-explain-buffer-diagnostics-sends-flycheck-prompt ()
  (let ((diagnostics
         '((:line 1
            :column 2
            :level error
            :checker mock-checker
            :message "broken")))
        sent)
    (my-codex-test--with-mock-flycheck diagnostics
      (cl-letf (((symbol-function 'my-codex-project-root)
                 (lambda () "/repo/"))
                ((symbol-function 'my-codex--preview-and-send-prompt)
                 (lambda (prompt) (setq sent prompt))))
        (my-codex-explain-buffer-diagnostics)
        (should sent)
        (should (string-match-p "source: Flycheck" sent))
        (should (string-match-p "message: \"broken\"" sent))))))

(ert-deftest my-codex-explain-symbol-references-saved-file ()
  (let ((sent nil))
    (with-temp-buffer
      (setq buffer-file-name "/repo/src/example.el")
      (insert "(defun alpha ()\n  42)\n")
      (goto-char (point-min))
      (search-forward "alpha")
      (set-buffer-modified-p nil)
      (cl-letf (((symbol-function 'my-codex-project-root)
                 (lambda () "/repo/"))
                ((symbol-function 'my-codex--symbol-xref-context)
                 (lambda (_symbol _root) nil))
                ((symbol-function 'my-codex--preview-and-send-prompt)
                 (lambda (prompt) (setq sent prompt))))
        (my-codex-explain-symbol-at-point)))
    (should (string-match-p "symbol: \"alpha\"" sent))
    (should (string-match-p "location: \"src/example\\.el:1\"" sent))
    (should-not (string-match-p "excerpt: |" sent))))

(ert-deftest my-codex-explain-symbol-includes-modified-buffer-excerpt ()
  (let ((sent nil))
    (with-temp-buffer
      (setq buffer-file-name "/repo/src/example.el")
      (insert "(defun alpha ()\n  42)\n")
      (goto-char (point-min))
      (search-forward "alpha")
      (set-buffer-modified-p t)
      (cl-letf (((symbol-function 'my-codex-project-root)
                 (lambda () "/repo/"))
                ((symbol-function 'my-codex--symbol-xref-context)
                 (lambda (_symbol _root) nil))
                ((symbol-function 'my-codex--preview-and-send-prompt)
                 (lambda (prompt) (setq sent prompt))))
        (my-codex-explain-symbol-at-point)))
    (should (string-match-p "location: \"src/example\\.el:1\"" sent))
    (should (string-match-p "excerpt: |" sent))
    (should (string-match-p "(defun alpha" sent))))

(ert-deftest my-codex-line-context-trims-boundary-whitespace ()
  (with-temp-buffer
    (insert "   \n\n  (defun alpha ()  \n\n    42)\t\n\n")
    (goto-char (point-min))
    (search-forward "alpha")
    (should (equal (my-codex--line-context-around-point 5)
                   "  (defun alpha ()\n\n    42)"))))

(ert-deftest my-codex-xref-items-section-formats-relative-locations ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-xref" t))))
    (unwind-protect
        (with-temp-buffer
          (setq buffer-file-name (expand-file-name "src/example.el" root))
          (insert "(defun alpha ()\n"
                  "  (beta))\n"
                  "\n"
                  "(defun beta ()\n"
                  "  42)\n")
          (set-buffer-modified-p nil)
          (let* ((first-marker (copy-marker (point-min)))
                 (second-marker (copy-marker (point-max)))
                 (section
                  (my-codex--xref-items-section
                   "Definitions"
                   (list
                    (xref-make
                     "alpha"
                     (xref-make-buffer-location
                      (current-buffer)
                      (marker-position first-marker)))
                    (xref-make
                     "beta"
                     (xref-make-buffer-location
                      (current-buffer)
                      (marker-position second-marker))))
                   root
                   1
                   1)))
            (should (string-match-p "definitions:" section))
            (should (string-match-p
                     "location: \"src/example\\.el:1\""
                     section))
            (should-not (string-match-p "summary: \"alpha\"" section))
            (should-not (string-match-p "excerpt: |" section))
            (should-not (string-match-p "location: \"src/example\\.el:6\""
                                        section))))
      (delete-directory root t))))

(ert-deftest my-codex-xref-items-section-includes-modified-buffer-excerpt ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-xref" t))))
    (unwind-protect
        (with-temp-buffer
          (setq buffer-file-name (expand-file-name "src/example.el" root))
          (insert "(defun alpha ()\n"
                  "  (beta))\n")
          (set-buffer-modified-p t)
          (let* ((marker (copy-marker (point-min)))
                 (section
                  (my-codex--xref-items-section
                   "Definitions"
                   (list
                    (xref-make
                     "alpha"
                     (xref-make-buffer-location
                      (current-buffer)
                      (marker-position marker))))
                   root
                   1
                   1)))
            (should (string-match-p "definitions:" section))
            (should (string-match-p "excerpt: |" section))
            (should (string-match-p "(defun alpha" section))))
      (delete-directory root t))))

(ert-deftest my-codex-dynamic-helper-buffer-names-support-active-agent ()
  (let* ((root "/mock/project")
         (my-codex-agent-profiles
          '((codex
             :label "Codex"
             :buffer-prefix "codex")
            (antigravity
             :label "Antigravity"
             :buffer-prefix "agy")))
         (my-codex--project-active-agents (make-hash-table :test #'equal)))
    (puthash (file-name-as-directory "/mock/project") 'antigravity
             my-codex--project-active-agents)
    (should
     (string-prefix-p "*Antigravity prompt preview:"
                      (my-codex--prompt-preview-buffer-name root)))
    (should
     (string-prefix-p "*Antigravity GitHub issue:"
                      (my-codex--github-issue-output-buffer-name root)))
    (should
     (string-prefix-p "*Antigravity open issues:"
                      (my-codex--github-issue-list-buffer-name root)))
    (should
     (string-prefix-p "*Antigravity GitHub issue draft:"
                      (my-codex--github-issue-draft-buffer-name root)))))

(provide 'my-codex-test)

;;; my-codex-test.el ends here
