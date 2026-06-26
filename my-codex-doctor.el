;;; my-codex-doctor.el --- Diagnostics for my-codex -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Manlio Morini

;; This file is not part of GNU Emacs.

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at https://mozilla.org/MPL/2.0/.

;;; Code:

(require 'project)
(require 'seq)
(require 'subr-x)
(require 'my-codex-core)
(require 'my-codex-vterm)

(defvar my-codex-agent)
(defvar my-codex-project-build-command)
(defvar my-codex-read-only-command)
(defvar my-codex-resume-command)
(defvar my-codex-workspace-command)
(defvar my-codex-antigravity-read-only-command)
(defvar my-codex-antigravity-workspace-command)
(defvar my-codex-antigravity-resume-command)
(defvar vterm-max-scrollback)

(defcustom my-codex-doctor-terminal-timeout 3
  "Seconds to wait for a diagnostic vterm process to start."
  :type 'number
  :group 'my-codex)

(declare-function my-codex--agent-command "my-codex-core" (agent access-mode))
(declare-function my-codex-project-root "my-codex-core" ())
(declare-function vterm-mode "vterm" ())

(defface my-codex-doctor-info-face
  '((t :inherit font-lock-doc-face))
  "Face used for INFO labels in `my-codex-doctor'.")

(defface my-codex-doctor-warn-face
  '((t :inherit warning))
  "Face used for WARN labels in `my-codex-doctor'.")

(defface my-codex-doctor-fail-face
  '((t :inherit error))
  "Face used for FAIL labels in `my-codex-doctor'.")

(defun my-codex--version>= (version minimum)
  "Return non-nil when VERSION is greater than or equal to MINIMUM."
  (not (version< version minimum)))

(defun my-codex--doctor-command-assignment-token-p (token)
  "Return non-nil when TOKEN is a shell environment assignment."
  (and (stringp token)
       (string-match-p "\\`[[:alpha:]_][[:alnum:]_]*=" token)))

(defun my-codex--doctor-command-executable-token (command)
  "Return the executable shell token in COMMAND, or nil."
  (when (and (stringp command)
             (not (string-blank-p command)))
    (let ((tokens (ignore-errors (split-string-shell-command command))))
      (while (and tokens
                  (my-codex--doctor-command-assignment-token-p (car tokens)))
        (setq tokens (cdr tokens)))
      (when (member (car tokens) '("command" "exec"))
        (setq tokens (cdr tokens))
        (while (and tokens
                    (string-prefix-p "-" (car tokens)))
          (when (member (car tokens) '("-a"))
            (setq tokens (cdr tokens)))
          (setq tokens (cdr tokens))))
      (when (and tokens (string= (car tokens) "env"))
        (setq tokens (cdr tokens))
        (while (and tokens
                    (or (my-codex--doctor-command-assignment-token-p (car tokens))
                        (string-prefix-p "-" (car tokens))))
          (when (member (car tokens) '("-u" "--unset" "-C" "--chdir"))
            (setq tokens (cdr tokens)))
          (setq tokens (cdr tokens))))
      (car tokens))))

(defun my-codex--doctor-command-status (label command)
  "Return a diagnostic row for configured shell COMMAND named LABEL."
  (let* ((token (my-codex--doctor-command-executable-token command))
         (available (and token (executable-find token))))
    (list (format "command: %s" label)
          (cond
           (available 'ok)
           (token 'warn)
           (t 'fail))
          (cond
           (available (format "%s (program found at %s)" command available))
           (token (format "%s (program `%s' not found)" command token))
           (t "Not configured")))))

(defun my-codex--doctor-process-output (program &rest args)
  "Run PROGRAM with ARGS and return a cons of exit status and output."
  (with-temp-buffer
    (let ((status (apply #'process-file program nil t nil args)))
      (cons status (string-trim (buffer-string))))))

(defun my-codex--doctor-require-vterm ()
  "Return a cons describing whether `vterm' can be loaded.
The car is non-nil when loading succeeds.  The cdr is a diagnostic detail."
  (condition-case err
      (if (require 'vterm nil t)
          (cons t (format "Loaded from %s"
                          (or (locate-library "vterm") "load-path")))
        (cons nil "Cannot load vterm"))
    (error
     (cons nil (error-message-string err)))))

(defun my-codex--doctor-terminal-start ()
  "Return a diagnostic row describing whether a vterm process starts."
  (let ((buffer (generate-new-buffer " *my-codex-doctor-vterm*"))
        process)
    (unwind-protect
        (condition-case err
            (with-current-buffer buffer
              (vterm-mode)
              (let ((deadline (+ (float-time)
                                 my-codex-doctor-terminal-timeout)))
                (while (and (not (process-live-p (get-buffer-process buffer)))
                            (< (float-time) deadline))
                  (accept-process-output nil 0.05)))
              (setq process (get-buffer-process buffer))
              (if (process-live-p process)
                  (list "terminal startup" 'ok
                        (format "vterm process `%s' is live"
                                (process-name process)))
                (list "terminal startup" 'fail
                      "vterm-mode did not create a live process")))
          (error
           (list "terminal startup" 'fail
                 (error-message-string err))))
      (when (process-live-p process)
        (delete-process process))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun my-codex--doctor-vterm-scrollback (vterm-loadable)
  "Return a diagnostic row for Codex vterm scrollback settings.
VTERM-LOADABLE is non-nil when `vterm' can be loaded."
  (cond
   ((null my-codex-vterm-min-scrollback)
    (list "Codex vterm scrollback" 'warn
          "Scrollback floor is disabled; marked output can be truncated"))
   ((< my-codex-vterm-min-scrollback 10000)
    (list "Codex vterm scrollback" 'warn
          (format "Floor is %s lines; recommended minimum is 10000"
                  my-codex-vterm-min-scrollback)))
   ((and vterm-loadable (boundp 'vterm-max-scrollback)
         (numberp vterm-max-scrollback)
         (< vterm-max-scrollback my-codex-vterm-min-scrollback))
    (list "Codex vterm scrollback" 'ok
          (format "Codex buffers raise %s to %s lines"
                  vterm-max-scrollback
                  my-codex-vterm-min-scrollback)))
   ((and vterm-loadable (boundp 'vterm-max-scrollback)
         (numberp vterm-max-scrollback))
    (list "Codex vterm scrollback" 'ok
          (format "Effective floor is %s lines"
                  (max vterm-max-scrollback
                       my-codex-vterm-min-scrollback))))
   (vterm-loadable
    (list "Codex vterm scrollback" 'warn
          "Cannot inspect vterm-max-scrollback"))
   (t
    (list "Codex vterm scrollback" 'warn
          "Skipped; vterm cannot be loaded"))))

(defun my-codex--doctor-toml-string-value (line key)
  "Return KEY's TOML string value from LINE, or nil."
  (when (string-match
         (format "\\`[[:space:]]*%s[[:space:]]*=[[:space:]]*\\([\"']\\)\\([^\"']+\\)\\1"
                 (regexp-quote key))
         line)
    (match-string 2 line)))

(defun my-codex--doctor-toml-integer-value (line key)
  "Return KEY's TOML integer value from LINE, or nil."
  (when (string-match
         (format "\\`[[:space:]]*%s[[:space:]]*=[[:space:]]*\\([0-9][0-9_]*\\)"
                 (regexp-quote key))
         line)
    (string-to-number (string-replace "_" "" (match-string 1 line)))))

(defun my-codex--doctor-toml-profile-table (line)
  "Return the Codex profile name from a TOML table LINE, or nil."
  (when (string-match
         "\\`[[:space:]]*\\[profiles\\.\\(?:\"\\([^\"]+\\)\"\\|'\\([^']+\\)'\\|\\([[:alnum:]_.-]+\\)\\)\\][[:space:]]*\\(?:#.*\\)?\\'"
         line)
    (or (match-string 1 line)
        (match-string 2 line)
        (match-string 3 line))))

(defun my-codex--doctor-codex-effective-service-tier ()
  "Return the effective Codex CLI service_tier in the current buffer.
The result is a cons of (TIER . SOURCE), or nil when unset."
  (let (active-profile top-tier top-source profile-tiers current-profile
                       (current-section 'top))
    (goto-char (point-min))
    (while (not (eobp))
      (let ((line (buffer-substring-no-properties
                   (line-beginning-position)
                   (line-end-position))))
        (cond
         ((or (string-blank-p line)
              (string-match-p "\\`[[:space:]]*#" line)))
         ((string-match-p "\\`[[:space:]]*\\[" line)
          (setq current-profile
                (my-codex--doctor-toml-profile-table line))
          (setq current-section (if current-profile 'profile 'other)))
         ((eq current-section 'profile)
          (when-let ((tier (my-codex--doctor-toml-string-value
                            line "service_tier")))
            (setf (alist-get current-profile profile-tiers nil nil #'equal)
                  tier)))
         ((eq current-section 'top)
          (when-let ((profile (my-codex--doctor-toml-string-value
                               line "profile")))
            (setq active-profile profile))
          (when-let ((tier (my-codex--doctor-toml-string-value
                            line "service_tier")))
            (setq top-tier tier)
            (setq top-source "top level")))))
      (forward-line 1))
    (if-let* ((active-profile)
              (tier (alist-get active-profile profile-tiers nil nil #'equal)))
        (cons tier (format "profile %S" active-profile))
      (when top-tier
        (cons top-tier top-source)))))

(defun my-codex--doctor-codex-effective-integer-setting (key)
  "Return the effective Codex CLI integer setting KEY in the current buffer.
The result is a cons of (VALUE . SOURCE), or nil when unset."
  (let (active-profile top-value top-source profile-values current-profile
                       (current-section 'top))
    (goto-char (point-min))
    (while (not (eobp))
      (let ((line (buffer-substring-no-properties
                   (line-beginning-position)
                   (line-end-position))))
        (cond
         ((or (string-blank-p line)
              (string-match-p "\\`[[:space:]]*#" line)))
         ((string-match-p "\\`[[:space:]]*\\[" line)
          (setq current-profile
                (my-codex--doctor-toml-profile-table line))
          (setq current-section (if current-profile 'profile 'other)))
         ((eq current-section 'profile)
          (when-let ((value (my-codex--doctor-toml-integer-value line key)))
            (setf (alist-get current-profile profile-values nil nil #'equal)
                  value)))
         ((eq current-section 'top)
          (when-let ((profile (my-codex--doctor-toml-string-value
                               line "profile")))
            (setq active-profile profile))
          (when-let ((value (my-codex--doctor-toml-integer-value line key)))
            (setq top-value value)
            (setq top-source "top level")))))
      (forward-line 1))
    (if-let* ((active-profile)
              (value (alist-get active-profile profile-values nil nil #'equal)))
        (cons value (format "profile %S" active-profile))
      (when top-value
        (cons top-value top-source)))))

(defun my-codex--doctor-codex-config-file ()
  "Return the Codex CLI config file path."
  (expand-file-name
   "config.toml"
   (or (and-let* ((home (getenv "CODEX_HOME")))
         (unless (string-empty-p home) home))
       (expand-file-name ".codex" "~"))))

(defun my-codex--doctor-codex-service-tier (&optional file)
  "Return a diagnostic row for the Codex CLI service tier in FILE.
When FILE is nil, inspect `CODEX_HOME'/config.toml or ~/.codex/config.toml."
  (let ((config-file (or file (my-codex--doctor-codex-config-file))))
    (cond
     ((not (file-exists-p config-file))
      (list "Codex service_tier" 'ok
            "Not configured; Codex default applies"))
     ((not (file-readable-p config-file))
      (list "Codex service_tier" 'warn
            (format "Cannot read %s" config-file)))
     (t
      (with-temp-buffer
        (insert-file-contents config-file)
        (if-let ((tier-source
                  (my-codex--doctor-codex-effective-service-tier)))
            (let ((tier (car tier-source))
                  (source (cdr tier-source)))
              (if (string= tier "fast")
                  (list "Codex service_tier" 'warn
                        (format "fast in %s uses priority processing and increases costs; use it only when lower latency is worth it"
                                source))
                (list "Codex service_tier" 'ok
                      (format "Configured as %S in %s" tier source))))
          (list "Codex service_tier" 'ok
                "Not configured; Codex default applies")))))))

(defun my-codex--doctor-grouped-number (number)
  "Return NUMBER formatted with comma digit grouping."
  (let ((text (number-to-string number)))
    (while (string-match "\\([0-9]+\\)\\([0-9][0-9][0-9]\\)" text)
      (setq text (replace-match "\\1,\\2" nil nil text)))
    text))

(defun my-codex--doctor-codex-integer-setting
    (key label &optional unit file)
  "Return a diagnostic row for Codex integer setting KEY.
LABEL is the row label.  UNIT, when non-nil, is appended to configured values.
When FILE is nil, inspect `CODEX_HOME'/config.toml or ~/.codex/config.toml."
  (let ((config-file (or file (my-codex--doctor-codex-config-file))))
    (cond
     ((not (file-exists-p config-file))
      (list label 'ok "default applies"))
     ((not (file-readable-p config-file))
      (list label 'warn (format "Cannot read %s" config-file)))
     (t
      (with-temp-buffer
        (insert-file-contents config-file)
        (if-let ((value-source
                  (my-codex--doctor-codex-effective-integer-setting key)))
            (let ((value (my-codex--doctor-grouped-number
                          (car value-source))))
              (list label 'ok
                    (if unit
                        (format "%s %s" value unit)
                      value)))
          (list label 'ok "default applies")))))))

(defun my-codex--doctor-codex-context-rows (&optional file)
  "Return diagnostic rows for Codex context-related config in FILE."
  (list
   (my-codex--doctor-codex-integer-setting
    "tool_output_token_limit" "Codex tool_output_token_limit" "tokens" file)
   (my-codex--doctor-codex-integer-setting
    "model_auto_compact_token_limit" "Codex model_auto_compact_token_limit"
    "tokens" file)
   (my-codex--doctor-codex-integer-setting
    "project_doc_max_bytes" "Codex project_doc_max_bytes" "bytes" file)))

(defun my-codex--doctor-rows ()
  "Return diagnostic rows for `my-codex-doctor'."
  (let* ((root (my-codex-project-root))
         (project (project-current nil default-directory))
         (agent-cmd (my-codex--agent-command my-codex-agent 'read-only))
         (agent-exec (my-codex--doctor-command-executable-token agent-cmd))
         (agent-path (and agent-exec (executable-find agent-exec)))
         (git (executable-find "git"))
         (gh (executable-find "gh"))
         (vterm-status (my-codex--doctor-require-vterm))
         (vterm-loadable (car vterm-status)))
    (append
     (list
      (list "Emacs version"
            (if (my-codex--version>= emacs-version "29.1") 'ok 'fail)
            (format "%s (requires 29.1 or newer)" emacs-version))
      (list (format "%s executable" (or agent-exec (symbol-name my-codex-agent)))
            (if agent-path 'ok 'fail)
            (or agent-path "Not found in exec-path"))
      (if agent-path
          (pcase-let ((`(,status . ,output)
                       (my-codex--doctor-process-output
                        agent-exec "--version")))
            (list (format "%s --version" agent-exec)
                  (if (eq status 0) 'ok 'fail)
                  (if (string-empty-p output)
                      (format "Exited with status %s and no output" status)
                    output)))
        (list (format "%s --version" (or agent-exec "agent"))
              'fail
              (format "Skipped; %s not found" (or agent-exec "executable"))))
      (list "vterm package"
            (if vterm-loadable 'ok 'fail)
            (cdr vterm-status))
      (list "vterm backend"
            (cond
             ((featurep 'vterm-module) 'ok)
             ((and vterm-loadable (fboundp 'vterm-mode)) 'warn)
             (t 'fail))
            (cond
             ((featurep 'vterm-module) "Native module loaded")
             ((and vterm-loadable (fboundp 'vterm-mode))
              "vterm-mode is available; backend will be confirmed by startup check")
             (t "vterm-mode is unavailable")))
      (my-codex--doctor-vterm-scrollback vterm-loadable)
      (list "Git executable"
            (if git 'ok 'fail)
            (or git "Not found in exec-path"))
      (if git
          (pcase-let ((`(,status . ,output)
                       (my-codex--doctor-process-output
                        "git" "--version")))
            (list "Git version"
                  (if (eq status 0) 'ok 'fail)
                  (if (string-empty-p output)
                      (format "Exited with status %s and no output" status)
                    output)))
        (list "Git version" 'fail "Skipped; git not found"))
      (list "GitHub CLI executable"
            (if gh 'ok 'warn)
            (or gh "Not found in exec-path; GitHub issue commands will fail"))
      (if gh
          (pcase-let ((`(,status . ,output)
                       (my-codex--doctor-process-output
                        "gh" "--version")))
            (list "gh --version"
                  (if (eq status 0) 'ok 'warn)
                  (if (string-empty-p output)
                      (format "Exited with status %s and no output" status)
                    (car (split-string output "\n")))))
        (list "gh --version" 'warn "Skipped; gh not found"))
      (list "current directory is a project"
            (if project 'ok 'warn)
            (if project
                (format "Project root: %s" (project-root project))
              (format "No project detected; using %s" root)))
      (list "AGENTS.md"
            (if (file-exists-p (expand-file-name "AGENTS.md" root))
                'ok
              'warn)
            (if (file-exists-p (expand-file-name "AGENTS.md" root))
                (expand-file-name "AGENTS.md" root)
              (format "Not found in %s" root)))
      (my-codex--doctor-codex-service-tier))
     (my-codex--doctor-codex-context-rows)
     (list
      (my-codex--doctor-command-status
       (format "agent %s read-only" my-codex-agent)
       (my-codex--agent-command my-codex-agent 'read-only))
      (my-codex--doctor-command-status
       (format "agent %s workspace" my-codex-agent)
       (my-codex--agent-command my-codex-agent 'workspace-write))
      (my-codex--doctor-command-status
       (format "agent %s resume" my-codex-agent)
       (my-codex--agent-command my-codex-agent 'resume))
      (list "command: project build"
            (if my-codex-project-build-command 'ok 'warn)
            (or my-codex-project-build-command
                (format "Uses compile-command: %s"
                        compile-command)))
      (if vterm-loadable
          (my-codex--doctor-terminal-start)
        (list "terminal startup" 'fail
              "Skipped; vterm cannot be loaded"))))))

(defun my-codex--doctor-status-label (status)
  "Return display label for diagnostic STATUS."
  (let ((label (pcase status
                 ('ok "OK")
                 ('warn "WARN")
                 ('fail "FAIL")
                 (_ "INFO"))))
    (pcase status
      ('warn (propertize label 'face 'my-codex-doctor-warn-face))
      ('fail (propertize label 'face 'my-codex-doctor-fail-face))
      ('ok label)
      (_ (propertize label 'face 'my-codex-doctor-info-face)))))

(defun my-codex--doctor-insert-row (row)
  "Insert diagnostic ROW in the current buffer."
  (pcase-let ((`(,check ,status ,detail) row))
    (insert (format "%-34s %-5s %s\n"
                    check
                    (my-codex--doctor-status-label status)
                    detail))))

;;;###autoload
(defun my-codex-doctor ()
  "Run a health check for the local Codex Emacs integration."
  (interactive)
  (let ((buffer (get-buffer-create "*my-codex-doctor*"))
        (root default-directory)
        rows)
    (setq rows (my-codex--doctor-rows))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "my-codex doctor\nDirectory: %s\n\n" root))
        (insert (format "%-34s %-5s %s\n" "Check" "State" "Details"))
        (insert (make-string 78 ?-) "\n")
        (mapc #'my-codex--doctor-insert-row rows))
      (special-mode))
    (display-buffer buffer)
    (if (seq-some (lambda (row) (eq (cadr row) 'fail)) rows)
        (message "my-codex doctor finished with failures")
      (message "my-codex doctor finished"))))

(provide 'my-codex-doctor)

;;; my-codex-doctor.el ends here
