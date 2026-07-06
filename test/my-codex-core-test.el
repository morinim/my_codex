;;; my-codex-core-test.el --- Tests for my-codex -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Code:

(require 'ert)
(require 'my-codex)
(require 'my-codex-vterm)

(ert-deftest my-codex-require-keeps-optional-modules-lazy ()
  (let* ((script '(progn
                    (setq load-prefer-newer t)
                    (require 'my-codex)
                    (prin1
                     (mapcar #'featurep
                             '(my-codex-prompts my-codex-diagnostics my-codex-git
                               my-codex-github my-codex-links my-codex-ui
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
    (should (equal output "(nil nil nil nil nil nil nil nil)"))))

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
                        my-codex-explain-diagnostic-at-point
                        my-codex-explain-buffer-diagnostics
                        my-codex--ensure-vterm-scrollback
                        my-codex-top)))))
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
                   (concat "(\"my-codex-prompts\" \"my-codex-prompts\" "
                           "\"my-codex-diagnostics\" "
                           "\"my-codex-diagnostics\" \"my-codex-vterm\" "
                           "\"my-codex-ui\")")))))

(ert-deftest my-codex-command-catalogue-commands-exist ()
  (dolist (entry my-codex-command-catalogue)
    (should (fboundp (plist-get entry :command)))))

