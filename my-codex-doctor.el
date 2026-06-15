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

(defvar my-codex-doctor-terminal-timeout)
(defvar my-codex-project-build-command)
(defvar my-codex-read-only-command)
(defvar my-codex-resume-command)
(defvar my-codex-workspace-command)

(declare-function my-codex-project-root "my-codex" ())
(declare-function vterm-mode "vterm" ())

(defun my-codex--ensure-main-package ()
  "Load `my-codex' when this file was entered through an autoload."
  (unless (featurep 'my-codex)
    (require 'my-codex)))

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

(defun my-codex--doctor-rows ()
  "Return diagnostic rows for `my-codex-doctor'."
  (let* ((root (my-codex-project-root))
         (project (project-current nil default-directory))
         (codex (executable-find "codex"))
         (git (executable-find "git"))
         (gh (executable-find "gh"))
         (vterm-status (my-codex--doctor-require-vterm))
         (vterm-loadable (car vterm-status)))
    (append
     (list
      (list "Emacs version"
            (if (my-codex--version>= emacs-version "29.1") 'ok 'fail)
            (format "%s (requires 29.1 or newer)" emacs-version))
      (list "codex executable"
            (if codex 'ok 'fail)
            (or codex "Not found in exec-path"))
      (if codex
          (pcase-let ((`(,status . ,output)
                       (my-codex--doctor-process-output
                        "codex" "--version")))
            (list "codex --version"
                  (if (eq status 0) 'ok 'fail)
                  (if (string-empty-p output)
                      (format "Exited with status %s and no output" status)
                    output)))
        (list "codex --version" 'fail "Skipped; codex not found"))
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
              (format "Not found in %s" root))))
     (list
      (my-codex--doctor-command-status
       "read-only" my-codex-read-only-command)
      (my-codex--doctor-command-status
       "workspace" my-codex-workspace-command)
      (my-codex--doctor-command-status
       "resume" my-codex-resume-command)
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
  (pcase status
    ('ok "OK")
    ('warn "WARN")
    ('fail "FAIL")
    (_ "INFO")))

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
  (my-codex--ensure-main-package)
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
