;;; my-codex-ui.el --- UI buffers for my-codex -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Manlio Morini

;; Author: Manlio Morini
;; Keywords: tools, convenience
;; URL: https://github.com/morinim/my_codex

;; This file is not part of GNU Emacs.

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at https://mozilla.org/MPL/2.0/.

;;; Commentary:

;; Session dashboard buffer for my-codex.

;;; Code:

(require 'compile)
(require 'my-codex-core)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)

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
  (when (derived-mode-p 'my-codex-top-mode)
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

(defun my-codex--edit-window-for-session-buffer-any-frame (buffer)
  "Return an edit window associated with session BUFFER on any frame."
  (seq-some
   (lambda (frame)
     (seq-find
      (lambda (window)
        (eq (window-parameter window 'my-codex-term-buffer) buffer))
      (window-list frame 'no-minibuf)))
   (frame-list)))

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

(defun my-codex-top-visit ()
  "Visit the agent session at point."
  (interactive)
  (let* ((buffer-name (tabulated-list-get-id))
         (buffer (and buffer-name (get-buffer buffer-name))))
    (unless buffer
      (user-error "No agent session on this line"))
    (my-codex--switch-active-session-buffer buffer)))

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
  "RET" #'my-codex-top-visit
  "e"   #'my-codex-top-visit-edit-window
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
              '("  *Agents Top*  [D:Dired  b:Build  R:Rename  d:Diff  e:Edit  k:Kill  RET:Visit  g:Refresh]"))
  (tabulated-list-init-header)
  (my-codex--sync-header-hscroll))

(defun my-codex-top-refresh (&rest _)
  "Refresh the agent dashboard entries."
  (setq tabulated-list-entries (my-codex-top--make-entries))
  (tabulated-list-print t))

(defun my-codex-top--git-info (root)
  "Return Git information for ROOT as (BRANCH . STATE).

STATE is one of the strings `clean', `dirty', or `error'."
  (let* ((default-directory root)
         (branch-result
          (my-codex--process-output-result
           "git" "branch" "--show-current"))
         (status-result
          (my-codex--process-output-result
           "git" "status" "--porcelain"))
         (branch (if (eq (car branch-result) 0)
                     (or (cadr branch-result) "—")
                   "—"))
         (state (cond
                 ((not (eq (car status-result) 0)) "error")
                 ((cdr status-result) "dirty")
                 (t "clean"))))
    (cons branch state)))

(defun my-codex-top--make-entries ()
  "Build tabulated list entries for all agent sessions."
  (let ((git-cache (make-hash-table :test #'equal)))
    (mapcar
     (lambda (buffer)
       (let (project session access state pid branch git-state prompts lines age last-act)
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
               (pcase-let ((`(,cached-branch . ,cached-state)
                            (or (gethash root git-cache)
                                (puthash root
                                         (my-codex-top--git-info root)
                                         git-cache))))
                 (setq branch cached-branch
                       git-state cached-state))
               (setq branch "—"
                     git-state "—"))))
         (list (buffer-name buffer)
               (vector project session (buffer-name buffer) access state pid branch git-state prompts lines age last-act))))
     (my-codex--all-session-buffers))))

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

(defun my-codex-top-visit-edit-window ()
  "Select the edit window associated with the session at point."
  (interactive)
  (let* ((buffer-name (tabulated-list-get-id))
         (buffer (and buffer-name (get-buffer buffer-name)))
         (window (and buffer
                      (my-codex--edit-window-for-session-buffer-any-frame
                       buffer))))
    (unless buffer
      (user-error "No agent session on this line"))
    (unless (window-live-p window)
      (user-error "No edit window associated with %s" buffer-name))
    (select-window window)))

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
    (with-current-buffer buffer
      (when (equal my-codex-session-id
                   (my-codex--default-session-id
                    my-codex-session-project-root
                    my-codex-session-agent))
        (user-error "The default session cannot be renamed")))
    (let* ((current-name (with-current-buffer buffer my-codex-session-name))
           (new-name (read-string (format "Rename session %s to: " (or current-name "default"))
                                  current-name)))
      (with-current-buffer buffer
        (let* ((new-name (my-codex--normalise-session-name new-name))
               (old-buffer-name (buffer-name))
               (agent my-codex-session-agent)
               (root my-codex-session-project-root)
               (new-id (my-codex--session-id root new-name agent))
               (new-buf-name (my-codex-session-buffer-name new-name agent))
               (backend (gethash old-buffer-name my-codex--backends)))
          (setq-local my-codex-session-name new-name)
          (setq-local my-codex-session-id new-id)
          (my-codex--refresh-session-title)
          (setq new-buf-name (rename-buffer new-buf-name t))
          (when backend
            (remhash old-buffer-name my-codex--backends)
            (setf (my-codex-vterm-backend-buffer-name backend) new-buf-name)
            (puthash new-buf-name backend my-codex--backends))))
      (revert-buffer))))

;;;###autoload
(defun my-codex-top ()
  "Display a dashboard of all active and inactive agent sessions."
  (interactive)
  (with-current-buffer (get-buffer-create "*Agents Top*")
    (my-codex-top-mode)
    (my-codex-top-refresh)
    (pop-to-buffer (current-buffer))))

(provide 'my-codex-ui)

;;; my-codex-ui.el ends here
