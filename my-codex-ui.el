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

(defcustom my-codex-top-git-cache-ttl 5
  "Seconds for which dashboard Git information remains valid."
  :type 'number
  :group 'my-codex)

(defvar my-codex-top--git-cache (make-hash-table :test #'equal)
  "Git dashboard information keyed by project root.")

(defvar-keymap my-codex-top-sort-button-map
  :parent tabulated-list-sort-button-map
  "<header-line> <mouse-1>" #'my-codex-top-col-sort
  "<header-line> <mouse-2>" #'my-codex-top-col-sort
  "<mouse-1>" #'my-codex-top-col-sort
  "<mouse-2>" #'my-codex-top-col-sort)

(defun my-codex--build-header-string ()
  "Build a space-padded propertized string of column headers."
  (let* ((x (max tabulated-list-padding 0))
         (button-props `(help-echo "Click to sort by column"
                         mouse-face header-line-highlight
                         keymap ,my-codex-top-sort-button-map))
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
  (setq-local my-codex--header-string (my-codex--build-header-string))
  (setq-local header-line-format
              '("" header-line-indent
                (:eval
                 (let ((hscroll (window-hscroll)))
                   (if (< hscroll (length my-codex--header-string))
                       (substring my-codex--header-string hscroll)
                     ""))))))

(defun my-codex-top-sort (&optional column)
  "Sort dashboard entries by COLUMN and refresh its scrolling header."
  (interactive "P")
  (tabulated-list-sort column)
  (my-codex--sync-header-hscroll))

(defun my-codex-top-col-sort (event)
  "Sort by the dashboard column clicked in EVENT and refresh its header."
  (interactive "e")
  (let ((buffer (window-buffer (posn-window (event-start event)))))
    (tabulated-list-col-sort event)
    (with-current-buffer buffer
      (my-codex--sync-header-hscroll))))

(defun my-codex-top-widen-current-column (&optional width)
  "Widen the current dashboard column by WIDTH and refresh its header."
  (interactive "p")
  (tabulated-list-widen-current-column (or width 1))
  (my-codex--sync-header-hscroll))

(defun my-codex-top-narrow-current-column (&optional width)
  "Narrow the current dashboard column by WIDTH and refresh its header."
  (interactive "p")
  (tabulated-list-narrow-current-column (or width 1))
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
           (user-error "Failed to display %s" (buffer-name buffer)))))
    (my-codex--set-active-session buffer)))

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
  "<remap> <tabulated-list-sort>" #'my-codex-top-sort
  "<remap> <tabulated-list-widen-current-column>"
  #'my-codex-top-widen-current-column
  "<remap> <tabulated-list-narrow-current-column>"
  #'my-codex-top-narrow-current-column
  "RET" #'my-codex-top-visit
  "e"   #'my-codex-top-visit-edit-window
  "k"   #'my-codex-top-kill-session
  "K"   #'my-codex-top-kill-dead-sessions
  "d"   #'my-codex-top-project-diff
  "D"   #'my-codex-top-dired-project
  "b"   #'my-codex-top-build-project
  "R"   #'my-codex-top-rename-session
  "g"   #'my-codex-top-refresh-git)

(define-derived-mode my-codex-top-mode tabulated-list-mode
  "Agents Top"
  "Major mode for monitoring agent sessions."
  (setq tabulated-list-format
        [("Active" 6 t)
         ("Agent" 12 t)
         ("Project" 12 t)
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
              '("  *Agents Top*  [D:Dired  b:Build  R:Rename  d:Diff  e:Edit  k:Kill  K:Kill dead  RET:Visit  g:Refresh]"))
  (tabulated-list-init-header)
  (my-codex--sync-header-hscroll))

(defun my-codex-top-refresh (&rest _)
  "Refresh the agent dashboard entries."
  (setq tabulated-list-entries (my-codex-top--make-entries))
  (tabulated-list-print t))

(defun my-codex-top-refresh-git ()
  "Refresh the dashboard, discarding cached Git information."
  (interactive)
  (clrhash my-codex-top--git-cache)
  (revert-buffer))

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

(defun my-codex-top--cached-git-info (root)
  "Return recently cached Git information for ROOT, or compute it."
  (let* ((now (float-time))
         (cached (gethash root my-codex-top--git-cache)))
    (if (and cached
             (< (- now (car cached)) my-codex-top-git-cache-ttl))
        (cdr cached)
      (let ((info (my-codex-top--git-info root)))
        (puthash root (cons now info) my-codex-top--git-cache)
        info))))

(defun my-codex-top--agent-label (agent)
  "Return a dashboard label for AGENT, including removed profiles."
  (if-let ((profile (alist-get agent my-codex-agent-profiles)))
      (or (plist-get profile :label) (symbol-name agent))
    (if agent (format "%s" agent) "—")))

(defun my-codex-top--make-entries ()
  "Build tabulated list entries for all agent sessions."
  (let ((git-cache (make-hash-table :test #'equal)))
    (mapcar
     (lambda (buffer)
       (let (active agent project session access state pid branch git-state prompts lines age last-act)
         (with-current-buffer buffer
           (let ((root my-codex-session-project-root)
                 (now (current-time)))
             (setq active (if (and root
                                    (eq buffer
                                        (gethash (my-codex--project-key root)
                                                 my-codex--project-active-sessions)))
                               "*"
                             "")
                 agent (my-codex-top--agent-label my-codex-session-agent)
                 project (if root (file-name-nondirectory (directory-file-name root)) "")
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
                                         (my-codex-top--cached-git-info root)
                                         git-cache))))
                 (setq branch cached-branch
                       git-state cached-state))
               (setq branch "—"
                     git-state "—"))))
         (list (buffer-name buffer)
               (vector active agent project session (buffer-name buffer) access state pid branch git-state prompts lines age last-act))))
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

(defun my-codex-top-kill-dead-sessions ()
  "Kill all session buffers that have no live process."
  (interactive)
  (let ((buffers (seq-remove #'my-codex--session-buffer-live-p
                             (my-codex--all-session-buffers))))
    (if (null buffers)
        (message "No dead session buffers")
      (when (yes-or-no-p
             (format "Kill %d dead session buffer%s? "
                     (length buffers)
                     (if (= (length buffers) 1) "" "s")))
        (mapc #'kill-buffer buffers)
        (revert-buffer)))))

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
               (agent my-codex-session-agent)
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

(provide 'my-codex-ui)

;;; my-codex-ui.el ends here
