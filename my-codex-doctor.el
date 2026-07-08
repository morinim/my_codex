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

(defvar my-codex-agent)
(defvar my-codex-project-build-command)
(defvar vterm-max-scrollback)
(defvar eat-buffer-name)
(defvar eat-term-scrollback-size)

(defcustom my-codex-doctor-terminal-timeout 3
  "Seconds to wait for a diagnostic vterm process to start."
  :type 'number
  :group 'my-codex)

(defconst my-codex--doctor-codex-project-doc-default-bytes (* 32 1024)
  "Codex's default maximum size for project instruction files.")

(declare-function vterm-mode "vterm" ())
(declare-function eat "eat" (&optional program new-session))
(autoload 'my-codex--eat-shell-name "my-codex-eat")

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

(defun my-codex--doctor-require-eat ()
  "Return a cons describing whether Eat can be loaded.
The car is non-nil when loading succeeds.  The cdr is a diagnostic detail."
  (condition-case err
      (if (require 'eat nil t)
          (cons t (format "Loaded from %s"
                          (or (locate-library "eat") "load-path")))
        (cons nil "Cannot load Eat"))
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

(defun my-codex--doctor-eat-terminal-start ()
  "Return a diagnostic row describing whether an Eat process starts."
  (let ((buffer (generate-new-buffer " *my-codex-doctor-eat*"))
        process)
    (unwind-protect
        (condition-case err
            (let ((eat-buffer-name (buffer-name buffer)))
              (with-current-buffer buffer
                (eat (my-codex--eat-shell-name))
                (let ((deadline (+ (float-time)
                                   my-codex-doctor-terminal-timeout)))
                  (while (and (not (process-live-p
                                    (get-buffer-process buffer)))
                              (< (float-time) deadline))
                    (accept-process-output nil 0.05)))
                (setq process (get-buffer-process buffer))
                (if (process-live-p process)
                    (list "terminal startup" 'ok
                          (format "Eat process `%s' is live"
                                  (process-name process)))
                  (list "terminal startup" 'fail
                        "Eat did not create a live process"))))
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

(defun my-codex--doctor-eat-scrollback (eat-loadable)
  "Return a diagnostic row for Codex Eat scrollback settings.
EAT-LOADABLE is non-nil when Eat can be loaded."
  (cond
   ((null my-codex-eat-min-scrollback)
    (list "Codex Eat scrollback" 'ok
          "Unlimited scrollback configured"))
   ((< my-codex-eat-min-scrollback 100000)
    (list "Codex Eat scrollback" 'warn
          (format "Floor is %s characters; recommended minimum is 100000"
                  my-codex-eat-min-scrollback)))
   ((and eat-loadable (boundp 'eat-term-scrollback-size)
         (numberp eat-term-scrollback-size)
         (< eat-term-scrollback-size my-codex-eat-min-scrollback))
    (list "Codex Eat scrollback" 'ok
          (format "Codex buffers raise %s to %s characters"
                  eat-term-scrollback-size
                  my-codex-eat-min-scrollback)))
   ((and eat-loadable (boundp 'eat-term-scrollback-size)
         (numberp eat-term-scrollback-size))
    (list "Codex Eat scrollback" 'ok
          (format "Effective floor is %s characters"
                  (max eat-term-scrollback-size
                       my-codex-eat-min-scrollback))))
   (eat-loadable
    (list "Codex Eat scrollback" 'warn
          "Cannot inspect eat-term-scrollback-size"))
   (t
    (list "Codex Eat scrollback" 'warn
          "Skipped; Eat cannot be loaded"))))

(defun my-codex--doctor-terminal-rows ()
  "Return selected terminal backend diagnostic rows."
  (pcase my-codex-terminal-backend
    ('vterm
     (let* ((vterm-status (my-codex--doctor-require-vterm))
            (vterm-loadable (car vterm-status)))
       (list
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
        (if vterm-loadable
            (my-codex--doctor-terminal-start)
          (list "terminal startup" 'fail
                "Skipped; vterm cannot be loaded")))))
    ('eat
     (let* ((eat-status (my-codex--doctor-require-eat))
            (eat-loadable (car eat-status)))
       (list
        (list "Eat package"
              (if eat-loadable 'ok 'fail)
              (cdr eat-status))
        (list "Eat backend"
              (if (and eat-loadable (fboundp 'eat)) 'ok 'fail)
              (if (and eat-loadable (fboundp 'eat))
                  "Public `eat' entry point is available"
                "Public `eat' entry point is unavailable"))
        (my-codex--doctor-eat-scrollback eat-loadable)
        (if eat-loadable
            (my-codex--doctor-eat-terminal-start)
          (list "terminal startup" 'fail
                "Skipped; Eat cannot be loaded")))))
    (backend
     (list
      (list "terminal backend" 'fail
            (format "Unknown my-codex terminal backend: %s" backend))))))

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

(defun my-codex--doctor-codex-user-service-tier ()
  "Return the Codex CLI user-level service_tier in the current buffer.
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

(defun my-codex--doctor-codex-user-integer-setting (key)
  "Return the Codex CLI user-level integer setting KEY in the current buffer.
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

(defun my-codex--doctor-codex-integer-setting-value (key &optional file)
  "Return Codex user-level integer setting KEY from FILE, or nil."
  (let ((config-file (or file (my-codex--doctor-codex-config-file))))
    (when (file-readable-p config-file)
      (with-temp-buffer
        (insert-file-contents config-file)
        (car (my-codex--doctor-codex-user-integer-setting key))))))

(defun my-codex--doctor-codex-service-tier (&optional file)
  "Return a diagnostic row for the Codex CLI service tier in FILE.
When FILE is nil, inspect `CODEX_HOME'/config.toml or ~/.codex/config.toml."
  (let ((config-file (or file (my-codex--doctor-codex-config-file))))
    (cond
     ((not (file-exists-p config-file))
      (list "Codex user config: service_tier" 'ok
            "Not found in user-level config; another configuration layer may override it"))
     ((not (file-readable-p config-file))
      (list "Codex user config: service_tier" 'warn
            (format "Cannot read %s" config-file)))
     (t
      (with-temp-buffer
        (insert-file-contents config-file)
        (if-let ((tier-source
                  (my-codex--doctor-codex-user-service-tier)))
            (let ((tier (car tier-source))
                  (source (cdr tier-source)))
              (if (string= tier "fast")
                  (list "Codex user config: service_tier" 'warn
                        (format "fast in %s uses priority processing and increases costs; use it only when lower latency is worth it"
                                source))
                (list "Codex user config: service_tier" 'ok
                      (format "Configured as %S in %s" tier source))))
          (list "Codex user config: service_tier" 'ok
                "Not found in user-level config; another configuration layer may override it")))))))

(defun my-codex--doctor-grouped-number (number)
  "Return NUMBER formatted with comma digit grouping."
  (let ((text (number-to-string number)))
    (while (string-match "\\([0-9]+\\)\\([0-9][0-9][0-9]\\)" text)
      (setq text (replace-match "\\1,\\2" nil nil text)))
    text))

(defun my-codex--doctor-byte-size (bytes)
  "Return BYTES formatted as bytes or KiB."
  (if (< bytes 1024)
      (format "%d bytes" bytes)
    (format "%.1f KiB" (/ bytes 1024.0))))

(defun my-codex--doctor-project-instructions-row (root files)
  "Return the project instruction diagnostic row for FILES under ROOT."
  (if (null files)
      (list "Project instructions" 'info
            (format "No effective files found for %s" my-codex-agent))
    (let* ((bytes (apply #'+
                         (mapcar (lambda (file)
                                   (file-attribute-size
                                    (file-attributes file)))
                                 files)))
           (allowance
            (and (eq my-codex-agent 'codex)
                 (or (my-codex--doctor-codex-integer-setting-value
                      "project_doc_max_bytes")
                     my-codex--doctor-codex-project-doc-default-bytes)))
           (status (if (and allowance (>= bytes (* allowance 0.6)))
                       'warn
                     'ok)))
      (list
       "Project instructions" status
       (concat
        (format "%s discovered across %d %s"
                (my-codex--doctor-byte-size bytes)
                (length files)
                (if (= (length files) 1) "file" "files"))
        (when allowance
          (concat
           (format "; %s allowance"
                   (my-codex--doctor-byte-size allowance))
           (when (>= bytes allowance)
             "; Codex may omit or truncate instructions")))
        ": "
        (mapconcat (lambda (file) (file-relative-name file root))
                   files ", "))))))

(defun my-codex--doctor-codex-integer-setting
    (key label &optional unit file)
  "Return a diagnostic row for Codex integer setting KEY.
LABEL is the row label.  UNIT, when non-nil, is appended to configured values.
When FILE is nil, inspect `CODEX_HOME'/config.toml or ~/.codex/config.toml."
  (let ((config-file (or file (my-codex--doctor-codex-config-file))))
    (cond
     ((not (file-exists-p config-file))
      (list label 'ok
            "Not found in user-level config; another configuration layer may override it"))
     ((not (file-readable-p config-file))
      (list label 'warn (format "Cannot read %s" config-file)))
     (t
      (with-temp-buffer
        (insert-file-contents config-file)
        (if-let ((value-source
                  (my-codex--doctor-codex-user-integer-setting key)))
            (let ((value (my-codex--doctor-grouped-number
                          (car value-source))))
              (list label 'ok
                    (if unit
                        (format "%s %s" value unit)
                      value)))
          (list label 'ok
                "Not found in user-level config; another configuration layer may override it")))))))

(defun my-codex--doctor-codex-context-rows (&optional file)
  "Return diagnostic rows for Codex context-related config in FILE."
  (list
   (my-codex--doctor-codex-integer-setting
    "tool_output_token_limit" "Codex user config: tool_output_token_limit"
    "tokens per tool/function output retained in history" file)
   (my-codex--doctor-codex-integer-setting
    "model_auto_compact_token_limit"
    "Codex user config: model_auto_compact_token_limit"
    "tokens" file)
   (my-codex--doctor-codex-integer-setting
    "project_doc_max_bytes" "Codex user config: project_doc_max_bytes"
    "bytes" file)))

(defun my-codex--doctor-codex-rows ()
  "Return Codex-specific diagnostic rows."
  (cons (my-codex--doctor-codex-service-tier)
        (my-codex--doctor-codex-context-rows)))

(defun my-codex--doctor-agent-rows (agent)
  "Return backend-specific diagnostic rows for AGENT."
  (let* ((profile (my-codex--agent-profile agent))
         (function (plist-get profile :doctor-function)))
    (when function
      (funcall function))))

(defun my-codex--doctor-rows ()
  "Return diagnostic rows for `my-codex-doctor'."
  (let* ((root (my-codex-project-root))
         (project (project-current nil default-directory))
         (agent-cmd (my-codex--agent-command my-codex-agent 'read-only))
         (agent-exec (my-codex--doctor-command-executable-token agent-cmd))
         (agent-path (and agent-exec (executable-find agent-exec)))
         (git (executable-find "git"))
         (gh (executable-find "gh")))
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
      (my-codex--doctor-project-instructions-row
       root (my-codex-project-instruction-files root)))
     (my-codex--doctor-terminal-rows)
     (my-codex--doctor-agent-rows my-codex-agent)
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
                        compile-command)))))))

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
