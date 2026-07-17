;;; my-codex-diagnostics-test.el --- Tests for my-codex-diagnostics -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Code:

(require 'ert)
(require 'my-codex-diagnostics)

(defvar flycheck-current-errors)
(defvar flycheck-mode)
(defvar flymake-mode)

(defmacro my-codex-test--with-mock-flycheck (diagnostics &rest body)
  "Run BODY with mocked Flycheck DIAGNOSTICS."
  (declare (indent 1))
  `(let ((flycheck-mode t)
         (flycheck-current-errors ,diagnostics))
     (cl-letf (((symbol-function 'flycheck-error-<)
                (lambda (left right)
                  (let ((left-line (or (plist-get left :line) 1))
                        (right-line (or (plist-get right :line) 1))
                        (left-column (or (plist-get left :column) 1))
                        (right-column (or (plist-get right :column) 1)))
                    (if (/= left-line right-line)
                        (< left-line right-line)
                      (< left-column right-column)))))
               ((symbol-function 'flycheck-error-checker)
                (lambda (diagnostic) (plist-get diagnostic :checker)))
               ((symbol-function 'flycheck-error-column)
                (lambda (diagnostic) (plist-get diagnostic :column)))
               ((symbol-function 'flycheck-error-filename)
                (lambda (diagnostic) (plist-get diagnostic :filename)))
               ((symbol-function 'flycheck-error-id)
                (lambda (diagnostic) (plist-get diagnostic :id)))
               ((symbol-function 'flycheck-error-level)
                (lambda (diagnostic) (plist-get diagnostic :level)))
               ((symbol-function 'flycheck-error-line)
                (lambda (diagnostic) (plist-get diagnostic :line)))
               ((symbol-function 'flycheck-error-message)
                (lambda (diagnostic) (plist-get diagnostic :message))))
       ,@body)))

(ert-deftest my-codex-flycheck-diagnostics-sorts-current-errors ()
  (let ((diagnostics
         '((:line 10 :column 1 :message "third")
           (:line 2 :column 8 :message "second")
           (:line 2 :column 3 :message "first"))))
    (my-codex-test--with-mock-flycheck diagnostics
      (should
       (equal
        (mapcar (lambda (diagnostic)
                  (plist-get diagnostic :message))
                (my-codex--flycheck-diagnostics))
        '("first" "second" "third"))))))

(ert-deftest my-codex-flycheck-diagnostics-errors-when-inactive ()
  (let ((flycheck-mode nil)
        (flycheck-current-errors nil))
    (should-error
     (my-codex--flycheck-diagnostics)
     :type 'user-error)))

(ert-deftest my-codex-flycheck-diagnostic-at-point-selects-nearest-column ()
  (let ((diagnostics
         '((:line 2 :column 4 :message "left")
           (:line 2 :column 12 :message "right")
           (:line 3 :column 1 :message "other"))))
    (with-temp-buffer
      (insert "one\n012345678901234\nthree\n")
      (goto-char (point-min))
      (forward-line 1)
      (move-to-column 10)
      (my-codex-test--with-mock-flycheck diagnostics
        (should
         (equal
          (plist-get
           (my-codex--flycheck-diagnostic-at-point
            (my-codex--flycheck-diagnostics))
           :message)
          "right"))))))

(ert-deftest my-codex-flycheck-diagnostic-at-point-uses-absolute-line-in-narrowed-buffer ()
  (let ((diagnostics
         '((:line 2 :column 1 :message "wrong-relative-line")
           (:line 4 :column 1 :message "absolute-line"))))
    (with-temp-buffer
      (insert "one\ntwo\nthree\nfour\nfive\n")
      (narrow-to-region (save-excursion
                          (goto-char (point-min))
                          (forward-line 2)
                          (point))
                        (point-max))
      (goto-char (point-min))
      (forward-line 1)
      (my-codex-test--with-mock-flycheck diagnostics
        (should
         (equal
          (plist-get
           (my-codex--flycheck-diagnostic-at-point
            (my-codex--flycheck-diagnostics))
           :message)
          "absolute-line"))))))

(ert-deftest my-codex-flycheck-diagnostic-at-point-ignores-other-files ()
  (let* ((root (file-name-as-directory (make-temp-file "my-codex-flycheck" t)))
         (current-file (expand-file-name "src/current.el" root))
         (other-file (expand-file-name "src/other.el" root))
         (diagnostics
          `((:filename ,other-file
             :line 2
             :column 10
             :message "other-file")
            (:filename ,current-file
             :line 2
             :column 1
             :message "current-file"))))
    (unwind-protect
        (with-temp-buffer
          (setq buffer-file-name current-file)
          (insert "one\ntwo\n")
          (goto-char (point-min))
          (forward-line 1)
          (move-to-column 9)
          (my-codex-test--with-mock-flycheck diagnostics
            (should
             (equal
              (plist-get
               (my-codex--flycheck-diagnostic-at-point
                (my-codex--flycheck-diagnostics))
               :message)
              "current-file"))))
      (delete-directory root t))))

