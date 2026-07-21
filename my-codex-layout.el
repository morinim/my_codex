;;; my-codex-layout.el --- Window layout support for my-codex -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Manlio Morini

;; Author: Manlio Morini
;; Keywords: tools, convenience
;; URL: https://github.com/morinim/my_codex

;; This file is not part of GNU Emacs.

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at https://mozilla.org/MPL/2.0/.

;;; Commentary:

;; Window sizing, two-column layout, and edit-buffer display helpers.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'my-codex-core)

(defun my-codex-visible-window ()
  "Return the visible agent window in the selected frame, or raise an error."
  (my-codex-active-session-window))

(defun my-codex--associated-edit-window (codex-window)
  "Return the edit window associated with CODEX-WINDOW, or nil."
  (let ((codex-buffer (window-buffer codex-window)))
    (seq-find
     (lambda (window)
       (and (window-parameter window 'my-codex-edit-window)
            (eq (window-parameter window 'my-codex-term-buffer)
                codex-buffer)))
     (window-list (window-frame codex-window) 'no-minibuf))))

(defun my-codex-associated-edit-window ()
  "Return the most likely edit window associated with the agent."
  (let ((codex-window (my-codex-visible-window)))
    (let ((edit-window (or (my-codex--associated-edit-window codex-window)
                           (next-window codex-window nil))))
      (if (and edit-window (not (eq edit-window codex-window)))
          edit-window
        (user-error "No edit window found")))))

(defun my-codex-back-to-code ()
  "Move focus to the most likely coding window."
  (interactive)
  (select-window (my-codex-associated-edit-window)))

;;;###autoload
(defun my-codex-toggle-focus ()
  "Toggle focus between the agent vterm and the coding window."
  (interactive)
  (let ((codex-window (my-codex-visible-window)))
    (cond
     ((eq (selected-window) codex-window) (my-codex-back-to-code))
     (t (select-window codex-window)))))

(defun my-codex-selected-text ()
  "Return actively selected text from the visible agent window."
  (let ((codex-window (my-codex-visible-window)))
    (with-selected-window codex-window
      (cond
       ((use-region-p)
        (prog1
            (filter-buffer-substring
             (region-beginning)
             (region-end))
          (setq my-codex--captured-selection nil)
          (deactivate-mark)))
       (my-codex--captured-selection
        (prog1 my-codex--captured-selection
          (setq my-codex--captured-selection nil)))
       (t
        (user-error "No active selection in the agent buffer"))))))

;;;###autoload
(defun my-codex-insert-selection-into-code ()
  "Insert selected agent text into the coding window."
  (interactive)
  (let ((text (my-codex-selected-text))
        (edit-window (my-codex-associated-edit-window)))
    (select-window edit-window)
    (insert text)))

(defun my-codex--effective-right-width ()
  "Return the configured width of the Codex vterm window."
  (if my-codex-min-right-width
      (max my-codex-min-right-width my-codex-right-width)
    my-codex-right-width))

(defun my-codex--right-window-width (window)
  "Resize WINDOW to the target Codex width when enforcement is enabled."
  (when my-codex-enforce-right-side-layout
    (my-codex--resize-window-to-body-width
     window (my-codex--effective-right-width))))

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
  (+ my-codex-left-width (my-codex--effective-right-width)))

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

(defun my-codex--remove-edit-fill-column-indicator-hook-if-unused ()
  "Stop monitoring window changes when no buffers or windows are managed."
  (unless (or my-codex--edit-fill-column-indicator-buffers
              (seq-some
               (lambda (frame)
                 (seq-some
                  (lambda (window)
                    (window-parameter window 'my-codex-edit-window))
                  (window-list frame 'no-minibuf)))
               (frame-list)))
    (remove-hook 'window-buffer-change-functions
                 #'my-codex--refresh-edit-fill-column-indicator-windows)))

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
  (my-codex--restore-inactive-edit-fill-column-indicator-buffers)
  (my-codex--remove-edit-fill-column-indicator-hook-if-unused))

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
    (codex-command &optional focus-term session-name agent access-mode
                   startup-prompt)
  "Display Codex and run CODEX-COMMAND if the backend is not running.
If FOCUS-TERM is non-nil, leave the cursor focused on the terminal window.
When SESSION-NAME is non-nil, use that named session instead of default.
AGENT identifies the agent profile used for buffer names and metadata.
STARTUP-PROMPT is explicit prompt text sent when starting the session."
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
        (let ((recorded-backend
               (with-current-buffer existing-buf
                 my-codex-session-terminal-backend)))
          (with-current-buffer existing-buf
            (rename-buffer
             (generate-new-buffer-name
              (format "%s<old>" buffer-name))))
          (setq backend
                (my-codex--make-backend buffer-name recorded-backend)))
        (setq existing-buf nil))

      (let* ((edit-window (selected-window))
             (term-buffer (or existing-buf
                              (get-buffer-create buffer-name)))
             (term-window (display-codex-buffer term-buffer)))
        (my-codex--apply-display-window-width term-window)
        (my-codex--resize-edit-window-for-right-layout edit-window term-window)
        (my-codex--enable-edit-fill-column-indicator edit-window term-window)
        (select-window term-window)
        (if (and existing-buf
                 (my-codex-backend-live-p backend))
            (progn
              (set-window-buffer term-window existing-buf)
              (when (window-live-p edit-window)
                (set-window-parameter
                 edit-window 'my-codex-term-buffer existing-buf)))
          (let ((started-buffer
                 (my-codex-backend-start
                  backend project-root codex-command
                  session-name agent access-mode)))
            (when (bufferp started-buffer)
              (setq term-buffer started-buffer)
              (when startup-prompt
                (my-codex--record-outbound-prompt
                 term-buffer startup-prompt))
              (when (window-live-p term-window)
                (set-window-buffer term-window term-buffer))
              (when (window-live-p edit-window)
                (set-window-parameter
                 edit-window 'my-codex-term-buffer term-buffer)))))

        (when (my-codex--project-session-buffer-p term-buffer project-root)
          (my-codex--set-active-session term-buffer))

        (if focus-term
            (select-window term-window)
          (when (window-live-p edit-window)
            (select-window edit-window)))))))

(defun my-codex-layout-unload-function ()
  "Restore display state managed by `my-codex-layout'."
  (remove-hook 'window-buffer-change-functions
               #'my-codex--refresh-edit-fill-column-indicator-windows)
  (dolist (buffer (copy-sequence
                   my-codex--edit-fill-column-indicator-buffers))
    (my-codex--restore-edit-fill-column-indicator buffer))
  (dolist (frame (frame-list))
    (dolist (window (window-list frame 'no-minibuf))
      (when (window-parameter window 'my-codex-edit-window)
        (set-window-parameter window 'my-codex-edit-buffer nil)
        (set-window-parameter window 'my-codex-edit-window nil)
        (set-window-parameter window 'my-codex-term-buffer nil))))
  nil)

(provide 'my-codex-layout)

;;; my-codex-layout.el ends here
