;;; my-codex-eat.el --- Eat backend for my-codex -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Manlio Morini

;; This file is not part of GNU Emacs.

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at https://mozilla.org/MPL/2.0/.

;;; Commentary:

;; Eat terminal backend integration for Codex sessions.

;;; Code:

(require 'my-codex-core)

(autoload 'my-codex-session-links-mode "my-codex-links" nil t)
(autoload 'my-codex--linkify-session-region "my-codex-links" nil t)
(autoload 'my-codex-open-session-link-at-position "my-codex-links" nil t)
(defvar my-codex-session-link-map)
(defvar my-codex-eat-integration-mode)
(declare-function eat "eat" (&optional program new-session))
(declare-function eat--process-output-queue "eat" (buffer))
(defvar eat-buffer-name)
(defvar eat-terminal)
(defvar eat-term-scrollback-size)
(declare-function eat-term-input-event "eat" (terminal n event &optional ref-pos))
(declare-function eat-term-send-string "eat" (terminal string))
(declare-function eat-term-send-string-as-yank "eat" (terminal args))

(defvar-local my-codex--eat-link-overlays nil
  "Overlays making my-codex links visible in Eat buffers.")

(defun my-codex--eat-clear-link-overlays ()
  "Remove Eat link overlays in the current buffer."
  (mapc #'delete-overlay my-codex--eat-link-overlays)
  (setq my-codex--eat-link-overlays nil))

(defun my-codex--eat-apply-link-overlays ()
  "Apply visible Eat link overlays in the current buffer."
  (let ((pos (point-min))
        (end (point-max))
        next)
    (while (< pos end)
      (setq next (next-single-property-change
                  pos 'my-codex-session-link nil end))
      (when (get-text-property pos 'my-codex-session-link)
        (let ((overlay (make-overlay pos next nil nil t)))
          (overlay-put overlay 'my-codex-eat-link t)
          (overlay-put overlay 'face 'link)
          (overlay-put overlay 'mouse-face 'highlight)
          (overlay-put overlay 'help-echo "mouse-1 or RET: open link")
          (overlay-put overlay 'keymap my-codex-session-link-map)
          (overlay-put overlay 'priority 1000)
          (push overlay my-codex--eat-link-overlays)))
      (setq pos next))))

(defun my-codex--eat-shell-name ()
  "Return the shell executable Eat uses when no program is supplied."
  (or (and (boundp 'explicit-shell-file-name)
           (stringp explicit-shell-file-name)
           (not (string-empty-p explicit-shell-file-name))
           explicit-shell-file-name)
      (let ((eshell (getenv "ESHELL")))
        (and (stringp eshell)
             (not (string-empty-p eshell))
             eshell))
      shell-file-name
      ""))

(defun my-codex--eat-command-and-exit (command)
  "Return shell text that runs COMMAND, then exits with its status for Eat."
  (my-codex--shell-command-and-exit-for-shell
   command
   (my-codex--eat-shell-name)))

(defun my-codex--eat-scrollback-floor (scrollback)
  "Return SCROLLBACK raised to `my-codex-eat-min-scrollback' when needed."
  (cond
   ((null my-codex-eat-min-scrollback) nil)
   ((and (numberp scrollback)
         (< scrollback my-codex-eat-min-scrollback))
    my-codex-eat-min-scrollback)
   (t scrollback)))

(defun my-codex--ensure-eat-scrollback ()
  "Raise `eat-term-scrollback-size' in the current agent buffer when needed."
  (when (boundp 'eat-term-scrollback-size)
    (let ((scrollback
           (my-codex--eat-scrollback-floor eat-term-scrollback-size)))
      (unless (equal scrollback eat-term-scrollback-size)
        (setq-local eat-term-scrollback-size scrollback)))))

(defun my-codex--start-eat-buffer (buffer-name project-root)
  "Start an Eat terminal named BUFFER-NAME in PROJECT-ROOT and return it."
  (unless (require 'eat nil t)
    (user-error "Eat backend is selected but the Eat package is unavailable"))
  (let ((default-directory project-root)
        (eat-buffer-name buffer-name)
        (eat-term-scrollback-size
         (and (boundp 'eat-term-scrollback-size)
              (my-codex--eat-scrollback-floor eat-term-scrollback-size))))
    (let* ((placeholder (get-buffer buffer-name))
           (placeholder-windows
            (and placeholder
                 (get-buffer-window-list placeholder nil t)))
           (buffer (eat (my-codex--eat-shell-name))))
      (unless (equal (buffer-name buffer) buffer-name)
        (when (and placeholder
                   (not (eq placeholder buffer)))
          (when (process-live-p (get-buffer-process placeholder))
            (user-error "Refusing to replace live buffer %s" buffer-name))
          (kill-buffer placeholder))
        (with-current-buffer buffer
          (rename-buffer buffer-name))
        (dolist (window placeholder-windows)
          (when (window-live-p window)
            (set-window-buffer window buffer))))
      buffer)))

(cl-defmethod my-codex-backend-start
  ((backend my-codex-eat-backend) project-root command
   &optional session-name agent access-mode)
  "Start BACKEND's Eat process in PROJECT-ROOT with COMMAND."
  (let* ((agent (or agent my-codex-agent))
         (access-mode
          (or access-mode (my-codex--session-access-mode command agent)))
         (buffer-name (my-codex-backend-buffer-name backend))
         (buffer (my-codex--start-eat-buffer buffer-name project-root)))
    (with-current-buffer buffer
      (my-codex--ensure-eat-scrollback)
      (setq-local show-trailing-whitespace nil)
      (when my-codex-enable-session-links
        (my-codex-session-links-mode 1)
        (my-codex--enable-eat-session-links))
      (if session-name
          (my-codex--mark-named-session
           buffer session-name project-root access-mode agent 'eat)
        (my-codex--mark-default-session
         buffer project-root access-mode agent 'eat))
      (let ((proc (get-buffer-process buffer)))
        (unless (process-live-p proc)
          (user-error "Failed to start Eat process in %s" buffer-name))
        (set-process-query-on-exit-flag proc nil)
        (my-codex--track-process-output-time proc)
        (goto-char (point-max))
        (process-send-string proc (my-codex--eat-command-and-exit command))
        (process-send-string proc "\n")))
    (when (bound-and-true-p my-codex-eat-integration-mode)
      (with-current-buffer buffer
        (my-codex--enable-eat-buffer-integration)))
    buffer))

(cl-defmethod my-codex-backend-live-p ((backend my-codex-eat-backend))
  "Return non-nil when BACKEND's Eat process is live."
  (when-let (buffer (my-codex--backend-buffer backend))
    (process-live-p (get-buffer-process buffer))))

(cl-defmethod my-codex-backend-send
  ((backend my-codex-eat-backend) prompt)
  "Send PROMPT through BACKEND's Eat buffer."
  (let ((buffer (or (my-codex--backend-buffer backend)
                    (user-error "No %s buffer found"
                                (my-codex-backend-buffer-name backend)))))
    (with-current-buffer buffer
      (unless (get-buffer-process buffer)
        (user-error "No running Eat process in %s" (buffer-name buffer)))
      (goto-char (point-max))
      (eat-term-send-string-as-yank eat-terminal prompt)
      (if (fboundp 'eat-term-input-event)
          (eat-term-input-event eat-terminal 1 'return)
        (eat-term-send-string eat-terminal "\n"))
      (setq my-codex-session-last-activity (current-time))
      (setq my-codex-session-prompt-count
            (1+ (or my-codex-session-prompt-count 0))))))

(autoload 'my-codex-transient-preserve-selection "my-codex" nil t)

(defvar my-codex-eat-override-mode)

(defun my-codex--eat-linkify-after-update ()
  "Linkify rendered Eat output in the current my-codex session."
  (my-codex--eat-clear-link-overlays)
  (when (bound-and-true-p my-codex-session-links-mode)
    (my-codex--linkify-session-region (point-min) (point-max))
    (my-codex--eat-apply-link-overlays)))

(defun my-codex--eat-clear-overlays-when-links-disabled ()
  "Clear Eat link overlays when session links are disabled."
  (unless (bound-and-true-p my-codex-session-links-mode)
    (my-codex--eat-clear-link-overlays)))

(defun my-codex--enable-eat-output-linkification ()
  "Enable Eat output linkification advice when Eat is loaded."
  (when (fboundp 'eat--process-output-queue)
    (unless (advice-member-p #'my-codex--eat-process-output-queue-advice
                             'eat--process-output-queue)
      (advice-add 'eat--process-output-queue
                  :after #'my-codex--eat-process-output-queue-advice))))

(defun my-codex--enable-eat-output-linkification-when-active ()
  "Enable Eat output linkification when Eat integration is active."
  (when my-codex-eat-integration-mode
    (my-codex--enable-eat-output-linkification)))

(defun my-codex--enable-eat-session-links ()
  "Enable session link refreshes for Eat terminal updates."
  (my-codex--enable-eat-output-linkification)
  (add-hook 'my-codex-session-links-mode-hook
            #'my-codex--eat-clear-overlays-when-links-disabled
            nil t))

(defun my-codex--eat-process-output-queue-advice (buffer)
  "Linkify BUFFER after Eat has rendered pending output."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (my-codex--eat-linkify-after-update))))

(defun my-codex--eat-session-link-at-position-p (pos)
  "Return non-nil when POS is on a my-codex session link."
  (and (integer-or-marker-p pos)
       (get-text-property pos 'my-codex-session-link-type)))

(defun my-codex--eat-fallback-command (keys &optional position)
  "Return the current key's non-my-codex binding.
When POSITION is non-nil, look up KEYS at POSITION.  The lookup runs
with Eat overrides disabled."
  (let ((my-codex-eat-override-mode nil))
    (let ((command (key-binding keys t nil position)))
      (unless (eq command this-command)
        command))))

(defun my-codex--eat-count-event-command-p (command)
  "Return non-nil when COMMAND's mouse binding expects count then event."
  (or (eq command 'eat-self-input)
      (pcase (interactive-form command)
        (`(interactive ,spec)
         (and (stringp spec)
              (string-prefix-p "p\ne" spec))))))

(defun my-codex--eat-call-mouse-fallback (command event)
  "Call mouse fallback COMMAND for EVENT."
  (if (my-codex--eat-count-event-command-p command)
      (funcall command 1 event)
    (funcall command event)))

(defun my-codex-eat-open-link-or-fallback-at-point ()
  "Open a session link at point, or run Eat's normal binding."
  (interactive)
  (if (my-codex--eat-session-link-at-position-p (point))
      (my-codex-open-session-link-at-position (point))
    (when-let ((command (my-codex--eat-fallback-command (kbd "RET"))))
      (call-interactively command))))

(defun my-codex-eat-open-link-or-fallback-at-event (event)
  "Open a session link clicked by EVENT, or run Eat's normal binding."
  (interactive "e")
  (let* ((end (event-end event))
         (window (posn-window end))
         (pos (posn-point end)))
    (if (and (window-live-p window)
             (with-current-buffer (window-buffer window)
               (my-codex--eat-session-link-at-position-p pos)))
        (with-current-buffer (window-buffer window)
          (my-codex-open-session-link-at-position pos))
      (when (window-live-p window)
        (with-current-buffer (window-buffer window)
          (when-let ((command (my-codex--eat-fallback-command [mouse-1] end)))
            (my-codex--eat-call-mouse-fallback command event)))))))

(defvar-keymap my-codex-eat-override-mode-map
  :doc "Local key overrides for my-codex Eat buffers."
  "RET" #'my-codex-eat-open-link-or-fallback-at-point
  "<mouse-1>" #'my-codex-eat-open-link-or-fallback-at-event
  "<prior>" #'scroll-down-command
  "<next>" #'scroll-up-command
  "<f8>" #'my-codex-transient-preserve-selection)

(defvar my-codex-eat-override-mode-map-alist
  `((my-codex-eat-override-mode . ,my-codex-eat-override-mode-map))
  "Emulation map alist for `my-codex-eat-override-mode'.")

(unless (memq 'my-codex-eat-override-mode-map-alist
              emulation-mode-map-alists)
  (add-to-list 'emulation-mode-map-alists
               'my-codex-eat-override-mode-map-alist))

(define-minor-mode my-codex-eat-override-mode
  "Local key overrides for my-codex Eat buffers."
  :lighter nil)

(defun my-codex--enable-eat-buffer-integration ()
  "Enable my-codex helpers in the current agent Eat buffer."
  (when (and my-codex-session-id
             (eq major-mode 'eat-mode))
    (when (bound-and-true-p my-codex-session-links-mode)
      (my-codex--enable-eat-session-links))
    (my-codex-eat-override-mode 1)))

(defun my-codex--disable-eat-buffer-integration ()
  "Disable my-codex helpers in the current Eat buffer."
  (remove-hook 'my-codex-session-links-mode-hook
               #'my-codex--eat-clear-overlays-when-links-disabled
               t)
  (my-codex--eat-clear-link-overlays)
  (my-codex-eat-override-mode -1))

(defun my-codex--enable-eat-integration ()
  "Enable my-codex helpers for Eat."
  (with-eval-after-load 'eat
    (my-codex--enable-eat-output-linkification-when-active))
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (my-codex--enable-eat-buffer-integration))))

(defun my-codex--disable-eat-integration ()
  "Disable my-codex helpers for Eat."
  (when (fboundp 'eat--process-output-queue)
    (advice-remove 'eat--process-output-queue
                   #'my-codex--eat-process-output-queue-advice))
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (bound-and-true-p my-codex-eat-override-mode)
        (my-codex--disable-eat-buffer-integration)))))

;;;###autoload
(define-minor-mode my-codex-eat-integration-mode
  "Global minor mode for my-codex Eat integration."
  :global t
  :group 'my-codex
  (if my-codex-eat-integration-mode
      (my-codex--enable-eat-integration)
    (my-codex--disable-eat-integration)))

(provide 'my-codex-eat)

;;; my-codex-eat.el ends here
