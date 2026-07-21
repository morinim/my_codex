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
(autoload 'my-codex--line-bounds "my-codex-links" nil nil)
(autoload 'my-codex--linkify-session-region "my-codex-links" nil t)
(autoload 'my-codex-open-session-link-at-position "my-codex-links" nil t)
(defvar my-codex-session-link-map)
(defvar my-codex-eat-integration-mode)
(declare-function eat "eat" (&optional program new-session))
(defvar eat-buffer-name)
(defvar eat-terminal)
(defvar eat-term-scrollback-size)
(declare-function eat-term-display-beginning "eat" (terminal))
(declare-function eat-term-end "eat" (terminal))
(declare-function eat-term-input-event "eat" (terminal n event &optional ref-pos))
(declare-function eat-term-process-output "eat" (terminal output))
(declare-function eat-term-send-string "eat" (terminal string))
(declare-function eat-term-send-string-as-yank "eat" (terminal args))

(defconst my-codex--eat-link-refresh-delay 0.05
  "Seconds to coalesce Eat link refreshes.")

(defvar-local my-codex--eat-link-refresh-enabled nil
  "Non-nil when Eat link refresh hooks are installed.")

(defvar-local my-codex--eat-link-refresh-timer nil
  "Timer for a pending Eat link refresh.")

(defvar-local my-codex--eat-link-dirty-beg nil
  "Marker at the beginning of pending Eat link changes.")

(defvar-local my-codex--eat-link-dirty-end nil
  "Marker at the end of pending Eat link changes.")

(defvar-local my-codex--eat-previous-display-beg nil
  "Marker at Eat's display beginning before its latest update.")

(defun my-codex--eat-clear-link-overlays (&optional beg end)
  "Remove Eat link overlays between BEG and END.
When either bound is nil, use the corresponding buffer boundary."
  (remove-overlays (or beg (point-min)) (or end (point-max))
                   'my-codex-eat-link t))

(defun my-codex--eat-apply-link-overlays (&optional beg end)
  "Apply visible Eat link overlays between BEG and END."
  (let ((pos (or beg (point-min)))
        (end (or end (point-max)))
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
          (overlay-put overlay 'evaporate t)))
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
      (my-codex--record-outbound-prompt buffer prompt)
      (setq my-codex-session-last-activity (current-time))
      (setq my-codex-session-prompt-count
            (1+ (or my-codex-session-prompt-count 0))))))

(autoload 'my-codex-transient-preserve-selection "my-codex" nil t)

(defvar my-codex-eat-override-mode)

(defun my-codex--eat-linkify-after-update (&optional beg end)
  "Linkify rendered Eat output between BEG and END.
When either bound is nil, use the corresponding buffer boundary."
  (let ((beg (or beg (point-min)))
        (end (or end (point-max))))
    (pcase-let ((`(,rbeg . ,rend) (my-codex--line-bounds beg end)))
      (my-codex--eat-clear-link-overlays rbeg rend)
      (when (bound-and-true-p my-codex-session-links-mode)
        (my-codex--linkify-session-region beg end)
        (my-codex--eat-apply-link-overlays rbeg rend)))))

(defun my-codex--eat-current-display-beginning ()
  "Return the current Eat display beginning, or `point-min'."
  (if (and (bound-and-true-p eat-terminal)
           (fboundp 'eat-term-display-beginning))
      (max (point-min)
           (min (point-max)
                (eat-term-display-beginning eat-terminal)))
    (point-min)))

(defun my-codex--eat-current-display-end ()
  "Return the current Eat display end, or `point-max'."
  (if (and (bound-and-true-p eat-terminal)
           (fboundp 'eat-term-end))
      (max (point-min)
           (min (point-max) (eat-term-end eat-terminal)))
    (point-max)))

(defun my-codex--eat-release-marker (marker)
  "Detach MARKER from its buffer when it is a marker."
  (when (markerp marker)
    (set-marker marker nil)))

(defun my-codex--eat-cancel-link-refresh ()
  "Cancel and forget a pending Eat link refresh."
  (when (timerp my-codex--eat-link-refresh-timer)
    (cancel-timer my-codex--eat-link-refresh-timer))
  (setq my-codex--eat-link-refresh-timer nil)
  (my-codex--eat-release-marker my-codex--eat-link-dirty-beg)
  (my-codex--eat-release-marker my-codex--eat-link-dirty-end)
  (setq my-codex--eat-link-dirty-beg nil)
  (setq my-codex--eat-link-dirty-end nil))

(defun my-codex--eat-refresh-links (buffer)
  "Refresh pending session links in Eat BUFFER."
  (when (and (buffer-live-p buffer)
             (buffer-local-value
              'my-codex--eat-link-refresh-enabled buffer))
    (with-current-buffer buffer
      (setq my-codex--eat-link-refresh-timer nil)
      (let ((beg (and (markerp my-codex--eat-link-dirty-beg)
                      (marker-position my-codex--eat-link-dirty-beg)))
            (end (and (markerp my-codex--eat-link-dirty-end)
                      (marker-position my-codex--eat-link-dirty-end))))
        (my-codex--eat-release-marker my-codex--eat-link-dirty-beg)
        (my-codex--eat-release-marker my-codex--eat-link-dirty-end)
        (setq my-codex--eat-link-dirty-beg nil)
        (setq my-codex--eat-link-dirty-end nil)
        (when (and beg end
                   (bound-and-true-p my-codex-session-links-mode))
          (my-codex--eat-linkify-after-update beg end))))))

(defun my-codex--eat-schedule-link-refresh ()
  "Coalesce a link refresh for the current Eat display."
  (when (bound-and-true-p my-codex-session-links-mode)
    (let* ((display-beg (my-codex--eat-current-display-beginning))
           (previous-beg
            (and (markerp my-codex--eat-previous-display-beg)
                 (marker-position my-codex--eat-previous-display-beg)))
           (beg (min display-beg (or previous-beg display-beg)))
           (end (my-codex--eat-current-display-end)))
      (if (markerp my-codex--eat-previous-display-beg)
          (set-marker my-codex--eat-previous-display-beg display-beg)
        (setq my-codex--eat-previous-display-beg
              (copy-marker display-beg)))
      (if (markerp my-codex--eat-link-dirty-beg)
          (when (< beg (marker-position my-codex--eat-link-dirty-beg))
            (set-marker my-codex--eat-link-dirty-beg beg))
        (setq my-codex--eat-link-dirty-beg (copy-marker beg)))
      (if (markerp my-codex--eat-link-dirty-end)
          (when (> end (marker-position my-codex--eat-link-dirty-end))
            (set-marker my-codex--eat-link-dirty-end end))
        (setq my-codex--eat-link-dirty-end (copy-marker end t)))
      (unless my-codex--eat-link-refresh-timer
        (setq my-codex--eat-link-refresh-timer
              (run-with-timer my-codex--eat-link-refresh-delay nil
                              #'my-codex--eat-refresh-links
                              (current-buffer)))))))

(defun my-codex--eat-session-links-mode-changed ()
  "Update Eat link refresh state after session links mode changes."
  (my-codex--eat-cancel-link-refresh)
  (my-codex--eat-release-marker my-codex--eat-previous-display-beg)
  (setq my-codex--eat-previous-display-beg nil)
  (if (bound-and-true-p my-codex-session-links-mode)
      (progn
        (my-codex--eat-linkify-after-update)
        (setq my-codex--eat-previous-display-beg
              (copy-marker (my-codex--eat-current-display-beginning))))
    (my-codex--eat-clear-link-overlays)))

(defun my-codex--eat-update-hook-supported-p ()
  "Return non-nil when loaded Eat declares `eat-update-hook'."
  (and (featurep 'eat)
       (boundp 'eat-update-hook)
       (get 'eat-update-hook 'variable-documentation)))

(defun my-codex--eat-process-output-queue-advice (buffer)
  "Refresh BUFFER after an Eat output queue update.
This is retained for Eat versions without `eat-update-hook'."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (my-codex--eat-linkify-after-update))))

(defun my-codex--enable-eat-output-linkification ()
  "Enable the legacy Eat output advice when no update hook is available."
  (when (fboundp 'eat--process-output-queue)
    (unless (advice-member-p #'my-codex--eat-process-output-queue-advice
                             'eat--process-output-queue)
      (advice-add 'eat--process-output-queue :after
                  #'my-codex--eat-process-output-queue-advice))))

(defun my-codex--enable-eat-workarounds-when-active ()
  "Enable Eat compatibility workarounds when integration is active."
  (when my-codex-eat-integration-mode
    (my-codex--enable-eat-output-boundary-workaround)))

(defun my-codex--eat-term-process-output-advice (fn terminal output)
  "Call FN with TERMINAL and OUTPUT, tolerating Eat's chunk-boundary bug."
  (condition-case err
      (funcall fn terminal output)
    (args-out-of-range
     (unless (and (= (length err) 3)
                  (equal (nth 1 err) output)
                  (equal (nth 2 err) (length output)))
       (signal (car err) (cdr err))))))

(defun my-codex--enable-eat-output-boundary-workaround ()
  "Work around Eat 0.9.4 reading past an incomplete output chunk."
  (when (fboundp 'eat-term-process-output)
    (unless (advice-member-p #'my-codex--eat-term-process-output-advice
                             'eat-term-process-output)
      (advice-add 'eat-term-process-output :around
                  #'my-codex--eat-term-process-output-advice))))

(defun my-codex--enable-eat-session-links ()
  "Enable session link refreshes for Eat terminal updates."
  (unless my-codex--eat-link-refresh-enabled
    (setq my-codex--eat-link-refresh-enabled t)
    (if (my-codex--eat-update-hook-supported-p)
        (add-hook 'eat-update-hook #'my-codex--eat-schedule-link-refresh nil t)
      (my-codex--enable-eat-output-linkification))
    (add-hook 'my-codex-session-links-mode-hook
              #'my-codex--eat-session-links-mode-changed nil t)
    (add-hook 'kill-buffer-hook #'my-codex--eat-cancel-link-refresh nil t)
    (my-codex--eat-session-links-mode-changed)))

(defun my-codex--disable-eat-session-links ()
  "Disable session link refreshes in the current Eat buffer."
  (remove-hook 'eat-update-hook #'my-codex--eat-schedule-link-refresh t)
  (remove-hook 'my-codex-session-links-mode-hook
               #'my-codex--eat-session-links-mode-changed t)
  (remove-hook 'kill-buffer-hook #'my-codex--eat-cancel-link-refresh t)
  (my-codex--eat-cancel-link-refresh)
  (my-codex--eat-release-marker my-codex--eat-previous-display-beg)
  (setq my-codex--eat-previous-display-beg nil)
  (setq my-codex--eat-link-refresh-enabled nil)
  (my-codex--eat-clear-link-overlays))

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
    (my-codex--enable-eat-session-links)
    (my-codex-eat-override-mode 1)))

(defun my-codex--disable-eat-buffer-integration ()
  "Disable my-codex helpers in the current Eat buffer."
  (my-codex--disable-eat-session-links)
  (my-codex-eat-override-mode -1))

(defun my-codex--enable-eat-integration ()
  "Enable my-codex helpers for Eat."
  (with-eval-after-load 'eat
    (my-codex--enable-eat-workarounds-when-active))
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (my-codex--enable-eat-buffer-integration))))

(defun my-codex--disable-eat-integration ()
  "Disable my-codex helpers for Eat."
  (when (fboundp 'eat-term-process-output)
    (advice-remove 'eat-term-process-output
                   #'my-codex--eat-term-process-output-advice))
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
