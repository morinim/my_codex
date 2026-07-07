;;; my-codex-prompts-test.el --- Tests for my-codex-prompts -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Code:

(require 'ert)
(require 'my-codex)
(require 'my-codex-git)
(require 'my-codex-prompts)

(ert-deftest my-codex-approx-token-count-rounds-up ()
  (should (= (my-codex--approx-token-count "") 0))
  (should (= (my-codex--approx-token-count "abc") 1))
  (should (= (my-codex--approx-token-count "abcd") 2))
  (should (= (my-codex--approx-token-count "abcde") 2))
  (should (= (my-codex--approx-token-count "é") 1)))

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

(ert-deftest my-codex-active-session-buffer-reports-missing-session ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-active" t))))
    (unwind-protect
        (let ((default-directory root))
          (cl-letf (((symbol-function 'my-codex--session-buffer)
                     (lambda () nil)))
            (condition-case err
                (progn
                  (my-codex-active-session-buffer t)
                  (ert-fail "Expected a missing-session error"))
              (user-error
               (should (equal (cadr err) "No agent session available"))))))
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

(ert-deftest my-codex-copy-region-reference-copies-formatted-reference ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-region" t)))
        kill-ring)
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "src/example.el" root))
          (insert "first\nsecond\nthird\n")
          (set-buffer-modified-p nil)
          (cl-letf (((symbol-function 'use-region-p) (lambda () t))
                    ((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'verify-visited-file-modtime)
                     (lambda (_buffer) t)))
            (my-codex-copy-region-reference (point-min) (point-max))
            (should (equal (current-kill 0)
                           "@src/example.el lines 1-3"))))
      (delete-directory root t))))

(ert-deftest my-codex-copy-region-reference-copies-current-line-without-region ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-region" t)))
        kill-ring)
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "src/example.el" root))
          (insert "first\nsecond\nthird\n")
          (goto-char (point-min))
          (forward-line 1)
          (set-buffer-modified-p nil)
          (cl-letf (((symbol-function 'use-region-p) (lambda () nil))
                    ((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'verify-visited-file-modtime)
                     (lambda (_buffer) t)))
            (my-codex-copy-region-reference nil nil)
            (should (equal (current-kill 0)
                           "@src/example.el line 2"))))
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

(ert-deftest my-codex-implement-selected-plan-uses-subject-region-context ()
  (let ((subject (generate-new-buffer " *my-codex-plan-doc*"))
        sent-prompt sent-message)
    (unwind-protect
        (with-current-buffer subject
          (insert "1. Change the parser.\n2. Add tests.\n")
          (cl-letf (((symbol-function 'my-codex--subject-buffer)
                     (lambda () subject))
                    ((symbol-function 'use-region-p) (lambda () t))
                    ((symbol-function 'region-beginning) (lambda () 1))
                    ((symbol-function 'region-end) (lambda () 22))
                    ((symbol-function 'my-codex--region-context-request)
                     (lambda (beg end)
                       (should (= beg 1))
                       (should (= end 22))
                       '("Selected region:\n\ninline plan" . "Sent inline")))
                    ((symbol-function 'my-codex--preview-and-send-prompt)
                     (lambda (prompt &optional message)
                       (setq sent-prompt prompt
                             sent-message message))))
            (my-codex-implement-selected-plan)
            (should (equal sent-prompt
                           (format "%s\n\nSelected region:\n\ninline plan"
                                   my-codex-implement-plan-prompt)))
            (should (equal sent-message "Sent inline"))))
      (kill-buffer subject))))

(ert-deftest my-codex-implement-selected-plan-uses-whole-subject-without-region ()
  (let ((subject (generate-new-buffer " *my-codex-plan-doc*"))
        sent-prompt sent-message)
    (unwind-protect
        (with-current-buffer subject
          (insert "1. Change the parser.\n2. Add tests.\n")
          (cl-letf (((symbol-function 'my-codex--subject-buffer)
                     (lambda () subject))
                    ((symbol-function 'use-region-p) (lambda () nil))
                    ((symbol-function 'my-codex--region-context-request)
                     (lambda (beg end)
                       (should (= beg (point-min)))
                       (should (= end (point-max)))
                       '("Selected region:\n\nwhole plan" . "Sent inline")))
                    ((symbol-function 'my-codex--preview-and-send-prompt)
                     (lambda (prompt &optional message)
                       (setq sent-prompt prompt
                             sent-message message))))
            (my-codex-implement-selected-plan)
            (should (equal sent-prompt
                           (format "%s\n\nSelected region:\n\nwhole plan"
                                   my-codex-implement-plan-prompt)))
            (should (equal sent-message "Sent inline"))))
      (kill-buffer subject))))

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
           (string-match "Analyze test coverage\\." prompt)))
      (should instructions-pos)
      (should context-pos)
      (should implementation-pos)
      (should test-pos)
      (should request-pos)
      (should (< instructions-pos context-pos))
      (should (< context-pos implementation-pos))
      (should (< implementation-pos test-pos))
      (should (< test-pos request-pos)))))

(ert-deftest my-codex-test-coverage-prompt-uses-agent-file-reference-format ()
  (let ((my-codex-test-coverage-prompt "Coverage instructions."))
    (should
     (string-match-p
      "implementation: src/example\\.el"
      (my-codex--test-coverage-prompt
       "src/example.el" "test/example-test.el" 'antigravity)))))

(ert-deftest my-codex-test-coverage-prompt-asks-agent-to-find-tests ()
  (let ((prompt (my-codex--test-coverage-prompt "src/example.el")))
    (should (string-match-p "implementation: @src/example\\.el" prompt))
    (should-not (string-match-p "\\n  test:" prompt))
    (should (string-match-p "Find the relevant test files" prompt))))

(ert-deftest my-codex-analyse-test-coverage-finds-tests-by-default ()
  (let (sent-prompt)
    (with-temp-buffer
      (setq buffer-file-name "/project/src/example.el")
      (cl-letf (((symbol-function 'my-codex-project-root)
                 (lambda () "/project/"))
                ((symbol-function 'my-codex--project-relative-file)
                 (lambda (&rest _args) "src/example.el"))
                ((symbol-function 'my-codex--ensure-file-reference-current)
                 #'ignore)
                ((symbol-function 'my-codex--read-test-file)
                 (lambda (&rest _args)
                   (ert-fail "Prompted for a test file")))
                ((symbol-function 'my-codex--preview-and-send-prompt)
                 (lambda (prompt) (setq sent-prompt prompt))))
        (my-codex-analyse-test-coverage)
        (should (string-match-p "Find the relevant test files" sent-prompt))))))

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
             (my-codex-analyse-test-coverage t)
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
             (my-codex-analyse-test-coverage t)
             :type 'user-error)
            (should-not sent)))
      (when (buffer-live-p test-buffer)
        (kill-buffer test-buffer))
      (delete-directory root t))))

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
                ((symbol-function 'my-codex--project-relative-file)
                 (lambda (_file _root) "src/example.el"))
                ((symbol-function 'my-codex--symbol-xref-context)
                 (lambda (_symbol _root) nil))
                ((symbol-function 'my-codex--preview-and-send-prompt)
                 (lambda (prompt) (setq sent prompt))))
        (my-codex-explain-symbol-at-point)))
    (should (string-match-p "symbol: \"alpha\"" sent))
    (should (string-match-p "location: \"src/example\\.el:1\"" sent))
    (should-not (string-match-p "excerpt: |" sent))))

(ert-deftest my-codex-explain-symbol-rejects-outside-project-file ()
  (with-temp-buffer
    (setq buffer-file-name "/outside/example.el")
    (insert "alpha")
    (goto-char (point-min))
    (cl-letf (((symbol-function 'my-codex-project-root)
               (lambda () "/repo/")))
      (should-error
       (my-codex-explain-symbol-at-point)
       :type 'user-error))))

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
                ((symbol-function 'my-codex--project-relative-file)
                 (lambda (_file _root) "src/example.el"))
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


(provide 'my-codex-prompts-test)

;;; my-codex-prompts-test.el ends here
