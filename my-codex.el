;;; my-codex.el --- Codex integration -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Manlio Morini

;; Author: Manlio Morini
;; Keywords: tools, convenience
;; URL: https://github.com/morinim/my_codex
;; Version: 0.96.0
;; Package-Requires: ((emacs "29.1") (vterm "0") (transient "0"))

;; This file is not part of GNU Emacs.

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at https://mozilla.org/MPL/2.0/.

;;; Commentary:

;; my-codex.el runs OpenAI Codex CLI or Google Antigravity inside an Emacs
;; vterm buffer.  It provides a two-column layout, project-specific agent
;; sessions, helpers for Git diffs, selected regions, diagnostics, build
;; output, and compiler or test errors.

;;; Code:

(require 'compile)
(require 'my-codex-core)
(require 'my-codex-ui)
(require 'cl-lib)
(require 'ediff)
(require 'easymenu)
(require 'project)
(require 'subr-x)
(require 'transient)

(autoload 'vterm-mode "vterm" nil t)
(autoload 'vterm-send-string "vterm")
(autoload 'vterm-send-return "vterm")
(autoload 'vterm-yank "vterm" nil t)
(autoload 'vterm-copy-mode "vterm" nil t)
(declare-function markdown-mode "markdown-mode")
(declare-function projectile-toggle-between-implementation-and-test "projectile")
(defvar vterm-copy-mode)
(defvar vterm-max-scrollback)

(defun my-codex--ensure-vterm-scrollback ()
  "Raise `vterm-max-scrollback' in the current Codex buffer when needed."
  (when (and my-codex-vterm-min-scrollback
             (boundp 'vterm-max-scrollback)
             (numberp vterm-max-scrollback)
             (< vterm-max-scrollback my-codex-vterm-min-scrollback))
    (setq-local vterm-max-scrollback my-codex-vterm-min-scrollback)))

(defun my-codex--vterm-scrollback-floor (scrollback)
  "Return SCROLLBACK raised to `my-codex-vterm-min-scrollback' when needed."
  (if (and my-codex-vterm-min-scrollback
           (numberp scrollback)
           (< scrollback my-codex-vterm-min-scrollback))
      my-codex-vterm-min-scrollback
    scrollback))

(defun my-codex--vterm-mode-with-scrollback-floor ()
  "Enable `vterm-mode' while flooring the libvterm scrollback argument."
  (require 'vterm)
  (if (and my-codex-vterm-min-scrollback
           (fboundp 'vterm--new))
      (let ((vterm--new (symbol-function 'vterm--new)))
        (cl-letf (((symbol-function 'vterm--new)
                   (lambda (height width scrollback &rest args)
                     (apply vterm--new
                            height
                            width
                            (my-codex--vterm-scrollback-floor scrollback)
                            args))))
          (vterm-mode)))
    (vterm-mode)))

(defun my-codex--track-process-output-time (process)
  "Record output timestamps for PROCESS without replacing its behaviour."
  (unless (process-get process 'my-codex-output-time-filter)
    (let ((original-filter (process-filter process)))
      (process-put process 'my-codex-output-time-filter t)
      (set-process-filter
       process
       (lambda (proc output)
         (when (and output (not (string-empty-p output)))
           (when-let (buffer (process-buffer proc))
             (with-current-buffer buffer
               (setq-local my-codex-session-last-output-time (current-time))
               (force-mode-line-update))))
         (when original-filter
           (funcall original-filter proc output)))))))

(cl-defmethod my-codex-backend-start
  ((backend my-codex-vterm-backend) project-root command
   &optional session-name agent access-mode)
  "Start BACKEND's vterm process in PROJECT-ROOT with COMMAND."
  (let* ((agent (or agent my-codex-agent))
         (access-mode
          (or access-mode (my-codex--session-access-mode command agent)))
         (default-directory project-root)
         (buffer-name (my-codex--backend-buffer-name backend))
         (buffer (get-buffer-create buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'vterm-mode)
        (my-codex--vterm-mode-with-scrollback-floor))
      (my-codex--ensure-vterm-scrollback)
      (setq-local show-trailing-whitespace nil)
      (when my-codex-enable-session-links
        (my-codex-session-links-mode 1))
      (let ((proc (get-buffer-process buffer)))
        (unless (process-live-p proc)
          (user-error "Failed to start vterm process in %s" buffer-name))
        (set-process-query-on-exit-flag proc nil)
        (my-codex--track-process-output-time proc)
        (goto-char (point-max))
        (vterm-send-string (my-codex--shell-command-and-exit command))
        (vterm-send-return)))
    (if session-name
        (my-codex--mark-named-session
         buffer session-name project-root access-mode agent)
      (my-codex--mark-default-session
       buffer project-root access-mode agent))
    buffer))

(defun my-codex--selected-window-is-codex-p ()
  "Return non-nil if the selected window shows Codex."
  (eq (selected-window)
      (ignore-errors
        (my-codex-visible-window))))

(defun my-codex--vterm-shell-name ()
  "Return the configured vterm shell executable name, if known."
  (let ((shell (or (and (boundp 'vterm-shell)
                        (let ((value (symbol-value 'vterm-shell)))
                          (and (stringp value)
                               (not (string-empty-p value))
                               value)))
                   shell-file-name
                   "")))
    (file-name-nondirectory
     (replace-regexp-in-string "\\\\" "/" shell))))

(defun my-codex--shell-command-and-exit (command)
  "Return shell text that runs COMMAND, then exits with its status."
  (let ((shell (downcase (my-codex--vterm-shell-name))))
    (cond
     ((member shell '("cmd" "cmd.exe" "cmdproxy" "cmdproxy.exe"))
      (format "%s\nexit %%ERRORLEVEL%%" command))
     ((member shell '("powershell" "powershell.exe" "pwsh" "pwsh.exe"))
      (format (concat "%s\n"
                      "if ($LASTEXITCODE -ne $null) { exit $LASTEXITCODE }\n"
                      "if ($?) { exit 0 } else { exit 1 }")
              command))
     (t
      (format "%s\nstatus=$?\nexit $status" command)))))


(defun my-codex--right-window-width (window)
  "Resize WINDOW to the target Codex width when enforcement is enabled."
  (when my-codex-enforce-right-side-layout
    (my-codex--resize-window-to-body-width
     window
     (max my-codex-min-right-width my-codex-right-width))))

(defun my-codex--display-buffer-action-alist ()
  "Return the alist part of `my-codex-display-buffer-action', if any."
  (when (and (consp my-codex-display-buffer-action)
             (listp (cdr my-codex-display-buffer-action)))
    (cdr my-codex-display-buffer-action)))

(defun my-codex--right-side-action-p ()
  "Return non-nil when Codex is configured for a right side window."
  (eq (alist-get 'side (my-codex--display-buffer-action-alist)) 'right))

(defun my-codex--right-layout-width ()
  "Return the minimum frame width for the default right-side layout."
  (+ my-codex-left-width
     (max my-codex-min-right-width my-codex-right-width)))

(defun my-codex--enforce-right-side-layout-p ()
  "Return non-nil when Codex should enforce the right-side layout."
  (and my-codex-enforce-right-side-layout
       (my-codex--right-side-action-p)))

(defun my-codex--fit-frame-to-right-layout ()
  "Widen the selected frame enough for the default right-side layout."
  (when (my-codex--enforce-right-side-layout-p)
    (let ((required-width (my-codex--right-layout-width)))
      (when (< (frame-width) required-width)
        (condition-case nil
            (progn
              (set-frame-width (selected-frame) (+ required-width 8))
              (redisplay t))
          (error nil)))
      (when (< (frame-width) required-width)
        (user-error "Frame is too narrow for agent layout")))))

(defun my-codex--resize-window-to-body-width (window width)
  "Resize WINDOW to WIDTH body columns when possible."
  (when (and (window-live-p window)
             (integerp width)
             (> width 0))
    (let ((delta (- width (window-body-width window))))
      (when (not (zerop delta))
        (ignore-errors
          (window-resize window delta t 'ignore))))))

(defun my-codex--apply-display-window-width (window)
  "Apply the configured Codex display width to WINDOW."
  (when (window-live-p window)
    (pcase (alist-get 'window-width (my-codex--display-buffer-action-alist))
      ((and width (pred integerp))
       (my-codex--resize-window-to-body-width window width))
      (`(body-columns . ,width)
       (my-codex--resize-window-to-body-width window width))
      ((and width (pred functionp))
       (funcall width window)))))

(defun my-codex--resize-edit-window-for-right-layout (edit-window term-window)
  "Keep EDIT-WINDOW wide enough for the default right-side Codex layout."
  (when (and (my-codex--enforce-right-side-layout-p)
             (window-live-p edit-window)
             (window-live-p term-window)
             (> (window-left-column term-window)
                (window-left-column edit-window))
             (< (window-body-width edit-window)
                my-codex-left-width))
    (my-codex--resize-window-to-body-width edit-window
                                            my-codex-left-width)))

(defun my-codex--refresh-edit-fill-column-indicator ()
  "Refresh the fill-column indicator after window layout changes."
  (when (and my-codex--edit-fill-column-indicator-state
             (fboundp 'display-fill-column-indicator-mode)
             (bound-and-true-p display-fill-column-indicator-mode))
    (display-fill-column-indicator-mode -1)
    (display-fill-column-indicator-mode 1)))

(defun my-codex--edit-window-codex-visible-p (window frame)
  "Return non-nil if WINDOW's Codex buffer is visible in FRAME."
  (when-let ((buffer (window-parameter window 'my-codex-term-buffer)))
    (and (buffer-live-p buffer)
         (get-buffer-window buffer frame))))

(defun my-codex--restore-edit-fill-column-indicator (buffer)
  "Restore BUFFER's fill-column indicator state saved by my-codex."
  (setq my-codex--edit-fill-column-indicator-buffers
        (delq buffer my-codex--edit-fill-column-indicator-buffers))
  (when (and (buffer-live-p buffer)
             (fboundp 'display-fill-column-indicator-mode))
    (with-current-buffer buffer
      (when my-codex--edit-fill-column-indicator-state
        (let ((mode (plist-get my-codex--edit-fill-column-indicator-state
                               :mode))
              (column-local
               (plist-get my-codex--edit-fill-column-indicator-state
                          :column-local))
              (column
               (plist-get my-codex--edit-fill-column-indicator-state
                          :column)))
          (remove-hook 'window-configuration-change-hook
                       #'my-codex--refresh-edit-fill-column-indicator
                       t)
          (if column-local
              (setq-local display-fill-column-indicator-column column)
            (kill-local-variable 'display-fill-column-indicator-column))
          (display-fill-column-indicator-mode (if mode 1 -1))
          (setq my-codex--edit-fill-column-indicator-state nil))))))

(defun my-codex--apply-edit-fill-column-indicator (window)
  "Show a fill-column indicator in WINDOW's buffer."
  (when (and (fboundp 'display-fill-column-indicator-mode)
             (window-live-p window))
    (with-current-buffer (window-buffer window)
      (unless my-codex--edit-fill-column-indicator-state
        (setq-local my-codex--edit-fill-column-indicator-state
                    (list
                     :mode
                     (bound-and-true-p display-fill-column-indicator-mode)
                     :column-local
                     (local-variable-p
                      'display-fill-column-indicator-column)
                     :column
                     display-fill-column-indicator-column)))
      (cl-pushnew (current-buffer)
                  my-codex--edit-fill-column-indicator-buffers)
      (setq-local display-fill-column-indicator-column 80)
      (add-hook 'window-configuration-change-hook
                #'my-codex--refresh-edit-fill-column-indicator
                nil
                t)
      (display-fill-column-indicator-mode 1))))

(defun my-codex--active-edit-fill-column-indicator-buffers ()
  "Return buffers shown in live Codex edit windows."
  (let (buffers)
    (dolist (frame (frame-list))
      (dolist (window (window-list frame 'no-minibuf))
        (when (and (window-parameter window 'my-codex-edit-window)
                   (my-codex--edit-window-codex-visible-p window frame))
          (cl-pushnew (window-buffer window) buffers))))
    buffers))

(defun my-codex--restore-inactive-edit-fill-column-indicator-buffers ()
  "Restore managed buffers no longer shown in a live Codex edit window."
  (let ((active-buffers
         (my-codex--active-edit-fill-column-indicator-buffers)))
    (dolist (buffer (copy-sequence
                     my-codex--edit-fill-column-indicator-buffers))
      (unless (memq buffer active-buffers)
        (my-codex--restore-edit-fill-column-indicator buffer)))))

(defun my-codex--refresh-edit-fill-column-indicator-windows (frame)
  "Apply Codex fill-column indicators to marked edit windows in FRAME."
  (dolist (window (window-list frame 'no-minibuf))
    (when (window-parameter window 'my-codex-edit-window)
      (let ((previous-buffer
             (window-parameter window 'my-codex-edit-buffer))
            (current-buffer (window-buffer window)))
        (unless (eq previous-buffer current-buffer)
          (my-codex--restore-edit-fill-column-indicator previous-buffer))
        (if (my-codex--edit-window-codex-visible-p window frame)
            (progn
              (set-window-parameter window 'my-codex-edit-buffer
                                    current-buffer)
              (my-codex--apply-edit-fill-column-indicator window))
          (my-codex--restore-edit-fill-column-indicator current-buffer)
          (my-codex--restore-edit-fill-column-indicator previous-buffer)
          (set-window-parameter window 'my-codex-edit-buffer nil)
          (set-window-parameter window 'my-codex-edit-window nil)
          (set-window-parameter window 'my-codex-term-buffer nil)))))
  (my-codex--restore-inactive-edit-fill-column-indicator-buffers))

(defun my-codex--set-edit-fill-column-indicator-window (window)
  "Mark WINDOW as the Codex edit window and update its indicator."
  (let ((previous-buffer (window-parameter window 'my-codex-edit-buffer))
        (current-buffer (window-buffer window)))
    (unless (eq previous-buffer current-buffer)
      (my-codex--restore-edit-fill-column-indicator previous-buffer))
    (set-window-parameter window 'my-codex-edit-buffer current-buffer)
    (my-codex--apply-edit-fill-column-indicator window)))

(defun my-codex--enable-edit-fill-column-indicator (edit-window term-window)
  "Show a fill-column indicator in EDIT-WINDOW."
  (when (and (fboundp 'display-fill-column-indicator-mode)
             (window-live-p edit-window)
             (window-live-p term-window)
             (not (eq (window-buffer edit-window)
                      (window-buffer term-window))))
    (set-window-parameter edit-window 'my-codex-edit-window t)
    (set-window-parameter edit-window 'my-codex-term-buffer
                          (window-buffer term-window))
    (add-hook 'window-buffer-change-functions
              #'my-codex--refresh-edit-fill-column-indicator-windows)
    (my-codex--set-edit-fill-column-indicator-window edit-window)))

(defun my-codex-two-column-layout-with-command
    (codex-command &optional focus-term session-name agent access-mode)
  "Display Codex and run CODEX-COMMAND if the backend is not running.
If FOCUS-TERM is non-nil, leave the cursor focused on the terminal window.
When SESSION-NAME is non-nil, use that named session instead of default.
AGENT identifies the agent profile used for buffer names and metadata."
  (cl-labels
      ((display-codex-buffer
        (buffer)
        (or (display-buffer buffer my-codex-display-buffer-action)
            (user-error "Failed to display %s" (buffer-name buffer)))))
    (let* ((agent (or agent (my-codex--active-agent)))
           (session-name (when session-name
                           (my-codex--normalise-session-name session-name)))
           (buffer-name (if session-name
                            (my-codex-session-buffer-name session-name agent)
                          (my-codex-current-buffer-name agent)))
           (backend (my-codex--backend-for-buffer-name buffer-name))
           (project-root (my-codex-project-root))
           (existing-buf (get-buffer buffer-name)))
      (unless session-name
        (my-codex--set-active-agent agent project-root))
      (my-codex--fit-frame-to-right-layout)

      (when (and existing-buf
                 (not (my-codex-backend-live-p backend)))
        (with-current-buffer existing-buf
          (rename-buffer
           (generate-new-buffer-name
            (format "%s<old>" buffer-name))))
        (setq existing-buf nil))

      (let* ((edit-window (selected-window))
             (term-buffer (or existing-buf
                              (get-buffer-create buffer-name)))
             (term-window (display-codex-buffer term-buffer)))
        (my-codex--apply-display-window-width term-window)
        (my-codex--resize-edit-window-for-right-layout edit-window term-window)
        (my-codex--enable-edit-fill-column-indicator edit-window term-window)
        (select-window term-window)
        (when (and existing-buf
                   (my-codex-backend-live-p backend))
          (set-window-buffer term-window existing-buf))
        (unless (and existing-buf
                     (my-codex-backend-live-p backend))
          (my-codex-backend-start
           backend project-root codex-command session-name agent access-mode))

        (if focus-term
            (select-window term-window)
          (when (window-live-p edit-window)
            (select-window edit-window)))))))

;;;###autoload
(defun my-codex-hide-window ()
  "Hide visible windows showing the current agent buffer."
  (interactive)
  (let* ((buffer (my-codex-active-session-buffer))
         (label (with-current-buffer buffer
                  (if my-codex-session-agent
                      (my-codex--agent-label my-codex-session-agent)
                    (my-codex--active-agent-label))))
         (windows (get-buffer-window-list buffer nil t)))
    (unless windows
      (user-error "%s window is not visible" label))
    (dolist (window windows)
      (when (window-live-p window)
        (quit-window nil window)))
    (message "%s window hidden" label)))

(defun my-codex--session-layout-buffer ()
  "Return the agent buffer associated with the selected session layout."
  (my-codex-active-session-buffer))

;;;###autoload
(defun my-codex-hide-session-window ()
  "Hide visible windows showing the selected agent session buffer."
  (interactive)
  (let* ((buffer (my-codex--session-layout-buffer))
         (label (with-current-buffer buffer
                  (if my-codex-session-agent
                      (my-codex--agent-label my-codex-session-agent)
                    (my-codex--active-agent-label))))
         (windows (get-buffer-window-list buffer nil t)))
    (unless windows
      (user-error "%s window is not visible" label))
    (dolist (window windows)
      (when (window-live-p window)
        (quit-window nil window)))
    (message "%s window hidden" label)))

;;;###autoload
(defun my-codex-read-only ()
  "Show the configured agent, starting it in read-only mode if needed."
  (interactive)
  (my-codex-two-column-layout-with-command
   (my-codex--agent-command my-codex-agent 'read-only)
   nil nil my-codex-agent 'read-only))

;;;###autoload
(defun my-codex-workspace ()
  "Show the configured agent with workspace write access if needed."
  (interactive)
  (my-codex-two-column-layout-with-command
   (my-codex--agent-command my-codex-agent 'workspace-write)
   nil nil my-codex-agent 'workspace-write))

;;;###autoload
(defun my-codex-default-read-only (agent)
  "Show the default AGENT session in read-only mode."
  (interactive (list (my-codex--read-agent)))
  (my-codex-two-column-layout-with-command
   (my-codex--agent-command agent 'read-only)
   nil nil agent 'read-only))

;;;###autoload
(defun my-codex-default-workspace (agent)
  "Show the default AGENT session with workspace write access."
  (interactive (list (my-codex--read-agent)))
  (my-codex-two-column-layout-with-command
   (my-codex--agent-command agent 'workspace-write)
   nil nil agent 'workspace-write))

(defun my-codex--read-session-access-mode ()
  "Read and return an access mode for a new named session."
  (pcase (completing-read
          "Session access: "
          '("read-only" "workspace-write")
          nil t nil nil "read-only")
    ("read-only" 'read-only)
    ("workspace-write" 'workspace-write)))

;;;###autoload
(defun my-codex-new-session (name agent &optional access-mode)
  "Start or show a named agent session NAME using AGENT and ACCESS-MODE."
  (interactive
   (list
    (read-string "Session name: ")
    (my-codex--read-agent)
    (my-codex--read-session-access-mode)))
  (let ((session-name (my-codex--normalise-session-name name)))
    (my-codex-two-column-layout-with-command
     (my-codex--agent-command agent access-mode)
     nil session-name agent access-mode)))

;;;###autoload
(defun my-codex-resume ()
  "Show the configured agent, resuming a previous session if needed."
  (interactive)
  (my-codex-two-column-layout-with-command
   (my-codex--agent-command my-codex-agent 'resume)
   t nil my-codex-agent 'resume))

;;;###autoload
(defun my-codex-export-session-to-markdown ()
  "Export the current project's agent session transcript to Markdown."
  (interactive)
  (let* ((buffer (my-codex-active-session-buffer))
         (root (with-current-buffer buffer
                 (or my-codex-session-project-root
                     (my-codex-project-root))))
         (transcript (my-codex-session-transcript))
         (export-buffer
          (get-buffer-create (my-codex--session-export-buffer-name root))))
    (when (string-empty-p transcript)
      (user-error "Agent session transcript is empty"))
    (with-current-buffer export-buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (my-codex--insert-session-export-markdown
         transcript root (buffer-name buffer))
        (goto-char (point-min)))
      (my-codex--session-export-mode))
    (pop-to-buffer export-buffer)
    (message "%s session exported to Markdown."
             (my-codex--active-agent-label root))))

;;;###autoload
(defun my-codex-summarize-session-to-markdown ()
  "Ask the agent to summarize the current conversation as Markdown notes.
Open the generated notes in an editable Markdown buffer when they are ready."
  (interactive)
  (let* ((buffer (my-codex-active-session-buffer t))
         (root (with-current-buffer buffer
                 (or my-codex-session-project-root
                     (my-codex-project-root)))))
    (my-codex--request-marked-output
     :name "SESSION_SUMMARY"
     :buffer buffer
     :prompt my-codex-session-summary-prompt
     :placeholder "<Markdown notes here>"
     :callback (lambda (summary)
                 (my-codex-edit-session-summary summary root))
     :timeout-message "Timed out waiting for agent session summary."
     :ready-message "Agent session summary is ready for editing."
     :poll-interval my-codex-generated-output-poll-interval
     :poll-attempts my-codex-generated-output-poll-attempts
     :timer-var 'my-codex--generated-artifact-wait-timer)
    (message "Asked %s to summarize the session; waiting to open editor."
             (my-codex--active-agent-label root))))

;; Prefix keymap for agent commands.
(defvar-keymap my-codex-map
  :doc "Prefix keymap for agent commands."
  "o"       #'my-codex-read-only
  "w"       #'my-codex-workspace
  "S"       #'my-codex-session-transient
  "r"       #'my-codex-resume
  "q"       #'my-codex-hide-window
  "a"       #'my-codex-ask
  "A"       #'my-codex-ask-preset-transient
  "s"       #'my-codex-send-region
  "<right>" #'my-codex-send-region
  "R"       #'my-codex-plan-refactor-region
  "<left>"  #'my-codex-insert-selection-into-code
  "f"       #'my-codex-review-defun-at-point
  "F"       #'my-codex-send-current-file
  "C"       #'my-codex-analyse-test-coverage
  "x"       #'my-codex-explain-symbol-at-point
  "g"       #'my-codex-send-git-diff
  "G"       #'my-codex-send-git-staged-diff
  "l"       #'my-codex-review-current-file-diff
  "v"       #'my-codex-show-git-diff
  "V"       #'my-codex-show-git-staged-diff
  "d"       #'my-codex-ediff-current-file-against-head
  "D"       #'my-codex-ediff-changed-file-against-head
  "c"       #'my-codex-git-commit-with-latest-message
  "e"       #'my-codex-explain-region-as-error
  "i"       #'my-codex-open-project-instructions
  "I"       #'my-codex-summarize-session-to-github-issue
  "M"       #'my-codex-summarize-session-to-markdown
  "t"       #'my-codex-list-open-issues
  "T"       #'my-codex-tools-transient
  "TAB"     #'my-codex-toggle-focus
  "<tab>"   #'my-codex-toggle-focus)

;;;###autoload
(transient-define-prefix my-codex-session-transient ()
  "Show agent session commands."
  [["Default session"
    ("o" "Read-only" my-codex-default-read-only)
    ("w" "Workspace" my-codex-default-workspace)]
   ["Session"
    ("l" "Dashboard" my-codex-top)
    ("n" "New named" my-codex-new-session)
    ("r" "Resume" my-codex-resume)
    ("q" "Hide agent" my-codex-hide-session-window)]])

;;;###autoload
(transient-define-prefix my-codex-diagnostics-transient ()
  "Show diagnostic explanation commands."
  [["Diagnostics"
    ("p" "At point" my-codex-explain-diagnostic-at-point)
    ("a" "All" my-codex-explain-buffer-diagnostics)]])

;;;###autoload
(transient-define-prefix my-codex-tools-transient ()
  "Show infrequent agent tools."
  [["Tools"
    ("p" "Project overview" my-codex-send-project-overview)
    ("X" "Export session" my-codex-export-session-to-markdown)
    ("E" "Diagnostics" my-codex-diagnostics-transient)
    ("!" "Doctor" my-codex-doctor)]])

;;;###autoload
(transient-define-prefix my-codex-transient ()
  "Show agent commands."
  [["Session"
    ("o" "Read-only" my-codex-read-only)
    ("w" "Workspace" my-codex-workspace)
    ("S" "Sessions" my-codex-session-transient)
    ("r" "Resume" my-codex-resume)
    ("q" "Hide agent" my-codex-hide-window)
    ("<tab>" "Toggle focus" my-codex-toggle-focus)]
   ["Send"
    ("a" "Ask" my-codex-ask)
    ("A" "Preset menu" my-codex-ask-preset-transient)
    ("s" "Region" my-codex-send-region)
    ("<right>" "Region" my-codex-send-region)
    ("R" "Refactor plan" my-codex-plan-refactor-region)
    ("<left>" "Insert selection" my-codex-insert-selection-into-code)
    ("f" "Current defun" my-codex-review-defun-at-point)
    ("F" "Current file" my-codex-send-current-file)
    ("C" "Coverage gaps" my-codex-analyse-test-coverage)
    ("x" "Explain symbol" my-codex-explain-symbol-at-point)]
   ["Git"
    ("g" "Review diff" my-codex-send-git-diff)
    ("G" "Review staged diff" my-codex-send-git-staged-diff)
    ("l" "Review current-file diff" my-codex-review-current-file-diff
     :inapt-if-not my-codex--current-or-left-file-available-p)
    ("v" "View diff" my-codex-show-git-diff)
    ("V" "View staged diff" my-codex-show-git-staged-diff)
    ("d" "Ediff current file" my-codex-ediff-current-file-against-head)
    ("D" "Ediff changed file" my-codex-ediff-changed-file-against-head)
    ("c" "Commit with agent message" my-codex-git-commit-with-latest-message)]
   ["Context"
    ("e" "Explain error" my-codex-explain-region-as-error)
    ("i" "Project instructions" my-codex-open-project-instructions)
    ("M" "Summarize session" my-codex-summarize-session-to-markdown)
    ("T" "Tools" my-codex-tools-transient)]
   ["GitHub"
    ("t" "List issues" my-codex-list-open-issues)
    ("I" "Draft issue" my-codex-summarize-session-to-github-issue)]])

;;;###autoload
(defun my-codex-transient-preserve-selection ()
  "Show Codex commands without disturbing the active region."
  (interactive)
  (setq my-codex--captured-selection
        (when (and (my-codex--selected-window-is-codex-p)
                   (use-region-p))
          (prog1
              (filter-buffer-substring
               (region-beginning)
               (region-end))
            (deactivate-mark))))
  (my-codex-transient))


;;;###autoload
(defun my-codex-project-build ()
  "Run the project build command with `compile'."
  (interactive)
  (let ((default-directory (my-codex-project-root)))
    (compile (or my-codex-project-build-command compile-command))))

(defvar-keymap my-codex-global-mode-map
  :doc "Keymap for `my-codex-global-mode'."
  "<f7>" #'my-codex-project-build
  "<f8>" #'my-codex-transient-preserve-selection)

(defun my-codex--enable-display-defaults ()
  "Enable default editing display helpers."
  (unless my-codex--display-defaults-enabled-by-mode
    (setq my-codex--saved-show-trailing-whitespace
          (default-value 'show-trailing-whitespace))
    (setq my-codex--saved-column-number-mode
          (bound-and-true-p column-number-mode))
    (setq my-codex--display-defaults-enabled-by-mode t))
  (setq-default show-trailing-whitespace
                my-codex--display-show-trailing-whitespace-value)
  (column-number-mode
   (if my-codex--display-column-number-mode-value 1 -1)))

(defun my-codex--restore-display-defaults ()
  "Restore display defaults changed by `my-codex-global-mode'."
  (when my-codex--display-defaults-enabled-by-mode
    (when (eq (default-value 'show-trailing-whitespace)
              my-codex--display-show-trailing-whitespace-value)
      (setq-default show-trailing-whitespace
                    my-codex--saved-show-trailing-whitespace))
    (when (eq (bound-and-true-p column-number-mode)
              my-codex--display-column-number-mode-value)
      (column-number-mode
       (if my-codex--saved-column-number-mode 1 -1)))
    (setq my-codex--saved-show-trailing-whitespace nil)
    (setq my-codex--saved-column-number-mode nil)
    (setq my-codex--display-defaults-enabled-by-mode nil)))

(easy-menu-define my-codex-menu my-codex-global-mode-map
  "Menu for agent commands."
  '("Agent"
    ("Session"
     ["Show/start read-only" my-codex-read-only
      :keys "F8 o"
      :help "Show the configured agent in read-only mode"]
     ["Show/start workspace-write" my-codex-workspace
      :keys "F8 w"
      :help "Show the configured agent with workspace write access"]
     ["Session commands" my-codex-session-transient
      :keys "F8 S"
      :help "Open default and future agent session commands"]
     ["Resume session" my-codex-resume
      :keys "F8 r"
      :help "Resume a previous agent session"]
     ["Show/start default read-only" my-codex-default-read-only
      :keys "F8 S o"
      :help "Show the default agent session in read-only mode"]
     ["Show/start default workspace-write" my-codex-default-workspace
      :keys "F8 S w"
      :help "Show the default agent session with workspace write access"]
     ["Session dashboard" my-codex-top
      :keys "F8 S l"
      :help "Display a dashboard of all agent sessions"]
     ["New named session" my-codex-new-session
      :keys "F8 S n"
      :help "Start or show a named agent session"]
     ["Hide selected session window" my-codex-hide-session-window
      :keys "F8 S q"
      :help "Hide the agent window associated with the selected session"]
     ["Hide agent window" my-codex-hide-window
      :keys "F8 q"
      :help "Hide the visible agent window"]
     ["Toggle focus" my-codex-toggle-focus
      :keys "F8 TAB"
      :help "Toggle focus between the agent and the previous window"])
    ("Send"
     ["Ask agent..." my-codex-ask
      :keys "F8 a"
      :help "Prompt for a question and send it to the active agent"]
     ["Preset menu" my-codex-ask-preset-transient
      :keys "F8 A"
      :help "Open the prompt preset menu"]
     ["Send selected region" my-codex-send-region
      :keys "F8 s"
      :active (use-region-p)
      :help "Send the selected region to the active agent"]
     ["Plan refactor for selected region" my-codex-plan-refactor-region
      :keys "F8 R"
      :active (and (use-region-p) buffer-file-name)
      :help "Ask the active agent for a low-risk refactoring plan"]
     ["Insert selection" my-codex-insert-selection-into-code
      :keys "F8 Left"
      :help "Insert the captured agent selection into the code buffer"]
     ["Review current defun" my-codex-review-defun-at-point
      :keys "F8 f"
      :help "Ask the active agent to review the defun at point"]
     ["Inspect current file" my-codex-send-current-file
      :keys "F8 F"
      :active buffer-file-name
      :help "Ask the active agent to inspect the current file directly"]
     ["Analyse test coverage" my-codex-analyse-test-coverage
      :keys "F8 C"
      :active buffer-file-name
      :help "Ask the active agent to analyse missing test scenarios"]
     ["Explain symbol at point" my-codex-explain-symbol-at-point
      :keys "F8 x"
      :active buffer-file-name
      :help "Ask the active agent to explain the symbol at point"])
    ("Git"
     ["Review Git diff" my-codex-send-git-diff
      :keys "F8 g"
      :help "Ask the active agent to review the current Git diff"]
     ["Review staged Git diff" my-codex-send-git-staged-diff
      :keys "F8 G"
      :help "Ask the active agent to review the staged Git diff"]
     ["Review current-file Git diff" my-codex-review-current-file-diff
      :keys "F8 l"
      :active (my-codex--current-or-left-file-available-p)
      :help "Ask the active agent to review only the current file's Git diff"]
     ["View Git diff" my-codex-show-git-diff
      :keys "F8 v"
      :help "Show the current Git diff in a diff-mode buffer"]
     ["View staged Git diff" my-codex-show-git-staged-diff
      :keys "F8 V"
      :help "Show the staged Git diff in a diff-mode buffer"]
     ["Ediff current file against HEAD" my-codex-ediff-current-file-against-head
      :keys "F8 d"
      :active (my-codex--current-or-left-file-available-p)
      :help "Review the current file's uncommitted changes against HEAD"]
     ["Ediff changed file against HEAD" my-codex-ediff-changed-file-against-head
      :keys "F8 D"
      :help "Choose a tracked changed file and review it against HEAD"]
     ["Edit commit with agent message" my-codex-git-commit-with-latest-message
      :keys "F8 c"
      :help "Use the latest agent commit message, or ask for one, then edit before committing"])
    ("Context"
     ["Explain selected error" my-codex-explain-region-as-error
      :keys "F8 e"
      :active (use-region-p)
      :help "Ask the active agent to explain the selected compiler/test error"]
     ["Open project instructions" my-codex-open-project-instructions
      :keys "F8 i"
      :help "Open AGENTS.md, CODEX.md, or .codex/instructions.md"]
     ["Summarize session to Markdown" my-codex-summarize-session-to-markdown
      :keys "F8 M"
      :help "Ask the active agent to summarize the conversation as Markdown notes"])
    ("Tools"
     ["Project overview" my-codex-send-project-overview
      :keys "F8 T p"
      :help "Send the active agent a compact project overview"]
     ["Export session" my-codex-export-session-to-markdown
      :keys "F8 T X"
      :help "Export the current agent session transcript to Markdown"]
     ["Diagnostics" my-codex-diagnostics-transient
      :keys "F8 T E"
      :help "Open diagnostic explanation commands"]
     ["Doctor" my-codex-doctor
      :keys "F8 T !"
      :help "Check Emacs, agent, vterm, Git, gh, project, configuration, and terminal startup"])
    ("GitHub"
     ["List issues" my-codex-list-open-issues
      :keys "F8 t"
      :help "List open GitHub issues for the current repository in a buffer"]
     ["Draft issue" my-codex-summarize-session-to-github-issue
      :keys "F8 I"
      :help "Ask the active agent to draft a GitHub issue, then edit it before creating it with gh"])
    "---"
    ["Compile project" my-codex-project-build
     :keys "F7"
     :help "Run the project build command"]))

;;;###autoload
(define-minor-mode my-codex-global-mode
  "Global minor mode for seamless Codex integration."
  :global t
  :group 'my-codex
  :keymap my-codex-global-mode-map
  (if my-codex-global-mode
      (progn
        (when my-codex-enable-display-defaults
          (my-codex--enable-display-defaults))
        (when (and my-codex-enable-vterm-integration
                   (not my-codex--vterm-integration-enabled-by-mode)
                   (not (bound-and-true-p my-codex-vterm-integration-mode)))
          (setq my-codex--vterm-integration-enabled-by-mode t)
          (my-codex-vterm-integration-mode 1))
        (when (and my-codex-enable-global-auto-revert
                   (not my-codex--auto-revert-enabled-by-mode)
                   (not (bound-and-true-p global-auto-revert-mode)))
          (setq my-codex--auto-revert-enabled-by-mode t)
          (global-auto-revert-mode 1)))
    (when (and my-codex--auto-revert-enabled-by-mode
               (bound-and-true-p global-auto-revert-mode))
      (global-auto-revert-mode -1))
    (when (and my-codex--vterm-integration-enabled-by-mode
               (bound-and-true-p my-codex-vterm-integration-mode))
      (my-codex-vterm-integration-mode -1))
    (my-codex--restore-display-defaults)
    (setq my-codex--vterm-integration-enabled-by-mode nil)
    (setq my-codex--auto-revert-enabled-by-mode nil)))

(require 'my-codex-prompts)
(require 'my-codex-git)
(require 'my-codex-github)
(require 'my-codex-links)
(require 'my-codex-doctor)
(require 'my-codex-vterm)

(provide 'my-codex)

;;; my-codex.el ends here
