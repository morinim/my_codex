;;; my-codex-vterm.el --- vterm integration for my-codex -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Manlio Morini

;; This file is not part of GNU Emacs.

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at https://mozilla.org/MPL/2.0/.

;;; Commentary:

;; vterm backend integration for agent sessions.

;;; Code:

(require 'my-codex-core)

(autoload 'my-codex-session-links-mode "my-codex-links" nil t)
(defvar vterm-copy-mode)
(defvar vterm-max-scrollback)
(defvar my-codex-vterm-integration-mode)
(defvar hack-local-variables-hook)
(declare-function vterm-mode "vterm" ())
(declare-function vterm-send-string "vterm" (string &optional paste-p))
(declare-function vterm-send-return "vterm" ())

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

(defun my-codex--vterm-command-and-exit (command)
  "Return shell text that runs COMMAND, then exits with its status for vterm."
  (my-codex--shell-command-and-exit-for-shell
   command
   (my-codex--vterm-shell-name)))

(defun my-codex--ensure-vterm-scrollback ()
  "Raise `vterm-max-scrollback' in the current agent buffer when needed."
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

(defun my-codex--floor-vterm-scrollback ()
  "Raise the effective vterm scrollback without changing its locality."
  (setq vterm-max-scrollback
        (my-codex--vterm-scrollback-floor vterm-max-scrollback)))

(defun my-codex--vterm-mode-with-scrollback-floor ()
  "Enable `vterm-mode' with the configured minimum scrollback."
  (unless (require 'vterm nil t)
    (user-error "vterm backend is selected but the vterm package is unavailable"))
  (let ((vterm-max-scrollback
        (my-codex--vterm-scrollback-floor vterm-max-scrollback))
        (hack-local-variables-hook
         (cons #'my-codex--floor-vterm-scrollback
               hack-local-variables-hook)))
    (vterm-mode)))

(cl-defmethod my-codex-backend-start
  ((backend my-codex-vterm-backend) project-root command
   &optional session-name agent access-mode)
  "Start BACKEND's vterm process in PROJECT-ROOT with COMMAND."
  (let* ((default-directory project-root)
         (buffer-name (my-codex-backend-buffer-name backend))
         (buffer (get-buffer-create buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'vterm-mode)
        (my-codex--vterm-mode-with-scrollback-floor))
      (my-codex--ensure-vterm-scrollback)
      (setq-local show-trailing-whitespace nil)
      (when my-codex-enable-session-links
        (my-codex-session-links-mode 1))
      (my-codex--prepare-backend-session
       buffer project-root command session-name agent access-mode 'vterm)
      (goto-char (point-max))
      (vterm-send-string (my-codex--vterm-command-and-exit command))
      (vterm-send-return))
    (when (bound-and-true-p my-codex-vterm-integration-mode)
      (with-current-buffer buffer
        (my-codex--enable-vterm-buffer-integration)))
    buffer))

(cl-defmethod my-codex-backend-live-p ((backend my-codex-vterm-backend))
  "Return non-nil when BACKEND's vterm process is live."
  (when-let (buffer (my-codex--backend-buffer backend))
    (process-live-p (get-buffer-process buffer))))

(cl-defmethod my-codex-backend-send
  ((backend my-codex-vterm-backend) prompt)
  "Send PROMPT through BACKEND's vterm buffer."
  (let ((buffer (or (my-codex--backend-buffer backend)
                    (user-error "No %s buffer found"
                                (my-codex-backend-buffer-name backend)))))
    (with-current-buffer buffer
      (goto-char (point-max))
      (vterm-send-string prompt t)
      (vterm-send-return)
      (my-codex--record-outbound-prompt buffer prompt))))

(autoload 'my-codex-transient-preserve-selection "my-codex" nil t)
(declare-function vterm-yank "vterm" ())

(defvar-keymap my-codex-vterm-override-mode-map
  :doc "Local key overrides for my-codex vterm buffers."
  "S-<insert>" #'vterm-yank
  "<prior>" #'scroll-down-command
  "<next>" #'scroll-up-command
  "<f8>" #'my-codex-transient-preserve-selection)

(defvar my-codex-vterm-override-mode-map-alist
  `((my-codex-vterm-override-mode . ,my-codex-vterm-override-mode-map))
  "Emulation map alist for `my-codex-vterm-override-mode'.")

(unless (memq 'my-codex-vterm-override-mode-map-alist
              emulation-mode-map-alists)
  (add-to-list 'emulation-mode-map-alists
               'my-codex-vterm-override-mode-map-alist))

(define-minor-mode my-codex-vterm-override-mode
  "Local key overrides for my-codex vterm buffers."
  :lighter nil)

(defvar-local my-codex--vterm-copy-mode-saved-header-line-format :unset
  "Previous `header-line-format' before showing the vterm copy mode hint.")

(defun my-codex--vterm-copy-mode-header-line ()
  "Show or hide a reminder while `vterm-copy-mode' is active."
  (if (bound-and-true-p vterm-copy-mode)
      (progn
        (when (eq my-codex--vterm-copy-mode-saved-header-line-format :unset)
          (setq my-codex--vterm-copy-mode-saved-header-line-format
                header-line-format))
        (setq header-line-format
              '(:eval
                (propertize
                 (format " vterm-copy-mode: scroll/copy mode -- press C-c C-t to return to %s input "
                         (if my-codex-session-agent
                             (my-codex--agent-label my-codex-session-agent)
                           "agent"))
                 'face 'warning))))
    (unless (eq my-codex--vterm-copy-mode-saved-header-line-format :unset)
      (setq header-line-format
            my-codex--vterm-copy-mode-saved-header-line-format)
      (setq my-codex--vterm-copy-mode-saved-header-line-format :unset)))
  (force-mode-line-update))

(defun my-codex--disable-vterm-editing-minor-modes ()
  "Disable editing minor modes that are not useful in `vterm-mode'."
  (when (eq major-mode 'vterm-mode)
    (dolist (mode '(company-mode flyspell-mode display-line-numbers-mode))
      (when (and (boundp mode)
                 (symbol-value mode)
                 (fboundp mode))
        (funcall mode -1)))))

(defun my-codex--enable-vterm-buffer-integration ()
  "Enable my-codex helpers in the current agent vterm buffer."
  (when (and my-codex-session-id
             (eq major-mode 'vterm-mode))
    (my-codex-vterm-override-mode 1)
    (my-codex--disable-vterm-editing-minor-modes)
    (add-hook 'vterm-copy-mode-hook
              #'my-codex--vterm-copy-mode-header-line nil t)))

(defun my-codex--disable-vterm-buffer-integration ()
  "Disable my-codex helpers in the current vterm buffer."
  (my-codex-vterm-override-mode -1)
  (remove-hook 'vterm-copy-mode-hook
               #'my-codex--vterm-copy-mode-header-line t)
  (unless (eq my-codex--vterm-copy-mode-saved-header-line-format :unset)
    (setq header-line-format
          my-codex--vterm-copy-mode-saved-header-line-format)
    (setq my-codex--vterm-copy-mode-saved-header-line-format :unset)))

(defun my-codex--enable-vterm-integration ()
  "Enable my-codex helpers for vterm."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (my-codex--enable-vterm-buffer-integration))))

(defun my-codex--disable-vterm-integration ()
  "Disable my-codex helpers for vterm."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (bound-and-true-p my-codex-vterm-override-mode)
        (my-codex--disable-vterm-buffer-integration))))
  (force-mode-line-update t))

;;;###autoload
(define-minor-mode my-codex-vterm-integration-mode
  "Global minor mode for my-codex vterm integration."
  :global t
  :group 'my-codex-integrations
  (if my-codex-vterm-integration-mode
      (with-eval-after-load 'vterm
        (when my-codex-vterm-integration-mode
          (my-codex--enable-vterm-integration)))
    (my-codex--disable-vterm-integration)))

(provide 'my-codex-vterm)

;;; my-codex-vterm.el ends here
