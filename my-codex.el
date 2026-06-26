;;; my-codex.el --- Codex integration -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Manlio Morini

;; Author: Manlio Morini
;; Keywords: tools, convenience
;; URL: https://github.com/morinim/my_codex
;; Version: 0.94.0
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
(require 'ansi-color)
(require 'my-codex-core)
(require 'browse-url)
(require 'cl-lib)
(require 'ediff)
(require 'easymenu)
(require 'project)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'thingatpt)
(require 'transient)
(require 'xref)

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
        (vterm-send-return)
        (when (and my-codex-language (not (string-empty-p my-codex-language)))
          (vterm-send-string
           (format "Please answer and generate all output (including commit messages, summaries, reviews, refactorings, etc.) in %s."
                   my-codex-language)
           t)
          (vterm-send-return))))
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

(defconst my-codex-sessions-buffer-name "*Agent sessions*"
  "Buffer name used to display open agent sessions.")

(defvar-local my-codex--header-string nil
  "Cached space-padded header string for horizontal scrolling.")

(defun my-codex--build-header-string ()
  "Build a space-padded propertized string of column headers."
  (let* ((x (max tabulated-list-padding 0))
         (button-props `(help-echo "Click to sort by column"
                         mouse-face header-line-highlight
                         keymap ,tabulated-list-sort-button-map))
         (len (length tabulated-list-format))
         (cols nil))
    (push (make-string x ?\s) cols)
    (dotimes (n len)
      (let* ((col (aref tabulated-list-format n))
             (not-last-col (< n (1- len)))
             (label (nth 0 col))
             (lablen (length label))
             (pname label)
             (width (nth 1 col))
             (props (nthcdr 3 col))
             (pad-right (or (plist-get props :pad-right) 1))
             (right-align (plist-get props :right-align))
             (available-space width))
        (when (and (>= lablen 3)
                   not-last-col
                   (> lablen available-space))
          (setq label (truncate-string-to-width label available-space nil nil t)))
        (let ((col-str
               (cond
                ((not (nth 2 col))
                 (propertize label 'tabulated-list-column-name pname))
                ((equal (car col) (car tabulated-list-sort-key))
                 (apply 'propertize
                        (concat label
                                (cond
                                 ((and (< lablen 3) not-last-col) "")
                                 ((cdr tabulated-list-sort-key)
                                  (format " %c" tabulated-list-gui-sort-indicator-desc))
                                 (t (format " %c" tabulated-list-gui-sort-indicator-asc))))
                        'face 'bold
                        'tabulated-list-column-name pname
                        button-props))
                (t (apply 'propertize label
                          'tabulated-list-column-name pname
                          button-props)))))
          (let* ((col-width (string-width col-str))
                 (padding-len (- width col-width)))
            (if right-align
                (progn
                  (when (> padding-len 0)
                    (push (make-string padding-len ?\s) cols))
                  (push col-str cols))
              (push col-str cols)
              (when (and not-last-col (> padding-len 0))
                (push (make-string padding-len ?\s) cols))))
          (when (and not-last-col (>= pad-right 0))
            (push (propertize (make-string pad-right ?\s) 'face 'fixed-pitch) cols)))))
    (apply #'concat (nreverse cols))))

(defun my-codex--sync-header-hscroll ()
  "Configure the buffer-local `header-line-format` to align with `window-hscroll`."
  (when (memq major-mode '(my-codex-sessions-mode my-codex-top-mode))
    (setq-local my-codex--header-string (my-codex--build-header-string))
    (setq-local header-line-format
                '("" header-line-indent
                  (:eval
                   (let ((hscroll (window-hscroll)))
                     (if (< hscroll (length my-codex--header-string))
                         (substring my-codex--header-string hscroll)
                       "")))))
    (add-hook 'post-command-hook #'force-mode-line-update nil t)))

(advice-add 'tabulated-list-init-header :after #'my-codex--sync-header-hscroll)

(defvar-keymap my-codex-sessions-mode-map
  :parent tabulated-list-mode-map
  "RET" #'my-codex-sessions-visit
  "<mouse-1>" #'my-codex-sessions-mouse-visit)

(define-derived-mode my-codex-sessions-mode tabulated-list-mode
  "Agent sessions"
  "Major mode for selecting open agent sessions."
  (setq tabulated-list-format
        [("Buffer" 32 t)
         ("Agent" 12 t)
         ("Name" 18 t)
         ("Access" 16 t)
         ("Project" 0 t)])
  (setq tabulated-list-padding 2)
  (tabulated-list-init-header)
  (my-codex--sync-header-hscroll))

(defun my-codex--visible-session-window (&optional source-window)
  "Return the visible agent session window for SOURCE-WINDOW."
  (let* ((source-window (or source-window (selected-window)))
         (term-buffer (window-parameter source-window
                                        'my-codex-term-buffer)))
    (or (and (buffer-live-p term-buffer)
             (get-buffer-window term-buffer nil))
        (seq-find
         (lambda (window)
           (with-current-buffer (window-buffer window)
             (bound-and-true-p my-codex-session-id)))
         (window-list nil 'no-minibuf)))))

(defun my-codex--edit-windows-for-session-buffer (buffer)
  "Return edit windows associated with agent session BUFFER."
  (seq-filter
   (lambda (window)
     (eq (window-parameter window 'my-codex-term-buffer) buffer))
   (window-list nil 'no-minibuf)))

(defun my-codex--switch-active-session-buffer (buffer)
  "Switch the active agent session window to BUFFER."
  (let* ((source-window (selected-window))
         (term-window (my-codex--visible-session-window source-window))
         (previous-buffer (and (window-live-p term-window)
                               (window-buffer term-window))))
    (if (window-live-p term-window)
        (progn
          (set-window-buffer term-window buffer)
          (dolist (window
                   (my-codex--edit-windows-for-session-buffer
                    previous-buffer))
            (set-window-parameter window 'my-codex-term-buffer buffer))
          (select-window term-window))
      (select-window
       (or (display-buffer buffer my-codex-display-buffer-action)
           (user-error "Failed to display %s" (buffer-name buffer)))))))

(defun my-codex-sessions-visit ()
  "Visit the agent session at point."
  (interactive)
  (let* ((buffer-name (tabulated-list-get-id))
         (buffer (and buffer-name (get-buffer buffer-name))))
    (unless buffer
      (user-error "No agent session on this line"))
    (my-codex--switch-active-session-buffer buffer)))

(defun my-codex-sessions-mouse-visit (event)
  "Visit the agent session clicked in EVENT."
  (interactive "e")
  (let* ((end (event-end event))
         (window (posn-window end))
         (point (posn-point end)))
    (when (and (windowp window) (integer-or-marker-p point))
      (select-window window)
      (goto-char point)
      (my-codex-sessions-visit))))

(defun my-codex--session-buffers ()
  "Return open agent session buffers."
  (seq-sort-by
   #'buffer-name #'string<
   (seq-filter
    (lambda (buffer)
      (with-current-buffer buffer
        (and (bound-and-true-p my-codex-session-id)
             (when-let ((process (get-buffer-process buffer)))
               (process-live-p process)))))
    (buffer-list))))

;;;###autoload
(defun my-codex-list-sessions ()
  "List open agent session buffers."
  (interactive)
  (let ((buffers (my-codex--session-buffers)))
    (if (null buffers)
        (message "No open agent sessions.")
      (with-current-buffer (get-buffer-create my-codex-sessions-buffer-name)
        (my-codex-sessions-mode)
        (setq tabulated-list-entries
              (mapcar
               (lambda (buffer)
                 (let (agent name access root)
                   (with-current-buffer buffer
                     (setq agent my-codex-session-agent
                           name my-codex-session-name
                           access my-codex-session-access-mode
                           root my-codex-session-project-root))
                   (list (buffer-name buffer)
                         (vector
                          (buffer-name buffer)
                          (if agent (symbol-name agent) "")
                          (or name "")
                          (my-codex--access-mode-label access)
                          (or root "")))))
               buffers))
        (tabulated-list-print t)
        (pop-to-buffer (current-buffer))))))

(defun my-codex--all-session-buffers ()
  "Return all agent session buffers, including dead ones."
  (seq-sort-by
   #'buffer-name #'string<
   (seq-filter
    (lambda (buffer)
      (with-current-buffer buffer
        (bound-and-true-p my-codex-session-id)))
    (buffer-list))))

(defun my-codex--format-duration (start end)
  "Format duration between START and END as a human-readable string."
  (if (and start end)
      (let* ((diff (floor (float-time (time-subtract end start))))
             (mins (/ diff 60))
             (hours (/ mins 60)))
        (cond
         ((>= hours 24) (format "%dd" (/ hours 24)))
         ((>= hours 1) (format "%dh" hours))
         ((>= mins 1) (format "%dm" mins))
         (t (format "%ds" diff))))
    "—"))

(defface my-codex-top-live-face
  '((t :inherit success :weight bold))
  "Face used for live sessions in the Codex dashboard."
  :group 'my-codex)

(defface my-codex-top-dead-face
  '((t :inherit shadow))
  "Face used for dead/inactive sessions in the Codex dashboard."
  :group 'my-codex)

(defvar-keymap my-codex-top-mode-map
  :parent tabulated-list-mode-map
  "RET" #'my-codex-sessions-visit
  "k"   #'my-codex-top-kill-session
  "d"   #'my-codex-top-project-diff
  "D"   #'my-codex-top-dired-project
  "b"   #'my-codex-top-build-project
  "R"   #'my-codex-top-rename-session
  "g"   #'revert-buffer)

(define-derived-mode my-codex-top-mode tabulated-list-mode
  "Agents Top"
  "Major mode for monitoring agent sessions."
  (setq tabulated-list-format
        [("Project" 12 t)
         ("Session" 10 t)
         ("Buffer" 28 t)
         ("Access" 16 t)
         ("State" 6 t)
         ("PID" 8 t)
         ("Branch" 12 t)
         ("Git" 8 t)
         ("Prompts" 8 t)
         ("Lines" 8 t)
         ("Age" 6 t)
         ("Activity" 8 t)])
  (setq tabulated-list-padding 1)
  (setq revert-buffer-function #'my-codex-top-refresh)
  (setq-local mode-line-format
              '("  *Agents Top*  [D:Dired  b:Build  R:Rename  d:Diff  k:Kill  RET:Visit  g:Refresh]"))
  (tabulated-list-init-header)
  (my-codex--sync-header-hscroll))

(defun my-codex-top-refresh (&rest _)
  "Refresh the agent dashboard entries."
  (setq tabulated-list-entries (my-codex-top--make-entries))
  (tabulated-list-print t))

(defun my-codex-top--make-entries ()
  "Build tabulated list entries for all agent sessions."
  (mapcar
   (lambda (buffer)
     (let (project session access state pid branch git prompts lines age last-act)
       (with-current-buffer buffer
         (let ((root my-codex-session-project-root)
               (now (current-time)))
           (setq project (if root (file-name-nondirectory (directory-file-name root)) "")
                 session (or my-codex-session-name "")
                 access (my-codex--access-mode-label my-codex-session-access-mode)
                 state (if-let ((proc (get-buffer-process buffer)))
                           (if (process-live-p proc)
                               (propertize "live" 'face 'my-codex-top-live-face)
                             (propertize "dead" 'face 'my-codex-top-dead-face))
                         (propertize "dead" 'face 'my-codex-top-dead-face))
                 pid (if-let ((proc (get-buffer-process buffer)))
                         (format "%d" (process-id proc))
                       "—")
                 lines (format "%d" (count-lines (point-min) (point-max)))
                 prompts (format "%d" (or my-codex-session-prompt-count 0))
                 age (my-codex--format-duration my-codex-session-start-time now)
                 last-act (my-codex--format-duration my-codex-session-last-activity now))
           (if (and root (file-directory-p root))
               (let ((default-directory root))
                 (setq branch (or (car (my-codex--process-output-lines "git" "branch" "--show-current"))
                                  "—")
                       git (if (my-codex--process-output-lines "git" "status" "--porcelain")
                               "dirty"
                             "clean")))
             (setq branch "—"
                   git "—"))))
       (list (buffer-name buffer)
             (vector project session (buffer-name buffer) access state pid branch git prompts lines age last-act))))
   (my-codex--all-session-buffers)))

(defun my-codex-top-kill-session ()
  "Kill the agent session process and buffer at point."
  (interactive)
  (let* ((buffer-name (tabulated-list-get-id))
         (buffer (and buffer-name (get-buffer buffer-name))))
    (unless buffer
      (user-error "No agent session on this line"))
    (when (yes-or-no-p (format "Kill session %s? " buffer-name))
      (with-current-buffer buffer
        (when-let ((proc (get-buffer-process buffer)))
          (when (process-live-p proc)
            (kill-process proc))))
      (kill-buffer buffer)
      (revert-buffer))))

(defun my-codex-top-project-diff ()
  "Show git diff for the selected session's project."
  (interactive)
  (let* ((buffer-name (tabulated-list-get-id))
         (buffer (and buffer-name (get-buffer buffer-name))))
    (unless buffer
      (user-error "No agent session on this line"))
    (let ((root (with-current-buffer buffer my-codex-session-project-root)))
      (if (and root (file-directory-p root))
          (let ((default-directory root))
            (if (fboundp 'magit-status)
                (magit-status root)
              (vc-diff)))
        (user-error "Invalid project root directory for session")))))

(defun my-codex-top-dired-project ()
  "Open dired at the selected session's project root directory."
  (interactive)
  (let* ((buffer-name (tabulated-list-get-id))
         (buffer (and buffer-name (get-buffer buffer-name))))
    (unless buffer
      (user-error "No agent session on this line"))
    (let ((root (with-current-buffer buffer my-codex-session-project-root)))
      (if (and root (file-directory-p root))
          (dired root)
        (user-error "Invalid project root directory for session")))))

(defun my-codex-top-build-project ()
  "Run the project build command with `compile` for the selected session."
  (interactive)
  (let* ((buffer-name (tabulated-list-get-id))
         (buffer (and buffer-name (get-buffer buffer-name))))
    (unless buffer
      (user-error "No agent session on this line"))
    (let ((root (with-current-buffer buffer my-codex-session-project-root)))
      (if (and root (file-directory-p root))
          (let ((default-directory root))
            (compile (or (with-current-buffer buffer my-codex-project-build-command)
                         my-codex-project-build-command
                         compile-command)))
        (user-error "Invalid project root directory for session")))))

(defun my-codex-top-rename-session ()
  "Rename the session name (my-codex-session-name) for the session at point."
  (interactive)
  (let* ((buffer-name (tabulated-list-get-id))
         (buffer (and buffer-name (get-buffer buffer-name))))
    (unless buffer
      (user-error "No agent session on this line"))
    (let* ((current-name (with-current-buffer buffer my-codex-session-name))
           (new-name (read-string (format "Rename session %s to: " (or current-name "default"))
                                  current-name)))
      (when (string-empty-p (string-trim new-name))
        (user-error "Session name cannot be empty"))
      (with-current-buffer buffer
        (let* ((agent my-codex-session-agent)
               (root my-codex-session-project-root)
               (new-id (my-codex--session-id root new-name agent))
               (new-buf-name (my-codex-session-buffer-name new-name agent)))
          (setq-local my-codex-session-name new-name)
          (setq-local my-codex-session-id new-id)
          (my-codex--refresh-session-title)
          (rename-buffer new-buf-name t)))
      (revert-buffer))))

;;;###autoload
(defun my-codex-top ()
  "Display a dashboard of all active and inactive agent sessions."
  (interactive)
  (with-current-buffer (get-buffer-create "*Agents Top*")
    (my-codex-top-mode)
    (my-codex-top-refresh)
    (pop-to-buffer (current-buffer))))

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
  (let* ((label (my-codex--active-agent-label))
         (buffer-name (my-codex-current-buffer-name))
         (windows (get-buffer-window-list buffer-name nil t)))
    (unless windows
      (user-error "%s window is not visible" label))
    (dolist (window windows)
      (when (window-live-p window)
        (quit-window nil window)))
    (message "%s window hidden" label)))

(defun my-codex--session-layout-buffer ()
  "Return the agent buffer associated with the selected session layout."
  (or (window-parameter (selected-window) 'my-codex-term-buffer)
      (when (bound-and-true-p my-codex-session-id)
        (current-buffer))
      (get-buffer (my-codex-current-buffer-name))
      (user-error "Agent window is not visible")))

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
  "Start or show a named agent session NAME using AGENT and ACCESS-MODE.
For compatibility, AGENT may also be a command string when ACCESS-MODE is nil."
  (interactive
   (list
    (read-string "Session name: ")
    (my-codex--read-agent)
    (my-codex--read-session-access-mode)))
  (let ((session-name (my-codex--normalise-session-name name)))
    (if (and (stringp agent) (null access-mode))
        (my-codex-two-column-layout-with-command
         agent nil session-name my-codex-agent)
      (my-codex-two-column-layout-with-command
       (my-codex--agent-command agent access-mode)
       nil session-name agent access-mode))))

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
  (let* ((root (my-codex-project-root))
         (buffer (my-codex--session-buffer))
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
  (let* ((root (my-codex-project-root))
         (buffer (my-codex-buffer)))
    (my-codex--request-marked-output
     :name "SESSION_SUMMARY"
     :buffer buffer
     :prompt my-codex-session-summary-prompt
     :placeholder "<Markdown notes here>"
     :callback (lambda (summary)
                 (my-codex-edit-session-summary summary root))
     :timeout-message "Timed out waiting for agent session summary."
     :ready-message "Agent session summary is ready for editing."
     :poll-interval my-codex-session-summary-poll-interval
     :poll-attempts my-codex-session-summary-poll-attempts
     :timer-var 'my-codex--session-summary-wait-timer)
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
  "f"       #'my-codex-send-current-file
  "C"       #'my-codex-analyse-test-coverage
  "x"       #'my-codex-explain-symbol-at-point
  "g"       #'my-codex-send-git-diff
  "G"       #'my-codex-send-git-staged-diff
  "v"       #'my-codex-show-git-diff
  "V"       #'my-codex-show-git-staged-diff
  "d"       #'my-codex-ediff-current-file-against-head
  "D"       #'my-codex-ediff-changed-file-against-head
  "c"       #'my-codex-git-commit-with-latest-message
  "e"       #'my-codex-explain-region-as-error
  "E"       #'my-codex-diagnostics-transient
  "i"       #'my-codex-open-project-instructions
  "p"       #'my-codex-send-project-overview
  "X"       #'my-codex-export-session-to-markdown
  "M"       #'my-codex-summarize-session-to-markdown
  "t"       #'my-codex-list-open-issues
  "T"       #'my-codex-summarize-session-to-github-issue
  "!"       #'my-codex-doctor
  "TAB"     #'my-codex-toggle-focus
  "<tab>"   #'my-codex-toggle-focus)

;;;###autoload
(transient-define-prefix my-codex-session-transient ()
  "Show agent session commands."
  [["Default session"
    ("o" "Read-only" my-codex-default-read-only)
    ("w" "Workspace" my-codex-default-workspace)]
   ["Session"
    ("l" "List" my-codex-list-sessions)
    ("t" "Session dashboard" my-codex-top)
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
    ("f" "Current file" my-codex-send-current-file)
    ("C" "Coverage gaps" my-codex-analyse-test-coverage)
    ("x" "Explain symbol" my-codex-explain-symbol-at-point)
    ("p" "Project overview" my-codex-send-project-overview)]
   ["Git"
    ("g" "Review diff" my-codex-send-git-diff)
    ("G" "Review staged diff" my-codex-send-git-staged-diff)
    ("v" "View diff" my-codex-show-git-diff)
    ("V" "View staged diff" my-codex-show-git-staged-diff)
    ("d" "Ediff current file" my-codex-ediff-current-file-against-head)
    ("D" "Ediff changed file" my-codex-ediff-changed-file-against-head)
    ("c" "Commit with agent message" my-codex-git-commit-with-latest-message)]
   ["Context"
    ("e" "Explain error" my-codex-explain-region-as-error)
    ("E" "Diagnostics" my-codex-diagnostics-transient)
    ("i" "Project instructions" my-codex-open-project-instructions)
    ("X" "Export session" my-codex-export-session-to-markdown)
    ("M" "Summarize session" my-codex-summarize-session-to-markdown)
    ("!" "Doctor" my-codex-doctor)]
   ["GitHub"
    ("t" "List issues" my-codex-list-open-issues)
    ("T" "Draft issue" my-codex-summarize-session-to-github-issue)]])

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
     ["List open sessions" my-codex-list-sessions
      :keys "F8 S l"
      :help "List open agent session buffers"]
     ["Session dashboard" my-codex-top
      :keys "F8 S t"
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
     ["Inspect current file" my-codex-send-current-file
      :keys "F8 f"
      :active buffer-file-name
      :help "Ask the active agent to inspect the current file directly"]
     ["Analyse test coverage" my-codex-analyse-test-coverage
      :keys "F8 C"
      :active buffer-file-name
      :help "Ask the active agent to analyse missing test scenarios"]
     ["Explain symbol at point" my-codex-explain-symbol-at-point
      :keys "F8 x"
      :active buffer-file-name
      :help "Ask the active agent to explain the symbol at point"]
     ["Send project overview" my-codex-send-project-overview
      :keys "F8 p"
      :help "Send the active agent a compact project overview"])
    ("Git"
     ["Review Git diff" my-codex-send-git-diff
      :keys "F8 g"
      :help "Ask the active agent to review the current Git diff"]
     ["Review staged Git diff" my-codex-send-git-staged-diff
      :keys "F8 G"
      :help "Ask the active agent to review the staged Git diff"]
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
     ["Explain diagnostics" my-codex-diagnostics-transient
      :keys "F8 E"
      :help "Open diagnostic explanation commands"]
     ["Open project instructions" my-codex-open-project-instructions
      :keys "F8 i"
      :help "Open AGENTS.md, CODEX.md, or .codex/instructions.md"]
     ["Export session to Markdown" my-codex-export-session-to-markdown
      :keys "F8 X"
      :help "Export the current agent session transcript to Markdown"]
     ["Summarize session to Markdown" my-codex-summarize-session-to-markdown
      :keys "F8 M"
      :help "Ask the active agent to summarize the conversation as Markdown notes"]
     ["Run health check" my-codex-doctor
      :keys "F8 !"
      :help "Check Emacs, agent, vterm, Git, gh, project, configuration, and terminal startup"])
    ("GitHub"
     ["List issues" my-codex-list-open-issues
      :keys "F8 t"
      :help "List open GitHub issues for the current repository in a buffer"]
     ["Draft issue" my-codex-summarize-session-to-github-issue
      :keys "F8 T"
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