(ert-deftest my-codex-command-catalogue-commands-exist-after-clean-require ()
  (let* ((script '(progn
                    (setq load-prefer-newer t)
                    (require 'my-codex)
                    (prin1
                     (cl-every (lambda (entry)
                                 (fboundp (plist-get entry :command)))
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
      (let* ((command (plist-get entry :command))
             (prefix (or (plist-get entry :prefix)
                         'my-codex-transient))
             (binding (cons prefix
                            (key-description (kbd (plist-get entry :key)))))
             (existing (gethash binding bindings)))
        (should (or (not existing) (eq existing command)))
        (puthash binding command bindings)))))

(ert-deftest my-codex-command-catalogue-menu-entries-have-help ()
  (dolist (entry my-codex-command-catalogue)
    (when (plist-get entry :menu)
      (should (plist-get entry :help)))))

(ert-deftest my-codex-easy-menu-includes-contextual-right-command ()
  (let* ((entry (cl-find 'my-codex-send-region-or-current-file
                         my-codex-command-catalogue
                         :key (lambda (item) (plist-get item :command))))
         (menu (my-codex--catalogue-easy-menu)))
    (should (equal (plist-get entry :menu-key) "Right"))
    (should (string-match-p "Send region or inspect current file"
                            (prin1-to-string menu)))
    (should (string-match-p "F8 Right" (prin1-to-string menu)))))

(ert-deftest my-codex-command-catalogue-hides-region-from-transient-only ()
  (let ((entry (cl-find 'my-codex-send-region my-codex-command-catalogue
                        :key (lambda (item) (plist-get item :command)))))
    (should (plist-member entry :transient))
    (should-not (plist-get entry :transient))
    (should (equal (plist-get entry :menu) "Send selected region"))
    (should (eq (keymap-lookup my-codex-map "s") 'my-codex-send-region)))
  (let ((layout (my-codex--catalogue-transient-layout
                 'my-codex-transient)))
    (should
     (cl-loop for group in layout
              never (cl-loop for index from 1 below (length group)
                             thereis (equal (car (aref group index))
                                            "s"))))))

(ert-deftest my-codex-command-catalogue-groups-review-and-git-bindings ()
  (should (eq (keymap-lookup my-codex-map "r")
              'my-codex-git-review-transient))
  (should (eq (keymap-lookup my-codex-map "g")
              'my-codex-git-transient))
  (dolist (key '("v" "V" "d" "D"))
    (should-not (keymap-lookup my-codex-map key)))
  (dolist (entry '((my-codex-resume my-codex-session-transient "r")
                   (my-codex-send-git-diff my-codex-git-review-transient "a")
                   (my-codex-show-git-diff my-codex-git-transient "v")))
    (pcase-let ((`(,command ,prefix ,key) entry))
      (should
       (cl-find-if
        (lambda (item)
          (and (eq (plist-get item :command) command)
               (eq (plist-get item :prefix) prefix)
               (equal (plist-get item :key) key)))
        my-codex-command-catalogue)))))

(ert-deftest my-codex-command-catalogue-groups-code-examination-bindings ()
  (should (eq (keymap-lookup my-codex-map "x")
              'my-codex-examine-transient))
  (dolist (key '("f" "F" "C"))
    (should-not (keymap-lookup my-codex-map key)))
  (dolist (entry '((my-codex-explain-symbol-at-point "s")
                   (my-codex-review-defun-at-point "f")
                   (my-codex-send-current-file "F")
                   (my-codex-analyse-test-coverage "C")))
    (pcase-let ((`(,command ,key) entry))
      (should
       (cl-find-if
        (lambda (item)
          (and (eq (plist-get item :command) command)
               (eq (plist-get item :prefix) 'my-codex-examine-transient)
               (equal (plist-get item :key) key)))
        my-codex-command-catalogue)))))

(ert-deftest my-codex-command-catalogue-validator-rejects-unknown-property ()
  (should-error
   (my-codex--validate-command-catalogue
    '((:command ignore :key "x" :commmand ignore)))
   :type 'error))

(ert-deftest my-codex-command-catalogue-validator-rejects-incomplete-transient-entry ()
  (should-error
   (my-codex--validate-command-catalogue
    '((:command ignore :key "x" :label "Ignore")))
   :type 'error))

(ert-deftest my-codex-command-catalogue-validator-rejects-unknown-predicate ()
  (should-error
   (my-codex--validate-command-catalogue
    '((:command ignore :key "x" :available my-codex--missing-predicate)) t)
   :type 'error))

(ert-deftest my-codex-command-catalogue-byte-compiles-with-autoloaded-predicates ()
  (let ((destination (make-temp-file "my-codex-" nil ".elc")))
    (unwind-protect
        (let ((byte-compile-dest-file-function (lambda (_) destination)))
          (should (byte-compile-file
                   (expand-file-name "my-codex.el" default-directory))))
      (delete-file destination))))

(ert-deftest my-codex-send-region-or-current-file-sends-active-region ()
  (let (called)
    (cl-letf (((symbol-function 'use-region-p) (lambda () t))
              ((symbol-function 'my-codex-send-region)
               (lambda (&rest _) (interactive) (setq called 'region)))
              ((symbol-function 'my-codex-send-current-file)
               (lambda () (interactive) (setq called 'file))))
      (my-codex-send-region-or-current-file)
      (should (eq called 'region)))))

(ert-deftest my-codex-send-region-or-current-file-sends-current-file-without-region ()
  (let (called)
    (cl-letf (((symbol-function 'use-region-p) (lambda () nil))
              ((symbol-function 'my-codex-send-region)
               (lambda (&rest _) (interactive) (setq called 'region)))
              ((symbol-function 'my-codex-send-current-file)
               (lambda () (interactive) (setq called 'file))))
      (my-codex-send-region-or-current-file)
      (should (eq called 'file)))))

(ert-deftest my-codex-agent-selection-available-requires-agent-window ()
  (let ((my-codex--captured-selection "selected"))
    (cl-letf (((symbol-function 'my-codex--selected-window-is-codex-p)
               (lambda () nil)))
      (should-not (my-codex--agent-selection-available-p)))))

(ert-deftest my-codex-agent-selection-available-accepts-captured-text ()
  (let ((my-codex--captured-selection "selected"))
    (cl-letf (((symbol-function 'my-codex--selected-window-is-codex-p)
               (lambda () t)))
      (should (my-codex--agent-selection-available-p)))))

(ert-deftest my-codex-agent-selection-available-requires-text ()
  (let ((my-codex--captured-selection nil))
    (cl-letf (((symbol-function 'my-codex--selected-window-is-codex-p)
               (lambda () t))
              ((symbol-function 'use-region-p) (lambda () nil)))
      (should-not (my-codex--agent-selection-available-p)))))

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

(ert-deftest my-codex-define-agent-adds-profile-with-defaults ()
  (let (my-codex-agent-profiles)
    (should
     (eq (my-codex-define-agent
          'example
          :commands '((read-only . "example --read-only")
                      (workspace-write . "example")
                      (resume . "example resume"))
          :instruction-files '("EXAMPLE.md"))
         'example))
    (should (equal (my-codex--agent-label 'example) "Example"))
    (should (equal (my-codex--agent-buffer-prefix 'example) "example"))
    (should (equal (my-codex--agent-command 'example 'resume)
                   "example resume"))
    (should (equal (plist-get (my-codex--agent-profile 'example)
                              :instruction-strategy)
                   'root-all))))

(ert-deftest my-codex-define-agent-replaces-profile ()
  (let ((my-codex-agent-profiles '((example :label "Old"))))
    (my-codex-define-agent
     'example :label "New" :buffer-prefix "new"
     :commands '((read-only . "new --read-only")
                 (workspace-write . "new")))
    (should (= (length my-codex-agent-profiles) 1))
    (should (equal (my-codex--agent-label 'example) "New"))))

(ert-deftest my-codex-define-agent-rejects-invalid-profile ()
  (let (my-codex-agent-profiles)
    (should-error
     (my-codex-define-agent
      nil :commands '((read-only . "example"))))
    (should-error (my-codex-define-agent 'example :commands nil))
    (should-error
     (my-codex-define-agent
      'example :commands '((unknown . "example"))))))

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

(ert-deftest my-codex-read-session-access-mode-shows-completions ()
  (let (setup-hook-ran)
    (cl-letf (((symbol-function 'minibuffer-completion-help)
               (lambda () (setq setup-hook-ran t)))
              ((symbol-function 'completing-read)
               (lambda (&rest _args)
                 (run-hooks 'minibuffer-setup-hook)
                 "read-only")))
      (should (eq (my-codex--read-session-access-mode) 'read-only))
      (should setup-hook-ran))))

(ert-deftest my-codex-access-mode-labels-highlight-risk ()
  (should (equal (my-codex--access-mode-label 'workspace-write t)
                 "WORKSPACE WRITE"))
  (should (equal (my-codex--access-mode-label 'read-only t)
                 "read-only [lock]")))

(ert-deftest my-codex-agent-command-reads-profile-commands ()
  (let ((my-codex-agent-profiles
         '((codex :commands
                  ((read-only . "codex-ro")
                   (workspace-write . "codex-ww")
                   (resume . "codex-resume")))
           (antigravity :commands
                        ((read-only . "agy-ro")
                         (workspace-write . "agy-ww")
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

(ert-deftest my-codex-session-action-reads-profile-capability ()
  (let ((my-codex-agent-profiles
         (quote ((codex :session-actions ((compact . "/compact")))
                 (antigravity :label "Antigravity")))))
    (should (equal (my-codex--session-action (quote codex) (quote compact))
                   "/compact"))
    (should-not
     (my-codex--session-action (quote antigravity) (quote compact)))))

(ert-deftest my-codex-compact-session-uses-active-session-agent ()
  (let ((buffer (generate-new-buffer " *my-codex-compact-test*"))
        (my-codex-agent-profiles
         (quote ((codex :session-actions ((compact . "/compact")))
                 (antigravity :label "Antigravity"))))
        sent)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq-local my-codex-session-agent (quote codex)))
          (cl-letf (((symbol-function (quote my-codex-active-session-buffer))
                     (lambda (&optional _require-live) buffer))
                    ((symbol-function (quote my-codex-send-prompt))
                     (lambda (prompt target)
                       (setq sent (list prompt target)))))
            (my-codex-compact-session)
            (should (equal sent (list "/compact" buffer)))))
      (kill-buffer buffer))))

(ert-deftest my-codex-compact-session-rejects-unsupported-agent ()
  (let ((buffer (generate-new-buffer " *my-codex-compact-test*"))
        (my-codex-agent-profiles (quote ((antigravity :label "Antigravity")))))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq-local my-codex-session-agent (quote antigravity)))
          (cl-letf (((symbol-function (quote my-codex-active-session-buffer))
                     (lambda (&optional _require-live) buffer)))
            (should-error (my-codex-compact-session) :type (quote user-error))))
      (kill-buffer buffer))))

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

(ert-deftest my-codex-backend-factory-defaults-to-vterm ()
  (let* ((my-codex-terminal-backend 'vterm)
         (backend (my-codex--make-backend "*agent*")))
    (should (my-codex-vterm-backend-p backend))
    (should (equal (my-codex-backend-buffer-name backend) "*agent*"))))

(ert-deftest my-codex-backend-factory-rejects-unknown-backend ()
  (let ((my-codex-terminal-backend 'unknown))
    (should-error (my-codex--make-backend "*agent*")
                  :type 'user-error)))

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
    (should (equal (my-codex--shell-command-and-exit "codex")
                   "codex\nstatus=$?\nexit $status"))))

(ert-deftest my-codex-shell-command-and-exit-uses-cmd-errorlevel ()
  (my-codex-test-with-vterm-shell "C:\\Windows\\System32\\cmd.exe"
    (should (equal (my-codex--shell-command-and-exit "codex")
                   "codex\nexit %ERRORLEVEL%"))))

(ert-deftest my-codex-shell-command-and-exit-uses-powershell-status ()
  (my-codex-test-with-vterm-shell "C:\\Program Files\\PowerShell\\7\\pwsh.exe"
    (should
     (equal (my-codex--shell-command-and-exit "codex")
            (concat "codex\n"
                    "if ($LASTEXITCODE -ne $null) { exit $LASTEXITCODE }\n"
                    "if ($?) { exit 0 } else { exit 1 }")))))

(ert-deftest my-codex-global-mode-preserves-pre-existing-services ()
  (let ((my-codex-enable-display-defaults nil)
        (my-codex-enable-global-auto-revert t)
        (my-codex-enable-vterm-integration t)
        (global-auto-revert-mode t)
        (my-codex-vterm-integration-mode t)
        (my-codex--auto-revert-enabled-by-mode nil)
        (my-codex--vterm-integration-enabled-by-mode nil)
        calls)
    (cl-letf (((symbol-function 'global-auto-revert-mode)
               (lambda (arg) (push (cons 'auto-revert arg) calls)))
              ((symbol-function 'my-codex-vterm-integration-mode)
               (lambda (arg) (push (cons 'vterm arg) calls))))
      (my-codex-global-mode 1)
      (my-codex-global-mode -1)
      (should-not calls))))

(provide 'my-codex-core-test)

;;; my-codex-core-test.el ends here
