;;; my-codex-vterm.el --- vterm integration for my-codex -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Manlio Morini

;; This file is not part of GNU Emacs.

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at https://mozilla.org/MPL/2.0/.

;;; Code:

(defvar my-codex--vterm-copy-mode-lighter)
(defvar my-codex--vterm-integration-keymap-bindings)
(defvar vterm-copy-mode)
(defvar vterm-copy-mode-map)
(defvar vterm-mode-map)

(declare-function my-codex-transient-preserve-selection "my-codex" ())
(declare-function vterm-yank "vterm" ())

(defun my-codex--ensure-main-package ()
  "Load `my-codex' when this file was entered through an autoload."
  (unless (featurep 'my-codex)
    (require 'my-codex)))

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
                 " vterm-copy-mode: scroll/copy mode -- press C-c C-t to return to Codex input "
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

(defun my-codex--shorten-vterm-copy-mode-lighter ()
  "Show `vterm-copy-mode' as a short highlighted mode-line lighter."
  (let ((entry (assq 'vterm-copy-mode minor-mode-alist)))
    (when entry
      (when (eq my-codex--vterm-copy-mode-lighter :unset)
        (setq my-codex--vterm-copy-mode-lighter (cdr entry)))
      (setcdr entry '((:propertize " Copy" face warning))))))

(defun my-codex--restore-vterm-copy-mode-lighter ()
  "Restore the previous `vterm-copy-mode' mode-line lighter."
  (let ((entry (assq 'vterm-copy-mode minor-mode-alist)))
    (when (and entry
               (not (eq my-codex--vterm-copy-mode-lighter :unset)))
      (setcdr entry my-codex--vterm-copy-mode-lighter)
      (setq my-codex--vterm-copy-mode-lighter :unset))))

(defun my-codex--save-and-set-vterm-key (map key command)
  "Save MAP's KEY binding and bind KEY to COMMAND."
  (push (list map key (keymap-lookup map key))
        my-codex--vterm-integration-keymap-bindings)
  (keymap-set map key command))

(defun my-codex--restore-vterm-keymap-bindings ()
  "Restore vterm key bindings changed by my-codex."
  (dolist (binding my-codex--vterm-integration-keymap-bindings)
    (pcase-let ((`(,map ,key ,previous) binding))
      (if previous
          (keymap-set map key previous)
        (keymap-unset map key))))
  (setq my-codex--vterm-integration-keymap-bindings nil))

(defun my-codex--enable-vterm-integration ()
  "Enable my-codex helpers for vterm."
  (my-codex--shorten-vterm-copy-mode-lighter)
  (unless my-codex--vterm-integration-keymap-bindings
    (when (boundp 'vterm-mode-map)
      (my-codex--save-and-set-vterm-key
       vterm-mode-map "S-<insert>" #'vterm-yank)
      (my-codex--save-and-set-vterm-key
       vterm-mode-map "<prior>" #'scroll-down-command)
      (my-codex--save-and-set-vterm-key
       vterm-mode-map "<next>" #'scroll-up-command)
      (my-codex--save-and-set-vterm-key
       vterm-mode-map "<f8>" #'my-codex-transient-preserve-selection))
    (when (boundp 'vterm-copy-mode-map)
      (my-codex--save-and-set-vterm-key
       vterm-copy-mode-map "<f8>" #'my-codex-transient-preserve-selection)))
  (add-hook 'vterm-mode-hook
            #'my-codex--disable-vterm-editing-minor-modes)
  (add-hook 'after-change-major-mode-hook
            #'my-codex--disable-vterm-editing-minor-modes
            100)
  (add-hook 'vterm-copy-mode-hook
            #'my-codex--vterm-copy-mode-header-line))

(defun my-codex--disable-vterm-integration ()
  "Disable my-codex helpers for vterm."
  (remove-hook 'vterm-mode-hook
               #'my-codex--disable-vterm-editing-minor-modes)
  (remove-hook 'after-change-major-mode-hook
               #'my-codex--disable-vterm-editing-minor-modes)
  (remove-hook 'vterm-copy-mode-hook
               #'my-codex--vterm-copy-mode-header-line)
  (my-codex--restore-vterm-copy-mode-lighter)
  (my-codex--restore-vterm-keymap-bindings))

;;;###autoload
(define-minor-mode my-codex-vterm-integration-mode
  "Global minor mode for my-codex vterm integration."
  :global t
  :group 'my-codex
  (my-codex--ensure-main-package)
  (if my-codex-vterm-integration-mode
      (with-eval-after-load 'vterm
        (when my-codex-vterm-integration-mode
          (my-codex--enable-vterm-integration)))
    (my-codex--disable-vterm-integration)))

(provide 'my-codex-vterm)

;;; my-codex-vterm.el ends here
