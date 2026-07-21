;;; my-codex-layout-test.el --- Tests for my-codex-layout -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'my-codex-layout)

(defmacro my-codex-layout-test--with-windows (bindings &rest body)
  "Run BODY with edit and agent windows and buffers bound by BINDINGS."
  (declare (indent 1) (debug (sexp body)))
  (pcase-let ((`(,edit-window ,agent-window ,edit-buffer ,agent-buffer)
               bindings))
    `(let ((,edit-buffer (generate-new-buffer " *my-codex-edit-test*"))
           (,agent-buffer (generate-new-buffer " *my-codex-agent-test*")))
       (unwind-protect
           (save-window-excursion
             (delete-other-windows)
             (let ((,edit-window (selected-window))
                   (,agent-window (split-window-right)))
               (set-window-buffer ,edit-window ,edit-buffer)
               (set-window-buffer ,agent-window ,agent-buffer)
               ,@body))
         (kill-buffer ,edit-buffer)
         (kill-buffer ,agent-buffer)))))

(ert-deftest my-codex-visible-window-uses-active-session-window ()
  (let ((expected (selected-window)))
    (cl-letf (((symbol-function 'my-codex-active-session-window)
               (lambda () expected)))
      (should (eq (my-codex-visible-window) expected)))))

(ert-deftest my-codex-effective-right-width-uses-target-without-minimum ()
  (let ((my-codex-right-width 60)
        (my-codex-min-right-width nil))
    (should (= (my-codex--effective-right-width) 60))))

(ert-deftest my-codex-effective-right-width-honours-optional-minimum ()
  (let ((my-codex-right-width 60)
        (my-codex-min-right-width 80))
    (should (= (my-codex--effective-right-width) 80)))
  (let ((my-codex-right-width 100)
        (my-codex-min-right-width 80))
    (should (= (my-codex--effective-right-width) 100))))

(ert-deftest my-codex-right-layout-width-combines-edit-and-agent-widths ()
  (let ((my-codex-left-width 81)
        (my-codex-right-width 60)
        (my-codex-min-right-width nil))
    (should (= (my-codex--right-layout-width) 141))))

(ert-deftest my-codex-associated-edit-window-prefers-window-parameters ()
  (my-codex-layout-test--with-windows
      (edit-window agent-window edit-buffer agent-buffer)
    (set-window-parameter edit-window 'my-codex-edit-window t)
    (set-window-parameter edit-window 'my-codex-term-buffer agent-buffer)
    (cl-letf (((symbol-function 'my-codex-visible-window)
               (lambda () agent-window)))
      (should (eq (my-codex-associated-edit-window) edit-window)))))

(ert-deftest my-codex-associated-edit-window-falls-back-to-next-window ()
  (my-codex-layout-test--with-windows
      (edit-window agent-window edit-buffer agent-buffer)
    (cl-letf (((symbol-function 'my-codex-visible-window)
               (lambda () agent-window)))
      (should (eq (my-codex-associated-edit-window) edit-window)))))

(ert-deftest my-codex-associated-edit-window-requires-another-window ()
  (save-window-excursion
    (delete-other-windows)
    (cl-letf (((symbol-function 'my-codex-visible-window)
               (lambda () (selected-window))))
      (should-error (my-codex-associated-edit-window)
                    :type 'user-error))))

(ert-deftest my-codex-layout-removes-window-buffer-hook-when-unused ()
  (let ((window-buffer-change-functions nil)
        (my-codex--edit-fill-column-indicator-buffers nil))
    (my-codex-layout-test--with-windows
        (edit-window agent-window edit-buffer agent-buffer)
      (my-codex--enable-edit-fill-column-indicator
       edit-window agent-window)
      (should (memq #'my-codex--refresh-edit-fill-column-indicator-windows
                    window-buffer-change-functions))
      (delete-window agent-window)
      (my-codex--refresh-edit-fill-column-indicator-windows
       (selected-frame))
      (should-not my-codex--edit-fill-column-indicator-buffers)
      (should-not
       (memq #'my-codex--refresh-edit-fill-column-indicator-windows
             window-buffer-change-functions)))))

(ert-deftest my-codex-layout-keeps-window-buffer-hook-for-marked-window ()
  (let ((window-buffer-change-functions
         (list #'my-codex--refresh-edit-fill-column-indicator-windows))
        (my-codex--edit-fill-column-indicator-buffers nil)
        (marked-window 'marked-window))
    (cl-letf (((symbol-function 'frame-list) (lambda () '(other-frame)))
              ((symbol-function 'window-list)
               (lambda (&rest _args) (list marked-window)))
              ((symbol-function 'window-parameter)
               (lambda (window parameter)
                 (and (eq window marked-window)
                      (eq parameter 'my-codex-edit-window)))))
      (my-codex--remove-edit-fill-column-indicator-hook-if-unused))
    (should (memq #'my-codex--refresh-edit-fill-column-indicator-windows
                  window-buffer-change-functions))))

(ert-deftest my-codex-layout-unload-restores-managed-display-state ()
  (let ((window-buffer-change-functions nil)
        (my-codex--edit-fill-column-indicator-buffers nil))
    (my-codex-layout-test--with-windows
        (edit-window agent-window edit-buffer agent-buffer)
      (with-current-buffer edit-buffer
        (display-fill-column-indicator-mode -1))
      (my-codex--enable-edit-fill-column-indicator
       edit-window agent-window)
      (my-codex-layout-unload-function)
      (should-not my-codex--edit-fill-column-indicator-buffers)
      (should-not
       (memq #'my-codex--refresh-edit-fill-column-indicator-windows
             window-buffer-change-functions))
      (should-not
       (buffer-local-value 'display-fill-column-indicator-mode
                           edit-buffer))
      (should-not (window-parameter edit-window 'my-codex-edit-buffer))
      (should-not (window-parameter edit-window 'my-codex-edit-window))
      (should-not (window-parameter edit-window 'my-codex-term-buffer)))))

(ert-deftest my-codex-toggle-focus-switches-both-ways ()
  (my-codex-layout-test--with-windows
      (edit-window agent-window edit-buffer agent-buffer)
    (cl-letf (((symbol-function 'my-codex-visible-window)
               (lambda () agent-window))
              ((symbol-function 'my-codex-associated-edit-window)
               (lambda () edit-window)))
      (select-window edit-window)
      (my-codex-toggle-focus)
      (should (eq (selected-window) agent-window))
      (my-codex-toggle-focus)
      (should (eq (selected-window) edit-window)))))

(ert-deftest my-codex-layout-records-existing-session-on-edit-window ()
  (let* ((root (file-name-as-directory (make-temp-file "my-codex-layout" t)))
         (session "review")
         (agent 'antigravity)
         (buffer-name (let ((default-directory root))
                        (my-codex-session-buffer-name session agent)))
         (existing (get-buffer-create buffer-name)))
    (unwind-protect
        (let ((default-directory root))
          (my-codex--mark-named-session
           existing session root 'read-only agent)
          (save-window-excursion
            (delete-other-windows)
            (let ((edit-window (selected-window))
                  term-window)
              (cl-letf (((symbol-function 'project-current)
                         (lambda (&rest _args) nil))
                        ((symbol-function 'my-codex-project-root)
                         (lambda () root))
                        ((symbol-function 'my-codex--fit-frame-to-right-layout)
                         #'ignore)
                        ((symbol-function 'my-codex--apply-display-window-width)
                         #'ignore)
                        ((symbol-function 'my-codex--resize-edit-window-for-right-layout)
                         #'ignore)
                        ((symbol-function 'my-codex--enable-edit-fill-column-indicator)
                         #'ignore)
                        ((symbol-function 'my-codex-backend-live-p)
                         (lambda (_backend) t))
                        ((symbol-function 'my-codex-backend-start)
                         (lambda (&rest _args)
                           (error "Should not start existing session")))
                        ((symbol-function 'display-buffer)
                         (lambda (buffer &rest _args)
                           (setq term-window (split-window-right))
                           (set-window-buffer term-window buffer)
                           term-window)))
                (my-codex-two-column-layout-with-command
                 (my-codex--agent-command agent 'read-only)
                 nil session agent 'read-only)
                (should (eq (window-parameter edit-window
                                               'my-codex-term-buffer)
                            existing))))))
      (when (buffer-live-p existing)
        (kill-buffer existing))
      (delete-directory root t))))

(ert-deftest my-codex-layout-records-explicit-startup-prompt ()
  (let* ((root (file-name-as-directory (make-temp-file "my-codex-layout" t)))
         (buffer-name "*my-codex-layout-startup*")
         (prompt "Read only; do not edit")
         (command "agy")
         (my-codex--project-active-agents (make-hash-table :test #'equal))
         (my-codex--project-active-sessions (make-hash-table :test #'equal)))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (let (term-window)
            (cl-letf (((symbol-function 'my-codex-project-root)
                       (lambda () root))
                      ((symbol-function 'my-codex-session-buffer-name)
                       (lambda (&rest _args) buffer-name))
                      ((symbol-function 'my-codex--fit-frame-to-right-layout)
                       #'ignore)
                      ((symbol-function 'my-codex--apply-display-window-width)
                       #'ignore)
                      ((symbol-function
                        'my-codex--resize-edit-window-for-right-layout)
                       #'ignore)
                      ((symbol-function
                        'my-codex--enable-edit-fill-column-indicator)
                       #'ignore)
                      ((symbol-function 'my-codex-backend-start)
                       (lambda (_backend project-root _command
                                &optional session agent access)
                         (let ((buffer (get-buffer-create buffer-name)))
                           (my-codex--mark-named-session
                            buffer session project-root access agent)
                           buffer)))
                      ((symbol-function 'display-buffer)
                       (lambda (buffer &rest _args)
                         (setq term-window (split-window-right))
                         (set-window-buffer term-window buffer)
                         term-window)))
              (my-codex-two-column-layout-with-command
               command nil "review" 'antigravity 'read-only prompt)))
          (with-current-buffer buffer-name
            (should
             (= my-codex-session-prompt-token-estimate
                (my-codex--approx-token-count prompt)))))
      (when-let ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest my-codex-selected-text-consumes-captured-selection ()
  (let ((my-codex--captured-selection "selected")
        (window (selected-window)))
    (cl-letf (((symbol-function 'my-codex-visible-window)
               (lambda () window))
              ((symbol-function 'use-region-p) (lambda () nil)))
      (should (equal (my-codex-selected-text) "selected"))
      (should-not my-codex--captured-selection))))

(ert-deftest my-codex-selected-text-requires-selection ()
  (let ((my-codex--captured-selection nil)
        (window (selected-window)))
    (cl-letf (((symbol-function 'my-codex-visible-window)
               (lambda () window))
              ((symbol-function 'use-region-p) (lambda () nil)))
      (should-error (my-codex-selected-text) :type 'user-error))))

(ert-deftest my-codex-insert-selection-into-code-selects-and-inserts ()
  (my-codex-layout-test--with-windows
      (edit-window agent-window edit-buffer agent-buffer)
    (select-window agent-window)
    (cl-letf (((symbol-function 'my-codex-selected-text)
               (lambda () "selected"))
              ((symbol-function 'my-codex-associated-edit-window)
               (lambda () edit-window)))
      (my-codex-insert-selection-into-code)
      (should (eq (selected-window) edit-window))
      (should (equal (with-current-buffer edit-buffer (buffer-string))
                     "selected")))))

(provide 'my-codex-layout-test)

;;; my-codex-layout-test.el ends here
