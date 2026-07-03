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