(ert-deftest my-codex-flycheck-diagnostic-at-point-errors-without-current-line-diagnostic ()
  (let ((diagnostics '((:line 3 :column 1 :message "other"))))
    (with-temp-buffer
      (insert "one\ntwo\nthree\n")
      (goto-char (point-min))
      (forward-line 1)
      (my-codex-test--with-mock-flycheck diagnostics
        (should-error
         (my-codex--flycheck-diagnostic-at-point
          (my-codex--flycheck-diagnostics))
         :type 'user-error)))))

(ert-deftest my-codex-flycheck-diagnostics-prompt-formats-diagnostics ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-flycheck" t))))
    (unwind-protect
        (with-temp-buffer
          (let ((file (expand-file-name "src/example.el" root)))
            (setq buffer-file-name file)
            (my-codex-test--with-mock-flycheck
                `((:filename ,file
                   :line 7
                   :column 11
                   :level warning
                   :checker emacs-lisp
                   :id "free-vars"
                   :message "reference to free variable `value'")
                  (:filename ,file
                   :line 8
                   :column 3
                   :level warning
                   :checker emacs-lisp
                   :message "unused lexical argument"))
              (cl-letf (((symbol-function 'my-codex-project-root)
                         (lambda () root)))
                (let* ((my-codex-flycheck-diagnostics-limit 100)
                       (prompt (my-codex--flycheck-diagnostics-prompt
                                (my-codex--flycheck-diagnostics))))
                  (should
                   (string-match-p
                    "Analyse these Flycheck diagnostics as a batch" prompt))
                  (should (string-match-p "source: Flycheck" prompt))
                  (should (string-match-p "diagnostic_count: 2" prompt))
                  (should (string-match-p "truncated: false" prompt))
                  (should (string-match-p "file: \"src/example\\.el\"" prompt))
                  (should (string-match-p "diagnostics:" prompt))
                  (should (string-match-p "- line: 7" prompt))
                  (should (string-match-p "  column: 11" prompt))
                  (should (string-match-p "  severity: \"warning\"" prompt))
                  (should (string-match-p "  checker: \"emacs-lisp\"" prompt))
                  (should (string-match-p "  id: \"free-vars\"" prompt))
                  (should
                   (string-match-p
                    "message: \"reference to free variable `value'\""
                    prompt))
                  (should (string-match-p "- line: 8" prompt))
                  (should
                   (string-match-p
                    "message: \"unused lexical argument\""
                    prompt))
                  (should
                   (= 1
                      (let ((start 0)
                            (count 0))
                        (while (string-match
                                "file: \"src/example\\.el\""
                                prompt start)
                          (setq count (1+ count)
                                start (match-end 0)))
                        count))))))))
      (delete-directory root t))))

(ert-deftest my-codex-explain-diagnostic-at-point-sends-single-flycheck-prompt ()
  (let ((diagnostics
         '((:line 1
            :column 2
            :level error
            :checker mock-checker
            :message "broken")
           (:line 2
            :column 1
            :level warning
            :checker mock-checker
            :message "other")))
        sent)
    (with-temp-buffer
      (insert "broken\nother\n")
      (goto-char (point-min))
      (my-codex-test--with-mock-flycheck diagnostics
        (cl-letf (((symbol-function 'my-codex-project-root)
                   (lambda () "/repo/"))
                  ((symbol-function 'my-codex--preview-and-send-prompt)
                   (lambda (prompt) (setq sent prompt))))
          (my-codex-explain-diagnostic-at-point)
          (should sent)
          (should
           (string-match-p
            "Explain this Flycheck diagnostic" sent))
          (should (string-match-p "source: Flycheck" sent))
          (should (string-match-p "message: \"broken\"" sent))
          (should-not (string-match-p "message: \"other\"" sent)))))))

(ert-deftest my-codex-flycheck-diagnostics-prompt-reports-truncation ()
  (let ((my-codex-flycheck-diagnostics-limit 2)
        (diagnostics
         '((:line 1 :column 1 :level error :checker mock :message "first")
           (:line 2 :column 1 :level error :checker mock :message "second")
           (:line 3 :column 1 :level error :checker mock :message "third"))))
    (my-codex-test--with-mock-flycheck diagnostics
      (cl-letf (((symbol-function 'my-codex-project-root)
                 (lambda () "/repo/")))
        (let ((prompt (my-codex--flycheck-diagnostics-prompt diagnostics)))
          (should (string-match-p "diagnostic_count: 3" prompt))
          (should (string-match-p "included_count: 2" prompt))
          (should (string-match-p "truncated: true" prompt))
          (should (string-match-p "message: \"first\"" prompt))
          (should (string-match-p "message: \"second\"" prompt))
          (should-not (string-match-p "message: \"third\"" prompt)))))))

(ert-deftest my-codex-flycheck-diagnostics-prompt-deduplicates-diagnostics ()
  (let ((diagnostics
         '((:line 1 :column 1 :level error :checker mock :message "same")
           (:line 1 :column 1 :level error :checker mock :message "same")
           (:line 2 :column 1 :level error :checker mock :message "other"))))
    (my-codex-test--with-mock-flycheck diagnostics
      (cl-letf (((symbol-function 'my-codex-project-root)
                 (lambda () "/repo/")))
        (let ((prompt (my-codex--flycheck-diagnostics-prompt diagnostics)))
          (should (string-match-p "diagnostic_count: 3" prompt))
          (should (string-match-p "unique_diagnostic_count: 2" prompt))
          (should (string-match-p "included_count: 2" prompt))
          (should (string-match-p "omitted_count: 1" prompt))
          (should (= 1
                     (let ((start 0)
                           (count 0))
                       (while (string-match "message: \"same\"" prompt start)
                         (setq count (1+ count)
                               start (match-end 0)))
                       count))))))))

(ert-deftest my-codex-flycheck-diagnostics-prompt-groups-repeated-messages ()
  (let ((diagnostics
         '((:line 1 :column 1 :level error :checker mock :message "repeat")
           (:line 2 :column 3 :level error :checker mock :message "repeat")
           (:line 4 :column 1 :level warning :checker mock :message "repeat"))))
    (my-codex-test--with-mock-flycheck diagnostics
      (cl-letf (((symbol-function 'my-codex-project-root)
                 (lambda () "/repo/")))
        (let ((prompt (my-codex--flycheck-diagnostics-prompt diagnostics)))
          (should (string-match-p "occurrence_count: 2" prompt))
          (should (string-match-p "locations:" prompt))
          (should (string-match-p "- line: 1" prompt))
          (should (string-match-p "- line: 2" prompt))
          (should (string-match-p "- line: 4" prompt)))))))

(ert-deftest my-codex-flycheck-diagnostics-prompt-obeys-context-budget ()
  (let ((my-codex-flycheck-diagnostics-limit 100)
        (my-codex-diagnostics-token-budget 80)
        (diagnostics
         '((:line 1 :column 1 :level error :checker mock :message "short")
           (:line 2 :column 1 :level error :checker mock
            :message "this diagnostic has a much longer message")
           (:line 3 :column 1 :level error :checker mock :message "later"))))
    (my-codex-test--with-mock-flycheck diagnostics
      (cl-letf (((symbol-function 'my-codex-project-root)
                 (lambda () "/repo/")))
        (let ((prompt (my-codex--flycheck-diagnostics-prompt diagnostics)))
          (should (string-match-p "diagnostic_count: 3" prompt))
          (should (string-match-p "included_count: 1" prompt))
          (should (string-match-p "omitted_count: 2" prompt))
          (should (string-match-p "context_budget_tokens: 80" prompt))
          (should (string-match-p "truncated: true" prompt))
          (should (string-match-p "message: \"short\"" prompt))
          (should-not (string-match-p "much longer message" prompt))
          (should-not (string-match-p "message: \"later\"" prompt)))))))

(ert-deftest my-codex-flycheck-diagnostics-prompt-keeps-one-tight-budget ()
  (let ((my-codex-flycheck-diagnostics-limit 100)
        (my-codex-diagnostics-token-budget 1)
        (diagnostics
         '((:line 1 :column 1 :level error :checker mock
            :message "verbose diagnostic that exceeds the tiny budget")
           (:line 2 :column 1 :level error :checker mock
            :message "later"))))
    (my-codex-test--with-mock-flycheck diagnostics
      (cl-letf (((symbol-function 'my-codex-project-root)
                 (lambda () "/repo/")))
        (let ((prompt (my-codex--flycheck-diagnostics-prompt diagnostics)))
          (should (string-match-p "diagnostic_count: 2" prompt))
          (should (string-match-p "included_count: 1" prompt))
          (should (string-match-p "omitted_count: 1" prompt))
          (should (string-match-p
                   "message: \"verbose diagnostic that exceeds the tiny budget\""
                   prompt))
          (should-not (string-match-p "message: \"later\"" prompt)))))))

(ert-deftest my-codex-flycheck-diagnostics-prompt-caps-first-repeated-group ()
  (let ((my-codex-flycheck-diagnostics-limit 100)
        (my-codex-diagnostics-token-budget 10)
        (diagnostics
         '((:line 1 :column 1 :level error :checker mock :message "repeat")
           (:line 2 :column 1 :level error :checker mock :message "repeat")
           (:line 3 :column 1 :level error :checker mock :message "repeat"))))
    (my-codex-test--with-mock-flycheck diagnostics
      (cl-letf (((symbol-function 'my-codex-project-root)
                 (lambda () "/repo/"))
                ((symbol-function 'my-codex--approx-token-count)
                 (lambda (text)
                   (if (string-match-p "- line: 2" text) 99 1))))
        (let ((prompt (my-codex--flycheck-diagnostics-prompt diagnostics)))
          (should (string-match-p "diagnostic_count: 3" prompt))
          (should (string-match-p "included_count: 1" prompt))
          (should (string-match-p "omitted_count: 2" prompt))
          (should (string-match-p "message: \"repeat\"" prompt))
          (should (string-match-p "- line: 1" prompt))
          (should-not (string-match-p "- line: 2" prompt))
          (should-not (string-match-p "- line: 3" prompt)))))))

(ert-deftest my-codex-explain-buffer-diagnostics-sends-flycheck-prompt ()
  (let ((diagnostics
         '((:line 1
            :column 2
            :level error
            :checker mock-checker
            :message "broken")))
        sent)
    (my-codex-test--with-mock-flycheck diagnostics
      (cl-letf (((symbol-function 'my-codex-project-root)
                 (lambda () "/repo/"))
                ((symbol-function 'my-codex--preview-and-send-prompt)
                 (lambda (prompt) (setq sent prompt))))
        (my-codex-explain-buffer-diagnostics)
        (should sent)
        (should (string-match-p "source: Flycheck" sent))
        (should (string-match-p "message: \"broken\"" sent))))))

(ert-deftest my-codex-flymake-diagnostics-normalises-diagnostic ()
  (require 'flymake)
  (with-temp-buffer
    (insert "one\ntwo problem\nthree\n")
    (setq buffer-file-name "/repo/example.el")
    (let* ((flymake-mode t)
           (beg (save-excursion
                  (goto-char (point-min))
                  (forward-line 1)
                  (forward-char 4)
                  (point)))
           (diagnostic
            (flymake-make-diagnostic
             (current-buffer) beg (+ beg 7) :warning "problem")))
      (cl-letf (((symbol-function 'flymake-diagnostics)
                 (lambda (&rest _) (list diagnostic)))
                ((symbol-function 'flymake-diagnostic-backend)
                 (lambda (_diagnostic) 'mock-backend)))
        (let ((normalised (car (my-codex--flymake-diagnostics))))
          (should (equal (plist-get normalised :file) buffer-file-name))
          (should (= (plist-get normalised :line) 2))
          (should (= (plist-get normalised :column) 5))
          (should (= (plist-get normalised :end-column) 12))
          (should (eq (plist-get normalised :severity) 'warning))
          (should (equal (plist-get normalised :source) "mock-backend"))
          (should (equal (plist-get normalised :message) "problem")))))))

(ert-deftest my-codex-flymake-diagnostic-keeps-non-file-locus-selectable ()
  (require 'flymake)
  (with-temp-buffer
    (insert "problem\n")
    (let* ((diagnostic
            (flymake-make-diagnostic
             (current-buffer) 1 8 :error "problem"))
           (normalised
            (my-codex--normalise-flymake-diagnostic diagnostic)))
      (should-not (plist-get normalised :file))
      (goto-char 3)
      (should
       (eq normalised
           (my-codex--flycheck-diagnostic-at-point
            (list normalised)))))))

(ert-deftest my-codex-flymake-diagnostic-uses-live-overlay-bounds ()
  (require 'flymake)
  (with-temp-buffer
    (insert "old moved\n")
    (let* ((diagnostic
            (flymake-make-diagnostic
             (current-buffer) 1 4 :warning "moved"))
           (overlay (make-overlay 5 10)))
      (unwind-protect
          (cl-letf (((symbol-function 'flymake--diag-overlay)
                     (lambda (_diagnostic) overlay)))
            (let ((normalised
                   (my-codex--normalise-flymake-diagnostic diagnostic)))
              (should (= (plist-get normalised :column) 5))
              (should (= (plist-get normalised :end-column) 10))
              (goto-char 7)
              (should
               (eq normalised
                   (my-codex--flycheck-diagnostic-at-point
                    (list normalised))))))
        (delete-overlay overlay)))))

(ert-deftest my-codex-diagnostics-limit-preserves-obsolete-setting ()
  (let* ((script
          '(progn
             (setq my-codex-flycheck-diagnostics-limit 17)
             (require 'my-codex-diagnostics)
             (prin1 my-codex-diagnostics-limit)))
         (output
          (with-temp-buffer
            (let ((status
                   (call-process invocation-name nil t nil
                                 "--batch" "-Q" "-L" default-directory
                                 "--eval" (prin1-to-string script))))
              (unless (zerop status)
                (error "Nested Emacs failed: %s" (buffer-string)))
              (buffer-string)))))
    (should (equal output "17"))))

(ert-deftest my-codex-flymake-severity-honours-custom-types ()
  (require 'flymake)
  (let ((warning-type (make-symbol "custom-warning"))
        (error-type (make-symbol "custom-error")))
    (put warning-type 'flymake-category 'flymake-warning)
    (put error-type 'severity (warning-numeric-level :error))
    (should (eq (my-codex--flymake-severity warning-type) 'warning))
    (should (eq (my-codex--flymake-severity error-type) 'error))))

(ert-deftest my-codex-flymake-severity-honours-compatibility-alist ()
  (require 'flymake)
  (let* ((warning-type (make-symbol "configured-warning"))
         (note-type (make-symbol "configured-note"))
         (flymake-diagnostic-types-alist
          `((,warning-type
             (severity . ,(warning-numeric-level :warning)))
            (,note-type
             (flymake-category . flymake-note)))))
    (should (eq (my-codex--flymake-severity warning-type) 'warning))
    (should (eq (my-codex--flymake-severity note-type) 'note))))

(ert-deftest my-codex-diagnostic-at-point-prefers-overlapping-range ()
  (with-temp-buffer
    (insert "one\ntwo\nthree\n")
    (goto-char (point-min))
    (forward-line 1)
    (let ((diagnostics
           '((:line 2 :column 1 :message "nearest")
             (:line 1 :column 2 :end-line 3 :end-column 2
              :message "overlapping"))))
      (should
       (equal
        (plist-get
         (my-codex--flycheck-diagnostic-at-point diagnostics)
         :message)
        "overlapping")))))

(ert-deftest my-codex-diagnostic-at-point-excludes-range-end ()
  (with-temp-buffer
    (insert "abcdef\n")
    (goto-char (point-min))
    (forward-char 3)
    (let ((diagnostics
           '((:line 1 :column 1 :end-line 1 :end-column 4
              :message "previous")
             (:line 1 :column 4 :end-line 1 :end-column 7
              :message "current"))))
      (should
       (equal
        (plist-get
         (my-codex--flycheck-diagnostic-at-point diagnostics)
         :message)
        "current")))))

(ert-deftest my-codex-diagnostics-provider-auto-prefers-flycheck ()
  (let ((my-codex-diagnostics-provider 'auto))
    (cl-letf (((symbol-function 'my-codex--flycheck-available-p)
               (lambda () t))
              ((symbol-function 'my-codex--flymake-available-p)
               (lambda () t)))
      (should (eq (my-codex--active-diagnostics-provider) 'flycheck)))))

(ert-deftest my-codex-diagnostics-provider-auto-falls-back-to-flymake ()
  (let ((my-codex-diagnostics-provider 'auto))
    (cl-letf (((symbol-function 'my-codex--flycheck-available-p)
               (lambda () nil))
              ((symbol-function 'my-codex--flymake-available-p)
               (lambda () t)))
      (should (eq (my-codex--active-diagnostics-provider) 'flymake)))))

(ert-deftest my-codex-explain-buffer-diagnostics-sends-flymake-prompt ()
  (let ((my-codex-diagnostics-provider 'flymake)
        sent)
    (cl-letf (((symbol-function 'my-codex--flymake-available-p)
               (lambda () t))
              ((symbol-function 'my-codex--flymake-diagnostics)
               (lambda ()
                 '((:file "/repo/example.el"
                    :line 2 :column 3 :severity error
                    :source "mock-backend" :message "broken"))))
              ((symbol-function 'my-codex-project-root)
               (lambda () "/repo/"))
              ((symbol-function 'my-codex--preview-and-send-prompt)
               (lambda (prompt) (setq sent prompt))))
      (my-codex-explain-buffer-diagnostics)
      (should (string-match-p "Analyse these Flymake diagnostics" sent))
      (should (string-match-p "source: Flymake" sent))
      (should (string-match-p "checker: \"mock-backend\"" sent))
      (should (string-match-p "message: \"broken\"" sent)))))


(provide 'my-codex-diagnostics-test)

;;; my-codex-diagnostics-test.el ends here
