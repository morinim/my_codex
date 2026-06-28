;;; my-codex-vterm.el --- vterm integration for my-codex -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Manlio Morini

;; This file is not part of GNU Emacs.

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at https://mozilla.org/MPL/2.0/.

;;; Code:

(require 'my-codex-core)

(defvar vterm-copy-mode)

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
  :group 'my-codex
  (if my-codex-vterm-integration-mode
      (with-eval-after-load 'vterm
        (when my-codex-vterm-integration-mode
          (my-codex--enable-vterm-integration)))
    (my-codex--disable-vterm-integration)))

(provide 'my-codex-vterm)

;;; my-codex-vterm.el ends here
