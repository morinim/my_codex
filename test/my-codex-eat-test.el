;;; my-codex-eat-test.el --- Tests for my-codex-eat -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Code:

(require 'ert)
(require 'my-codex)
(require 'my-codex-eat)
(require 'my-codex-links)

(defvar explicit-shell-file-name)
(defvar eat-term-scrollback-size)
(defvar eat-buffer-name)
(declare-function eat-self-input "eat")

(defmacro my-codex-test-with-eat-shell (shell &rest body)
  "Bind Eat's default shell inputs so SHELL is selected while running BODY."
  (declare (indent 1))
  `(let ((explicit-shell-file-name ,shell)
         (process-environment
          (cons "ESHELL=" process-environment))
         (shell-file-name "/bin/sh"))
     ,@body))

(cl-defmacro my-codex-test-with-captured-eat-refresh
    ((callback arguments timer-count) &rest body)
  "Run BODY while capturing Eat refresh CALLBACK and ARGUMENTS.
Set TIMER-COUNT to the number of timers created."
  (declare (indent 1))
  `(let (,callback ,arguments (,timer-count 0))
     (cl-letf (((symbol-function 'run-with-timer)
                (lambda (delay repeat function &rest args)
                  (should (= delay my-codex--eat-link-refresh-delay))
                  (should-not repeat)
                  (cl-incf ,timer-count)
                  (setq ,callback function)
                  (setq ,arguments args)
                  (timer-create))))
       ,@body)))

(defun my-codex-test-eat-link-overlays ()
  "Return my-codex Eat link overlays in the current buffer."
  (cl-remove-if-not
   (lambda (overlay)
     (overlay-get overlay 'my-codex-eat-link))
   (overlays-in (point-min) (point-max))))

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
            (should (eq (key-binding (kbd "RET"))
                        #'my-codex-eat-open-link-or-fallback-at-point))
            (should (eq (key-binding (kbd "<mouse-1>"))
                        #'my-codex-eat-open-link-or-fallback-at-event))
            (should (eq (key-binding (kbd "<f8>"))
                        #'my-codex-transient-preserve-selection)))
        (my-codex--disable-eat-buffer-integration)))))

(ert-deftest my-codex-eat-ret-opens-link-at-point ()
  (let (opened-url)
    (with-temp-buffer
      (insert "https://example.invalid")
      (let ((major-mode 'eat-mode)
            (my-codex-session-id "test-session"))
        (cl-letf (((symbol-function 'browse-url)
                   (lambda (url &rest _args)
                     (setq opened-url url))))
          (my-codex-session-links-mode 1)
          (my-codex--enable-eat-buffer-integration)
          (goto-char (point-min))
          (my-codex-eat-open-link-or-fallback-at-point)
          (should (equal opened-url "https://example.invalid")))))))

(ert-deftest my-codex-eat-update-linkifies-output-with-inhibited-hooks ()
  (with-temp-buffer
    (let ((my-codex-session-id "test-session"))
      (my-codex-session-links-mode 1)
      (let ((inhibit-modification-hooks t))
        (insert "https://example.invalid"))
      (goto-char (point-min))
      (should-not (get-text-property (point) 'my-codex-session-link-type))
      (my-codex--eat-linkify-after-update)
      (should
       (eq (get-text-property (point) 'my-codex-session-link-type)
           'url)))))

(ert-deftest my-codex-eat-link-refresh-coalesces-updates ()
  (with-temp-buffer
    (let ((my-codex-session-links-mode t)
          (my-codex--eat-link-refresh-enabled t)
          (eat-terminal nil))
      (my-codex-test-with-captured-eat-refresh
          (callback arguments timer-count)
        (let ((refresh-count 0))
          (cl-letf (((symbol-function 'my-codex--eat-linkify-after-update)
                     (lambda (&rest _args)
                       (cl-incf refresh-count))))
            (dotimes (_ 3)
              (my-codex--eat-schedule-link-refresh))
            (should (= timer-count 1))
            (apply callback arguments)
            (should (= refresh-count 1))))))))

(ert-deftest my-codex-eat-disable-cancels-pending-link-refresh ()
  (with-temp-buffer
    (let ((my-codex-session-id "test-session")
          (eat-terminal nil))
      (insert "https://example.invalid")
      (my-codex-session-links-mode 1)
      (my-codex--eat-linkify-after-update)
      (setq my-codex--eat-link-refresh-enabled t)
      (my-codex-test-with-captured-eat-refresh
          (callback arguments timer-count)
        (my-codex--eat-schedule-link-refresh)
        (should (= timer-count 1))
        (should (my-codex-test-eat-link-overlays))
        (my-codex--disable-eat-session-links)
        (should-not my-codex--eat-link-refresh-enabled)
        (should-not my-codex--eat-link-refresh-timer)
        (should-not my-codex--eat-link-dirty-beg)
        (should-not my-codex--eat-link-dirty-end)
        (should-not (my-codex-test-eat-link-overlays))
        (apply callback arguments)
        (should-not (my-codex-test-eat-link-overlays))))))

(ert-deftest my-codex-eat-killed-buffer-ignores-pending-link-refresh ()
  (let ((buffer (generate-new-buffer " *my-codex-eat-pending*")))
    (unwind-protect
        (my-codex-test-with-captured-eat-refresh
            (callback arguments timer-count)
          (with-current-buffer buffer
            (setq-local my-codex-session-links-mode t)
            (setq-local my-codex--eat-link-refresh-enabled t)
            (add-hook 'kill-buffer-hook
                      #'my-codex--eat-cancel-link-refresh nil t)
            (my-codex--eat-schedule-link-refresh))
          (should (= timer-count 1))
          (kill-buffer buffer)
          (should-not (buffer-live-p buffer))
          (should-not (apply callback arguments)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest my-codex-eat-scrollback-truncation-removes-stale-overlays ()
  (with-temp-buffer
    (let ((my-codex-session-id "test-session")
          (eat-terminal nil))
      (insert "https://old.example.invalid\nplain terminal row\n")
      (my-codex-session-links-mode 1)
      (my-codex--eat-linkify-after-update)
      (let ((stale-overlay (car (my-codex-test-eat-link-overlays))))
        (should stale-overlay)
        (setq my-codex--eat-link-refresh-enabled t)
        (my-codex-test-with-captured-eat-refresh
            (callback arguments timer-count)
          (my-codex--eat-schedule-link-refresh)
          (should (= timer-count 1))
          (let ((inhibit-modification-hooks t))
            (delete-region (point-min)
                           (save-excursion
                             (goto-char (point-min))
                             (forward-line 1)
                             (point))))
          (apply callback arguments)
          (should-not (overlay-buffer stale-overlay))
          (should-not (my-codex-test-eat-link-overlays)))))))

(ert-deftest my-codex-eat-link-split-across-updates-becomes-clickable ()
  (with-temp-buffer
    (let ((my-codex-session-id "test-session")
          (my-codex--eat-link-refresh-enabled t)
          (eat-terminal nil))
      (my-codex-session-links-mode 1)
      (my-codex-test-with-captured-eat-refresh
          (callback arguments timer-count)
        (let ((inhibit-modification-hooks t))
          (insert "https://example.")
          (my-codex--eat-schedule-link-refresh)
          (insert "invalid")
          (my-codex--eat-schedule-link-refresh))
        (should (= timer-count 1))
        (apply callback arguments)
        (goto-char (point-min))
        (should (eq (get-text-property
                     (point) 'my-codex-session-link-type)
                    'url))
        (should (equal (get-text-property
                        (point) 'my-codex-session-link-target)
                       "https://example.invalid"))
        (should (my-codex-test-eat-link-overlays))))))

(ert-deftest my-codex-eat-row-update-removes-disappeared-link ()
  (with-temp-buffer
    (let ((my-codex-session-id "test-session")
          (my-codex--eat-link-refresh-enabled t)
          (eat-terminal nil))
      (insert "https://old.example.invalid\n"
              "https://kept.example.invalid\n")
      (my-codex-session-links-mode 1)
      (my-codex--eat-linkify-after-update)
      (my-codex-test-with-captured-eat-refresh
          (callback arguments timer-count)
        (let ((inhibit-modification-hooks t))
          (goto-char (point-min))
          (delete-region (line-beginning-position) (line-end-position))
          (insert "plain terminal row"))
        (my-codex--eat-schedule-link-refresh)
        (should (= timer-count 1))
        (apply callback arguments)
        (goto-char (point-min))
        (should-not (get-text-property
                     (point) 'my-codex-session-link-type))
        (should-not (cl-find-if
                     (lambda (overlay)
                       (overlay-get overlay 'my-codex-eat-link))
                     (overlays-at (point))))
        (forward-line 1)
        (should (eq (get-text-property
                     (point) 'my-codex-session-link-type)
                    'url))
        (should (cl-find-if
                 (lambda (overlay)
                   (overlay-get overlay 'my-codex-eat-link))
                 (overlays-at (point))))))))

(ert-deftest my-codex-eat-update-linkifies-before-session-metadata ()
  (with-temp-buffer
    (my-codex-session-links-mode 1)
    (let ((inhibit-modification-hooks t))
      (insert "https://example.invalid"))
    (goto-char (point-min))
    (should-not (get-text-property (point) 'my-codex-session-link-type))
    (my-codex--eat-linkify-after-update)
    (should
     (eq (get-text-property (point) 'my-codex-session-link-type)
         'url))))

(ert-deftest my-codex-eat-update-linkifies-in-place-redraw ()
  (with-temp-buffer
    (let ((my-codex-session-id "test-session"))
      (insert "xxxxxxxxxxxxxxxxxxxxxxx")
      (my-codex-session-links-mode 1)
      (let ((inhibit-modification-hooks t))
        (delete-region (point-min) (point-max))
        (insert "https://example.invalid"))
      (goto-char (point-min))
      (should-not (get-text-property (point) 'my-codex-session-link-type))
      (my-codex--eat-linkify-after-update)
      (should
       (eq (get-text-property (point) 'my-codex-session-link-type)
           'url)))))

(ert-deftest my-codex-eat-update-applies-visible-link-overlay ()
  (with-temp-buffer
    (let ((my-codex-session-id "test-session"))
      (my-codex-session-links-mode 1)
      (let ((inhibit-modification-hooks t))
        (insert (propertize "https://example.invalid" 'face 'shadow)))
      (my-codex--eat-linkify-after-update)
      (goto-char (point-min))
      (let ((overlay (cl-find-if
                      (lambda (overlay)
                        (overlay-get overlay 'my-codex-eat-link))
                      (overlays-at (point)))))
        (should overlay)
        (should (eq (overlay-get overlay 'face) 'link))
        (should (eq (overlay-get overlay 'keymap)
                    my-codex-session-link-map)))
      (let ((inhibit-modification-hooks t))
        (delete-region (point-min) (point-max))
        (insert (propertize "xxxxxxxxxxxxxxxxxxxxxxx" 'face 'shadow)))
      (my-codex--eat-linkify-after-update)
      (goto-char (point-min))
      (should (eq (get-text-property (point) 'face) 'shadow))
      (should-not (cl-find-if
                   (lambda (overlay)
                     (overlay-get overlay 'my-codex-eat-link))
                   (overlays-at (point))))
      (should-not (get-text-property (point) 'my-codex-session-link-type)))))

(ert-deftest my-codex-eat-update-clears-overlays-when-links-disabled ()
  (with-temp-buffer
    (let ((my-codex-session-id "test-session"))
      (insert "https://example.invalid")
      (my-codex-session-links-mode 1)
      (my-codex--enable-eat-session-links)
      (my-codex--eat-linkify-after-update)
      (goto-char (point-min))
      (should
       (cl-find-if
        (lambda (overlay)
          (overlay-get overlay 'my-codex-eat-link))
        (overlays-at (point))))
      (my-codex-session-links-mode -1)
      (should-not
       (cl-find-if
        (lambda (overlay)
          (overlay-get overlay 'my-codex-eat-link))
        (overlays-at (point)))))))

(ert-deftest my-codex-eat-output-boundary-workaround-ignores-end-of-chunk ()
  (let ((output "\e[ "))
    (should-not
     (my-codex--eat-term-process-output-advice
      (lambda (_terminal string)
        (signal 'args-out-of-range (list string (length string))))
      'terminal output))))

(ert-deftest my-codex-eat-output-boundary-workaround-preserves-other-errors ()
  (let ((output "\e[ "))
    (should-error
     (my-codex--eat-term-process-output-advice
      (lambda (_terminal string)
        (signal 'args-out-of-range (list string 1)))
     'terminal output)
     :type 'args-out-of-range)))

(ert-deftest my-codex-eat-output-boundary-workaround-preserves-range-errors ()
  (let ((output "\e[ "))
    (should-error
     (my-codex--eat-term-process-output-advice
      (lambda (_terminal string)
        (signal 'args-out-of-range
                (list string (length string) (1+ (length string)))))
      'terminal output)
     :type 'args-out-of-range)))

(ert-deftest my-codex-eat-integration-enables-session-link-updates ()
  (cl-letf (((symbol-function 'eat--process-output-queue)
             (lambda (_buffer))))
    (unwind-protect
        (with-temp-buffer
          (let ((major-mode 'eat-mode)
                (my-codex-session-id "test-session"))
            (my-codex-session-links-mode 1)
            (my-codex--enable-eat-buffer-integration)
            (should
             (advice-member-p #'my-codex--eat-process-output-queue-advice
                              'eat--process-output-queue))))
      (advice-remove 'eat--process-output-queue
                     #'my-codex--eat-process-output-queue-advice))))

(ert-deftest my-codex-eat-session-links-install-output-advice ()
  (cl-letf (((symbol-function 'eat--process-output-queue)
             (lambda (_buffer))))
    (unwind-protect
        (with-temp-buffer
          (my-codex--enable-eat-session-links)
          (should
           (advice-member-p #'my-codex--eat-process-output-queue-advice
                            'eat--process-output-queue)))
      (advice-remove 'eat--process-output-queue
                     #'my-codex--eat-process-output-queue-advice))))

(ert-deftest my-codex-eat-prebound-legacy-hook-uses-output-advice ()
  (cl-progv '(eat-update-hook) '((external-refresh))
    (cl-letf (((symbol-function 'featurep)
               (lambda (feature) (eq feature 'eat)))
              ((symbol-function 'eat--process-output-queue)
               (lambda (_buffer)))
              ((get 'eat-update-hook 'custom-type) nil)
              ((get 'eat-update-hook 'variable-documentation) nil))
      (unwind-protect
          (with-temp-buffer
            (my-codex--enable-eat-session-links)
            (should
             (advice-member-p #'my-codex--eat-process-output-queue-advice
                              'eat--process-output-queue)))
        (advice-remove 'eat--process-output-queue
                       #'my-codex--eat-process-output-queue-advice)))))

(ert-deftest my-codex-eat-bound-update-hook-needs-no-custom-type ()
  (cl-progv '(eat-update-hook) '(nil)
    (cl-letf (((symbol-function 'featurep)
               (lambda (feature) (eq feature 'eat)))
              ((get 'eat-update-hook 'custom-type) nil)
              ((get 'eat-update-hook 'variable-documentation)
               "Hook run after an Eat terminal is updated."))
      (with-temp-buffer
        (my-codex--enable-eat-session-links)
        (should
         (memq #'my-codex--eat-schedule-link-refresh
               (symbol-value 'eat-update-hook)))))))

(ert-deftest my-codex-eat-process-output-advice-linkifies-buffer ()
  (let ((buffer (generate-new-buffer " *my-codex-eat-advice*")))
    (unwind-protect
        (with-current-buffer buffer
          (let ((my-codex-session-id "test-session"))
            (my-codex-session-links-mode 1)
            (let ((inhibit-modification-hooks t))
              (insert "https://example.invalid"))
            (goto-char (point-min))
            (should-not
             (get-text-property (point) 'my-codex-session-link-type))
            (my-codex--eat-process-output-queue-advice buffer)
            (should
             (eq (get-text-property (point) 'my-codex-session-link-type)
                 'url))))
      (kill-buffer buffer))))

(ert-deftest my-codex-eat-linkifies-existing-buffer-content ()
  (with-temp-buffer
    (let ((my-codex-session-id "test-session"))
      (insert "src/kernel/evolution_strategy.tcc:211")
      (my-codex-session-links-mode 1)
      (my-codex--eat-linkify-after-update)
      (goto-char (point-min))
      (should
       (eq (get-text-property (point) 'my-codex-session-link-type)
           'file))
      (should
       (cl-find-if
        (lambda (overlay)
          (overlay-get overlay 'my-codex-eat-link))
        (overlays-at (point)))))))

(ert-deftest my-codex-eat-ret-falls-back-away-from-link ()
  (let (fallback-called)
    (with-temp-buffer
      (let ((map (make-sparse-keymap))
            (major-mode 'eat-mode)
            (my-codex-session-id "test-session"))
        (define-key map (kbd "RET")
                    (lambda ()
                      (interactive)
                      (setq fallback-called t)))
        (use-local-map map)
        (my-codex--enable-eat-buffer-integration)
        (my-codex-eat-open-link-or-fallback-at-point)
        (should fallback-called)))))

(ert-deftest my-codex-eat-mouse-fallback-preserves-eat-arguments ()
  (let ((clicked-buffer (generate-new-buffer " *my-codex-clicked-eat*"))
        (selected-buffer (generate-new-buffer " *my-codex-selected-eat*"))
        fallback-args
        fallback-buffer)
    (cl-letf (((symbol-function 'eat-self-input)
               (lambda (n &optional e)
                 (setq fallback-args (list n e))
                 (setq fallback-buffer (current-buffer)))))
      (unwind-protect
          (save-window-excursion
            (let ((clicked-window (split-window-right)))
              (set-window-buffer (selected-window) selected-buffer)
              (set-window-buffer clicked-window clicked-buffer)
              (with-current-buffer selected-buffer
                (let ((map (make-sparse-keymap)))
                  (define-key map [mouse-1]
                              (lambda (&rest _args)
                                (setq fallback-buffer (current-buffer))))
                  (use-local-map map)))
              (with-current-buffer clicked-buffer
                (insert "abc")
                (add-text-properties
                 1 2
                 `(my-codex-session-link-type url
                   keymap ,my-codex-session-link-map))
                (goto-char 1)
                (let ((map (make-sparse-keymap))
                      (major-mode 'eat-mode)
                      (my-codex-session-id "test-session"))
                  (define-key map [mouse-1] #'eat-self-input)
                  (use-local-map map)
                  (my-codex--enable-eat-buffer-integration)))
              (let ((event (list 'mouse-1
                                 (list clicked-window 3 '(0 . 0)
                                       0 nil 3 nil nil))))
                (with-current-buffer selected-buffer
                  (my-codex-eat-open-link-or-fallback-at-event event))
                (should (equal fallback-args (list 1 event)))
                (should (eq fallback-buffer clicked-buffer)))))
        (kill-buffer clicked-buffer)
        (kill-buffer selected-buffer)))))

(ert-deftest my-codex-eat-mouse-fallback-passes-event-to-generic-command ()
  (let ((clicked-buffer (generate-new-buffer " *my-codex-clicked-generic*"))
        (selected-buffer (generate-new-buffer " *my-codex-selected-generic*"))
        fallback-event
        fallback-buffer)
    (unwind-protect
        (save-window-excursion
          (let ((clicked-window (split-window-right)))
            (set-window-buffer (selected-window) selected-buffer)
            (set-window-buffer clicked-window clicked-buffer)
            (with-current-buffer clicked-buffer
              (insert "abc")
              (let ((map (make-sparse-keymap))
                    (major-mode 'eat-mode)
                    (my-codex-session-id "test-session"))
                (define-key map [mouse-1]
                            (lambda (event)
                              (interactive "e")
                              (setq fallback-event event)
                              (setq fallback-buffer (current-buffer))))
                (use-local-map map)
                (my-codex--enable-eat-buffer-integration)))
            (let ((event (list 'mouse-1
                               (list clicked-window 2 '(0 . 0)
                                     0 nil 2 nil nil))))
              (with-current-buffer selected-buffer
                (my-codex-eat-open-link-or-fallback-at-event event))
              (should (eq fallback-event event))
              (should (eq fallback-buffer clicked-buffer)))))
      (kill-buffer clicked-buffer)
      (kill-buffer selected-buffer))))

(provide 'my-codex-eat-test)

;;; my-codex-eat-test.el ends here
