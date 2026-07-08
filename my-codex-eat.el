;;; my-codex-eat.el --- Eat backend for my-codex -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Manlio Morini

;; This file is not part of GNU Emacs.

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at https://mozilla.org/MPL/2.0/.

;;; Code:

(require 'my-codex-core)

(autoload 'my-codex-session-links-mode "my-codex-links" nil t)
(declare-function eat "eat" (&optional program new-session))
(defvar eat-buffer-name)
(defvar eat-terminal)
(defvar eat-term-scrollback-size)
(declare-function eat-term-send-string "eat" (terminal string))
(declare-function eat-term-send-string-as-yank "eat" (terminal args))

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
         (buffer-name (my-codex--backend-buffer-name backend))
         (buffer (my-codex--start-eat-buffer buffer-name project-root)))
    (with-current-buffer buffer
      (my-codex--ensure-eat-scrollback)
      (setq-local show-trailing-whitespace nil)
      (when my-codex-enable-session-links
        (my-codex-session-links-mode 1))
      (let ((proc (get-buffer-process buffer)))
        (unless (process-live-p proc)
          (user-error "Failed to start Eat process in %s" buffer-name))
        (set-process-query-on-exit-flag proc nil)
        (my-codex--track-process-output-time proc)
        (goto-char (point-max))
        (process-send-string proc (my-codex--eat-command-and-exit command))
        (process-send-string proc "\n")))
    (if session-name
        (my-codex--mark-named-session
         buffer session-name project-root access-mode agent 'eat)
      (my-codex--mark-default-session
       buffer project-root access-mode agent 'eat))
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
                                (my-codex--backend-buffer-name backend)))))
    (with-current-buffer buffer
      (unless (get-buffer-process buffer)
        (user-error "No running Eat process in %s" (buffer-name buffer)))
      (goto-char (point-max))
      (eat-term-send-string-as-yank eat-terminal prompt)
      (eat-term-send-string eat-terminal "\n")
      (setq my-codex-session-last-activity (current-time))
      (setq my-codex-session-prompt-count
            (1+ (or my-codex-session-prompt-count 0))))))

(autoload 'my-codex-transient-preserve-selection "my-codex" nil t)

(defvar-keymap my-codex-eat-override-mode-map
  :doc "Local key overrides for my-codex Eat buffers."
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
    (my-codex-eat-override-mode 1)))

(defun my-codex--disable-eat-buffer-integration ()
  "Disable my-codex helpers in the current Eat buffer."
  (my-codex-eat-override-mode -1))

(defun my-codex--enable-eat-integration ()
  "Enable my-codex helpers for Eat."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (my-codex--enable-eat-buffer-integration))))

(defun my-codex--disable-eat-integration ()
  "Disable my-codex helpers for Eat."
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
