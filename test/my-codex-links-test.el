;;; my-codex-links-test.el --- Tests for my-codex-links -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Code:

(require 'ert)
(require 'my-codex-links)

(ert-deftest my-codex-session-links-linkifies-hard-wrapped-file-reference ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-links" t))))
    (unwind-protect
        (progn
          (make-directory
           (expand-file-name "docs/references" root)
           t)
          (write-region
           "" nil
           (expand-file-name
            "docs/references/closing-the-loop.md"
            root)
           nil 'silent)
          (with-temp-buffer
            (insert "docs/references/closing-the-\n     loop.md:19")
            (cl-letf (((symbol-function 'my-codex-project-root)
                       (lambda () root)))
              (my-codex-session-links-mode 1)
              (goto-char (point-min))
              (should
               (eq (get-text-property
                    (point)
                    'my-codex-session-link-type)
                   'file))
              (let ((target (get-text-property
                             (point)
                             'my-codex-session-link-target)))
                (should
                 (equal
                  target
                  '(:file "docs/references/closing-the-loop.md"
                    :line 19
                    :column nil
                    :end-line nil)))))))
      (delete-directory root t))))

(ert-deftest my-codex-session-links-linkifies-directory-boundary-wrapped-file-reference ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-links" t))))
    (unwind-protect
        (progn
          (make-directory
           (expand-file-name "docs/references" root)
           t)
          (write-region
           "" nil
           (expand-file-name
            "docs/references/closing-the-loop.md"
            root)
           nil 'silent)
          (with-temp-buffer
            (insert "docs/references/\n     closing-the-loop.md:19")
            (cl-letf (((symbol-function 'my-codex-project-root)
                       (lambda () root)))
              (my-codex-session-links-mode 1)
              (goto-char (point-min))
              (should
               (eq (get-text-property
                    (point)
                    'my-codex-session-link-type)
                   'file))
              (let ((target (get-text-property
                             (point)
                             'my-codex-session-link-target)))
                (should
                 (equal
                  target
                  '(:file "docs/references/closing-the-loop.md"
                    :line 19
                    :column nil
                    :end-line nil)))))))
      (delete-directory root t))))

(ert-deftest my-codex-session-links-linkifies-streamed-hard-wrapped-file-reference ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-links" t))))
    (unwind-protect
        (progn
          (make-directory
           (expand-file-name "docs/references" root)
           t)
          (write-region
           "" nil
           (expand-file-name
            "docs/references/closing-the-loop.md"
            root)
           nil 'silent)
          (with-temp-buffer
            (cl-letf (((symbol-function 'my-codex-project-root)
                       (lambda () root)))
              (my-codex-session-links-mode 1)
              (insert "docs/references/closing-the-\n")
              (insert "     loop.md:19")
              (goto-char (point-min))
              (should
               (eq (get-text-property
                    (point)
                    'my-codex-session-link-type)
                   'file))
              (let ((target (get-text-property
                             (point)
                             'my-codex-session-link-target)))
                (should
                 (equal
                  target
                  '(:file "docs/references/closing-the-loop.md"
                    :line 19
                    :column nil
                    :end-line nil)))))))
      (delete-directory root t))))

(ert-deftest my-codex-session-links-linkifies-wrapped-absolute-file-reference ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-links" t))))
    (unwind-protect
        (progn
          (make-directory
           (expand-file-name "src/examples/whichlang" root)
           t)
          (write-region
           "" nil
           (expand-file-name
            "src/examples/whichlang/make_dataset.h"
            root)
           nil 'silent)
          (with-temp-buffer
            (insert "  - [P2] Fix labels -- "
                    (expand-file-name "src/" root)
                    "\n    examples/whichlang/make_dataset.h:31-34")
            (cl-letf (((symbol-function 'my-codex-project-root)
                       (lambda () root)))
              (my-codex-session-links-mode 1)
              (goto-char (point-min))
              (search-forward "make_dataset.h")
              (should
               (eq (get-text-property
                    (point)
                    'my-codex-session-link-type)
                   'file))
              (let ((target (get-text-property
                             (point)
                             'my-codex-session-link-target)))
                (should
                 (equal
                  target
                  '(:file "src/examples/whichlang/make_dataset.h"
                    :line 31
                    :column nil
                    :end-line 34)))))))
      (delete-directory root t))))

(ert-deftest my-codex-session-links-use-session-root-for-file-references ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-links" t)))
        (other-root (file-name-as-directory
                     (make-temp-file "my-codex-links-other" t))))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "src/kernel" root) t)
          (write-region
           "" nil
           (expand-file-name "src/kernel/evolution_strategy.tcc" root)
           nil 'silent)
          (with-temp-buffer
            (let ((my-codex-session-project-root root))
              (insert "src/kernel/\n  evolution_strategy.tcc:211")
              (cl-letf (((symbol-function 'my-codex-project-root)
                         (lambda () other-root)))
                (my-codex-session-links-mode 1)
                (goto-char (point-min))
                (should
                 (eq (get-text-property
                      (point)
                      'my-codex-session-link-type)
                     'file))
                (should
                 (equal
                  (get-text-property
                   (point)
                   'my-codex-session-link-target)
                  '(:file "src/kernel/evolution_strategy.tcc"
                    :line 211
                    :column nil
                    :end-line nil)))))))
      (delete-directory root t)
      (delete-directory other-root t))))

(ert-deftest my-codex-session-links-linkifies-unvalidated-file-reference ()
  (with-temp-buffer
    (insert "src/kernel/evolution_strategy.tcc:211")
    (my-codex-session-links-mode 1)
    (goto-char (point-min))
    (should
     (eq (get-text-property (point) 'my-codex-session-link-type)
         'file))
    (should
     (equal
      (get-text-property (point) 'my-codex-session-link-target)
      '(:file "src/kernel/evolution_strategy.tcc"
        :line 211
        :column nil
        :end-line nil)))))


(provide 'my-codex-links-test)

;;; my-codex-links-test.el ends here
