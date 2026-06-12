;;; my-codex-test.el --- Tests for my-codex -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Code:

(require 'ert)
(require 'my-codex)

(ert-deftest my-codex-clean-commit-message-body-lines-fills-paragraphs ()
  (let ((my-codex-commit-message-fill-column 34))
    (should
     (equal
      (my-codex--clean-commit-message-body-lines
       '("" "  first body line with extra space"
         "second body line that wraps"
         "" "- list item that wraps with hanging indentation"
         "    preformatted line  "))
      '("" "first body line with extra space\nsecond body line that wraps"
        "" "- list item that wraps with\n  hanging indentation"
        "    preformatted line")))))

(ert-deftest my-codex-clean-commit-message-trims-and-fills ()
  (let ((my-codex-commit-message-fill-column 30))
    (should
     (equal
      (my-codex-clean-commit-message
       "  fix: trim message  \n\n  body text with extra spaces that wraps  \n")
      "fix: trim message\n\nbody text with extra spaces\nthat wraps"))))

(ert-deftest my-codex-parse-github-issue-draft-with-repository ()
  (should
   (equal
    (my-codex--parse-github-issue-draft
     "Repository: owner/repo\n\nTitle: Bug report\n\nBody:\nDetails here.\n")
    '(:repository "owner/repo" :title "Bug report" :body "Details here."))))

(ert-deftest my-codex-parse-github-issue-draft-without-repository ()
  (should
   (equal
    (my-codex--parse-github-issue-draft
     "Title: Feature request\n\nBody:\nAdd the thing.\n")
    '(:repository nil :title "Feature request" :body "Add the thing."))))

(ert-deftest my-codex-terminal-marker-regexp-allows-terminal-space ()
  (let ((regexp (my-codex--terminal-marker-regexp "END")))
    (should (string-match-p regexp "E \r\nN\tD"))
    (should-not (string-match-p regexp "ENX"))))

(ert-deftest my-codex-normalize-marked-output-removes-layout-indentation ()
  (should
   (equal
    (my-codex--normalize-marked-output "\r\n    first\n      second\n\n")
    "first\n  second")))

(ert-deftest my-codex-approx-token-count-rounds-up ()
  (should (= (my-codex--approx-token-count "") 0))
  (should (= (my-codex--approx-token-count "abcd") 1))
  (should (= (my-codex--approx-token-count "abcde") 2)))

(ert-deftest my-codex-check-prompt-size-allows-small-prompts ()
  (let ((my-codex-large-prompt-warning-chars 10)
        (my-codex-large-prompt-error-chars nil))
    (should-not (my-codex--check-prompt-size "small"))))

(ert-deftest my-codex-check-prompt-size-can-disable-warning ()
  (let ((my-codex-large-prompt-warning-chars nil)
        (my-codex-large-prompt-error-chars nil))
    (should-not (my-codex--check-prompt-size "this is large"))))

(ert-deftest my-codex-check-prompt-size-confirms-large-prompts ()
  (let ((my-codex-large-prompt-warning-chars 5)
        (my-codex-large-prompt-error-chars nil))
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (_prompt) t)))
      (should-not (my-codex--check-prompt-size "this is large")))))

(ert-deftest my-codex-check-prompt-size-cancels-large-prompts ()
  (let ((my-codex-large-prompt-warning-chars 5)
        (my-codex-large-prompt-error-chars nil))
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (_prompt) nil)))
      (should-error
       (my-codex--check-prompt-size "this is large")
       :type 'user-error))))

(ert-deftest my-codex-check-prompt-size-enforces-hard-limit ()
  (let ((my-codex-large-prompt-warning-chars nil)
        (my-codex-large-prompt-error-chars 5))
    (should-error
     (my-codex--check-prompt-size "this is large")
     :type 'user-error)))

(ert-deftest my-codex-doctor-command-executable-token-handles-shell-prefixes ()
  (should
   (equal
    (my-codex--doctor-command-executable-token
     "FOO=1 command -v env BAR=2 --unset BAZ codex exec")
    "codex")))

(ert-deftest my-codex-doctor-command-executable-token-returns-nil-for-blank ()
  (should-not (my-codex--doctor-command-executable-token "  ")))

(ert-deftest my-codex-project-tree-lines-renders-compact-tree ()
  (let ((my-codex-project-overview-tree-max-entries 2))
    (should
     (equal
      (my-codex--project-tree-lines
       '("README.md"
         "lisp/a.el"
         "lisp/b.el"
         "lisp/c.el"
         "test/my-codex-test.el"))
      '("README.md"
        "lisp/ (3 files)"
        "  a.el"
        "  b.el"
        "  ... (1 more entries)"
        "test/ (1 file)"
        "  my-codex-test.el")))))

(ert-deftest my-codex-xref-items-section-formats-relative-excerpts ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-xref" t))))
    (unwind-protect
        (with-temp-buffer
          (setq buffer-file-name (expand-file-name "src/example.el" root))
          (insert "(defun alpha ()\n"
                  "  (beta))\n"
                  "\n"
                  "(defun beta ()\n"
                  "  42)\n")
          (let* ((first-marker (copy-marker (point-min)))
                 (second-marker (copy-marker (point-max)))
                 (section
                  (my-codex--xref-items-section
                   "Definition context"
                   (list
                    (xref-make
                     "alpha"
                     (xref-make-buffer-location
                      (current-buffer)
                      (marker-position first-marker)))
                    (xref-make
                     "beta"
                     (xref-make-buffer-location
                      (current-buffer)
                      (marker-position second-marker))))
                   root
                   1
                   1)))
            (should (string-match-p "Definition context:" section))
            (should (string-match-p "src/example\\.el:1 -- alpha" section))
            (should (string-match-p "(defun alpha" section))
            (should-not (string-match-p " -- beta" section))))
      (delete-directory root t))))

(provide 'my-codex-test)

;;; my-codex-test.el ends here
