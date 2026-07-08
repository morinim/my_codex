;;; my-codex-eat-test.el --- Tests for my-codex-eat -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Code:

(require 'ert)
(require 'my-codex)
(require 'my-codex-eat)

(defvar explicit-shell-file-name)
(defvar eat-term-scrollback-size)

(defmacro my-codex-test-with-eat-shell (shell &rest body)
  "Bind Eat's default shell inputs so SHELL is selected while running BODY."
  (declare (indent 1))
  `(let ((explicit-shell-file-name ,shell)
         (process-environment
          (cons "ESHELL=" process-environment))
         (shell-file-name "/bin/sh"))
     ,@body))

(ert-deftest my-codex-eat-loads-without-external-eat ()
  (let* ((script '(progn
                    (setq load-prefer-newer t)
                    (require 'my-codex-eat)
                    (prin1 (featurep 'eat))))
         (output
          (with-temp-buffer
            (let ((exit-code
                   (call-process invocation-name nil t nil
                                 "--batch" "-Q" "-L" default-directory
                                 "--eval" (prin1-to-string script))))
              (unless (zerop exit-code)
                (error "Nested Emacs failed: %s" (buffer-string)))
              (buffer-string)))))
    (should (equal output "nil"))))

(ert-deftest my-codex-backend-factory-selects-eat ()
  (let* ((my-codex-terminal-backend 'eat)
         (backend (my-codex--make-backend "*agent*")))
    (should (my-codex-eat-backend-p backend))
    (should (equal (my-codex-backend-buffer-name backend) "*agent*"))))

(ert-deftest my-codex-start-eat-buffer-passes-resolved-shell ()
  (let (eat-args
        (caller-buffer (generate-new-buffer " *my-codex-eat-caller*")))
    (cl-letf (((symbol-function 'require) (lambda (&rest _args) t))
              ((symbol-function 'eat)
               (lambda (&rest args)
                 (setq eat-args args)
                 (get-buffer-create eat-buffer-name))))
      (unwind-protect
          (let ((explicit-shell-file-name "")
                (process-environment
                 (cons "ESHELL=" process-environment))
                (shell-file-name "/bin/sh"))
            (with-current-buffer caller-buffer
              (let ((buffer (my-codex--start-eat-buffer
                             "*my-codex-eat-start-test*" default-directory)))
                (should (equal eat-args '("/bin/sh")))
                (should (equal (buffer-name buffer)
                               "*my-codex-eat-start-test*"))
                (should-not (eq buffer caller-buffer)))))
        (when (buffer-live-p caller-buffer)
          (kill-buffer caller-buffer))
        (when-let ((buffer (get-buffer "*my-codex-eat-start-test*")))
          (kill-buffer buffer))))))

(ert-deftest my-codex-start-eat-buffer-replaces-layout-placeholder ()
  (let ((buffer-name "*my-codex-eat-placeholder-test*")
        eat-buffer)
    (unwind-protect
        (let ((placeholder (get-buffer-create buffer-name)))
          (set-window-buffer (selected-window) placeholder)
          (cl-letf (((symbol-function 'require) (lambda (&rest _args) t))
                    ((symbol-function 'eat)
                     (lambda (&rest _args)
                       (setq eat-buffer
                             (generate-new-buffer "*my-codex-eat-fresh*")))))
            (let ((buffer (my-codex--start-eat-buffer
                           buffer-name default-directory)))
              (should (eq buffer eat-buffer))
              (should (equal (buffer-name buffer) buffer-name))
              (should (eq (get-buffer buffer-name) buffer))
              (should (eq (window-buffer (selected-window)) buffer))
              (should-not (buffer-live-p placeholder)))))
      (dolist (buffer (buffer-list))
        (when (or (equal (buffer-name buffer) buffer-name)
                  (string-prefix-p "*my-codex-eat-fresh*" (buffer-name buffer)))
          (kill-buffer buffer))))))

(ert-deftest my-codex-eat-backend-send-pastes-multiline-prompt ()
  (let* ((buffer-name "*my-codex-eat-send-test*")
         (buffer (get-buffer-create buffer-name))
         (backend (my-codex--make-eat-backend buffer-name))
         calls)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq-local eat-terminal 'test-terminal)
            (setq-local my-codex-session-prompt-count 0))
          (cl-letf (((symbol-function 'get-buffer-process)
                     (lambda (candidate)
                       (and (eq candidate buffer) 'test-process)))
                    ((symbol-function 'eat-term-send-string-as-yank)
                     (lambda (terminal string)
                       (push (list :yank terminal string) calls)))
                    ((symbol-function 'eat-term-input-event)
                     (lambda (terminal count event)
                       (push (list :input-event terminal count event) calls)))
                    ((symbol-function 'eat-term-send-string)
                     (lambda (terminal string)
                       (push (list :send terminal string) calls))))
            (my-codex-backend-send backend "line one\nline two")
            (should
             (equal (nreverse calls)
                    '((:yank test-terminal "line one\nline two")
                      (:input-event test-terminal 1 return))))
            (with-current-buffer buffer
              (should (equal my-codex-session-prompt-count 1)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest my-codex-eat-command-and-exit-uses-posix-status ()
  (my-codex-test-with-eat-shell "/bin/zsh"
    (should (equal (my-codex--eat-command-and-exit "codex")
                   "codex\nstatus=$?\nexit $status"))))

(ert-deftest my-codex-eat-command-and-exit-uses-cmd-errorlevel ()
  (my-codex-test-with-eat-shell "C:\\Windows\\System32\\cmd.exe"
    (should (equal (my-codex--eat-command-and-exit "codex")
                   "codex\nexit %ERRORLEVEL%"))))

(ert-deftest my-codex-eat-command-and-exit-uses-powershell-status ()
  (my-codex-test-with-eat-shell "C:\\Program Files\\PowerShell\\7\\pwsh.exe"
    (should
     (equal (my-codex--eat-command-and-exit "codex")
            (concat "codex\n"
                    "if ($LASTEXITCODE -ne $null) { exit $LASTEXITCODE }\n"
                    "if ($?) { exit 0 } else { exit 1 }")))))

(ert-deftest my-codex-eat-shell-name-prefers-eshell-over-shell-file-name ()
  (let ((explicit-shell-file-name nil)
        (process-environment
         (cons "ESHELL=C:\\Windows\\System32\\cmd.exe" process-environment))
        (shell-file-name "/bin/sh"))
    (should (equal (my-codex--eat-command-and-exit "codex")
                   "codex\nexit %ERRORLEVEL%"))))

(ert-deftest my-codex-eat-shell-name-falls-back-to-shell-file-name ()
  (let ((explicit-shell-file-name nil)
        (process-environment
         (cons "ESHELL=" process-environment))
        (shell-file-name "C:\\Program Files\\PowerShell\\7\\pwsh.exe"))
    (should
     (equal (my-codex--eat-command-and-exit "codex")
            (concat "codex\n"
                    "if ($LASTEXITCODE -ne $null) { exit $LASTEXITCODE }\n"
                    "if ($?) { exit 0 } else { exit 1 }")))))

(ert-deftest my-codex-eat-scrollback-floor-raises-low-value ()
  (let ((my-codex-eat-min-scrollback 1000000))
    (should (equal (my-codex--eat-scrollback-floor 100) 1000000))))

(ert-deftest my-codex-eat-scrollback-floor-allows-unlimited ()
  (let ((my-codex-eat-min-scrollback nil))
    (should-not (my-codex--eat-scrollback-floor 100))))

(ert-deftest my-codex-eat-integration-ignores-non-agent-eat-buffers ()
  (with-temp-buffer
    (let ((major-mode 'eat-mode))
      (my-codex--enable-eat-buffer-integration)
      (should-not (bound-and-true-p my-codex-eat-override-mode)))))

(ert-deftest my-codex-eat-override-mode-provides-local-keys ()
  (with-temp-buffer
    (let ((major-mode 'eat-mode)
          (my-codex-session-id "test-session"))
      (unwind-protect
          (progn
            (my-codex--enable-eat-buffer-integration)
            (should (bound-and-true-p my-codex-eat-override-mode))
            (should (eq (key-binding (kbd "<f8>"))
                        #'my-codex-transient-preserve-selection)))
        (my-codex--disable-eat-buffer-integration)))))

(provide 'my-codex-eat-test)

;;; my-codex-eat-test.el ends here
