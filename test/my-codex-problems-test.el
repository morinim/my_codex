;;; my-codex-problems-test.el --- Tests for my-codex-problems -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Code:

(require 'ert)
(require 'my-codex-problems)

(ert-deftest my-codex-compilation-context-collects-parsed-problem ()
  (let ((buffer (generate-new-buffer " *my-codex-compilation*"))
        (root (file-name-as-directory default-directory)))
    (unwind-protect
        (with-current-buffer buffer
          (setq default-directory root)
          (compilation-mode)
          (let ((inhibit-read-only t))
            (insert "before\n"
                    "my-codex-problems.el:36:2: error: broken thing\n"
                    "after\n"))
          (setq-local compilation-arguments '("make test"))
          (goto-char (point-min))
          (forward-line 1)
          (let ((context (my-codex--compilation-context buffer t)))
            (should (equal (plist-get context :command) "make test"))
            (should (equal (plist-get context :file)
                           "my-codex-problems.el"))
            (should (= (plist-get context :line) 36))
            (should (= (plist-get context :column) 2))
            (should (equal (plist-get context :severity) "error"))
            (should (string-match-p "before" (plist-get context :output)))
            (should (string-match-p
                     "broken thing" (plist-get context :output)))
            (should (string-match-p
                     "my-codex--problem-region-prompt"
                     (plist-get context :source-excerpt)))))
      (kill-buffer buffer))))

(ert-deftest my-codex-compilation-buffer-for-subject-uses-recent-project-buffer ()
  (let ((subject (generate-new-buffer " *my-codex-subject*"))
        (compilation (generate-new-buffer " *my-codex-compilation*"))
        (next-error-last-buffer nil))
    (unwind-protect
        (progn
          (with-current-buffer compilation
            (compilation-mode))
          (setq next-error-last-buffer compilation)
          (cl-letf (((symbol-function 'my-codex--same-project-p)
                     (lambda (left right)
                       (and (eq left subject)
                            (eq right compilation)))))
            (should
             (eq (my-codex--compilation-buffer-for-subject subject)
                 compilation))))
      (kill-buffer subject)
      (kill-buffer compilation))))

(ert-deftest my-codex-compilation-context-keeps-unresolved-file-label ()
  (let ((buffer (generate-new-buffer " *my-codex-compilation*"))
        (root (file-name-as-directory default-directory)))
    (unwind-protect
        (with-current-buffer buffer
          (setq default-directory root)
          (compilation-mode)
          (let ((inhibit-read-only t))
            (insert "missing-example.c:7: error: unavailable source\n"))
          (goto-char (point-min))
          (let ((context (my-codex--compilation-context buffer t)))
            (should (equal (plist-get context :file) "missing-example.c"))
            (should-not (plist-get context :source-excerpt))))
      (kill-buffer buffer))))

(ert-deftest my-codex-compilation-buffer-for-subject-rejects-other-project ()
  (let ((subject (generate-new-buffer " *my-codex-subject*"))
        (compilation (generate-new-buffer " *my-codex-compilation*"))
        (next-error-last-buffer nil))
    (unwind-protect
        (progn
          (with-current-buffer compilation
            (compilation-mode))
          (setq next-error-last-buffer compilation)
          (cl-letf (((symbol-function 'my-codex--same-project-p)
                     (lambda (_left _right) nil)))
            (should-not
             (my-codex--compilation-buffer-for-subject subject))))
      (kill-buffer subject)
      (kill-buffer compilation))))

(ert-deftest my-codex-explain-problem-prefers-invoking-region ()
  (let (sent)
    (cl-letf (((symbol-function 'my-codex--problem-region-prompt)
               (lambda () "region prompt"))
              ((symbol-function 'my-codex--subject-buffer)
               (lambda () (ert-fail "Subject buffer was consulted")))
              ((symbol-function 'my-codex--preview-and-send-prompt)
               (lambda (prompt &optional _message)
                 (setq sent prompt))))
      (my-codex-explain-problem)
      (should (equal sent "region prompt")))))

(ert-deftest my-codex-explain-problem-uses-subject-fallback-order ()
  (let ((subject (generate-new-buffer " *my-codex-subject*"))
        calls
        sent)
    (unwind-protect
        (cl-letf (((symbol-function 'my-codex--problem-region-prompt)
                   (lambda ()
                     (push (list 'region (current-buffer)) calls)
                     nil))
                  ((symbol-function 'my-codex--subject-buffer)
                   (lambda () subject))
                  ((symbol-function 'my-codex--diagnostic-problem-prompt)
                   (lambda ()
                     (push (list 'diagnostic (current-buffer)) calls)
                     "diagnostic prompt"))
                  ((symbol-function 'my-codex--compilation-context-for-subject)
                   (lambda ()
                     (ert-fail "Compilation fallback was consulted")))
                  ((symbol-function 'my-codex--preview-and-send-prompt)
                   (lambda (prompt &optional _message)
                     (setq sent prompt))))
          (my-codex-explain-problem)
          (should (equal sent "diagnostic prompt"))
          (should (equal (nreverse calls)
                         (list (list 'region (current-buffer))
                               (list 'region subject)
                               (list 'diagnostic subject)))))
      (kill-buffer subject))))

(ert-deftest my-codex-explain-problem-uses-associated-subject-region ()
  (let ((subject (generate-new-buffer " *my-codex-subject*"))
        (transient-mark-mode t)
        sent)
    (unwind-protect
        (progn
          (with-current-buffer subject
            (insert "selected failure")
            (set-mark (point-min))
            (setq mark-active t))
          (cl-letf (((symbol-function 'my-codex--subject-buffer)
                     (lambda () subject))
                    ((symbol-function 'my-codex--diagnostic-problem-prompt)
                     (lambda ()
                       (ert-fail "Diagnostic fallback was consulted")))
                    ((symbol-function 'my-codex--preview-and-send-prompt)
                     (lambda (prompt &optional _message)
                       (setq sent prompt))))
            (my-codex-explain-problem)
            (should (string-match-p "selected failure" sent))))
      (kill-buffer subject))))

(ert-deftest my-codex-explain-problem-falls-back-to-compilation ()
  (let ((subject (generate-new-buffer " *my-codex-subject*"))
        sent)
    (unwind-protect
        (cl-letf (((symbol-function 'my-codex--problem-region-prompt)
                   (lambda () nil))
                  ((symbol-function 'my-codex--subject-buffer)
                   (lambda () subject))
                  ((symbol-function 'my-codex--diagnostic-problem-prompt)
                   (lambda () nil))
                  ((symbol-function 'my-codex--compilation-context-for-subject)
                   (lambda () '(:output "broken" :directory "/repo/"
                                :severity "error")))
                  ((symbol-function 'my-codex--preview-and-send-prompt)
                   (lambda (prompt &optional _message)
                     (setq sent prompt))))
          (my-codex-explain-problem)
          (should (string-match-p "source: compilation" sent))
          (should (string-match-p "broken" sent)))
      (kill-buffer subject))))

(ert-deftest my-codex-explain-problem-errors-without-context ()
  (cl-letf (((symbol-function 'my-codex--problem-region-prompt)
             (lambda () nil))
            ((symbol-function 'my-codex--subject-buffer)
             (lambda () (current-buffer)))
            ((symbol-function 'my-codex--diagnostic-problem-prompt)
             (lambda () nil))
            ((symbol-function 'my-codex--compilation-context-for-subject)
             (lambda () nil)))
    (should-error (my-codex-explain-problem) :type 'user-error)))

(ert-deftest my-codex-explain-compilation-error-uses-subject-buffer ()
  (let ((subject (generate-new-buffer " *my-codex-subject*"))
        observed-buffer
        sent)
    (unwind-protect
        (cl-letf (((symbol-function 'my-codex--subject-buffer)
                   (lambda () subject))
                  ((symbol-function 'my-codex--compilation-context-for-subject)
                   (lambda ()
                     (setq observed-buffer (current-buffer))
                     '(:output "broken" :directory "/repo/"
                       :severity "error")))
                  ((symbol-function 'my-codex--preview-and-send-prompt)
                   (lambda (prompt &optional _message)
                     (setq sent prompt))))
          (my-codex-explain-compilation-error-at-point)
          (should (eq observed-buffer subject))
          (should (string-match-p "source: compilation" sent)))
      (kill-buffer subject))))

(provide 'my-codex-problems-test)

;;; my-codex-problems-test.el ends here
