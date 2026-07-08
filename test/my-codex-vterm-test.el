;;; my-codex-vterm-test.el --- Tests for my-codex-vterm -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Code:

(require 'ert)
(require 'my-codex-vterm)

(defvar vterm-copy-mode-hook)
(defvar vterm-max-scrollback)
(defvar vterm-mode-hook)

(ert-deftest my-codex-ensure-vterm-scrollback-raises-low-value-locally ()
  (let ((was-bound (boundp 'vterm-max-scrollback))
        (original-value (and (boundp 'vterm-max-scrollback)
                             (symbol-value 'vterm-max-scrollback)))
        (my-codex-vterm-min-scrollback 10000))
    (unwind-protect
        (progn
          (set 'vterm-max-scrollback 100)
          (with-temp-buffer
            (my-codex--ensure-vterm-scrollback)
            (should (equal vterm-max-scrollback 10000))
            (should (local-variable-p 'vterm-max-scrollback))))
      (if was-bound
          (set 'vterm-max-scrollback original-value)
        (makunbound 'vterm-max-scrollback)))))

(ert-deftest my-codex-ensure-vterm-scrollback-preserves-higher-value ()
  (let ((was-bound (boundp 'vterm-max-scrollback))
        (original-value (and (boundp 'vterm-max-scrollback)
                             (symbol-value 'vterm-max-scrollback)))
        (my-codex-vterm-min-scrollback 10000))
    (unwind-protect
        (progn
          (set 'vterm-max-scrollback 20000)
          (with-temp-buffer
            (my-codex--ensure-vterm-scrollback)
            (should (equal vterm-max-scrollback 20000))
            (should-not (local-variable-p 'vterm-max-scrollback))))
      (if was-bound
          (set 'vterm-max-scrollback original-value)
        (makunbound 'vterm-max-scrollback)))))

(ert-deftest my-codex-vterm-scrollback-floor-raises-low-value ()
  (let ((my-codex-vterm-min-scrollback 10000))
    (should (equal (my-codex--vterm-scrollback-floor 100) 10000))))

(ert-deftest my-codex-vterm-mode-with-scrollback-floor-binds-public-option ()
  (let ((my-codex-vterm-min-scrollback 10000)
        captured-scrollback)
    (cl-letf (((symbol-function 'require)
               (lambda (&rest _args) t))
              ((symbol-function 'vterm-mode)
               (lambda ()
                 (setq captured-scrollback vterm-max-scrollback))))
      (let ((vterm-max-scrollback 100))
        (my-codex--vterm-mode-with-scrollback-floor))
      (should (equal captured-scrollback 10000)))))

(ert-deftest my-codex-vterm-mode-with-scrollback-floor-overrides-dir-local ()
  (let ((my-codex-vterm-min-scrollback 10000)
        captured-scrollback)
    (cl-letf (((symbol-function 'require)
               (lambda (&rest _args) t))
              ((symbol-function 'vterm-mode)
               (lambda ()
                 (setq vterm-max-scrollback 100)
                 (run-hooks 'hack-local-variables-hook)
                 (setq captured-scrollback vterm-max-scrollback))))
      (let ((vterm-max-scrollback 1000)
            (hack-local-variables-hook nil))
        (my-codex--vterm-mode-with-scrollback-floor))
      (should (equal captured-scrollback 10000)))))

(ert-deftest my-codex-vterm-mode-reports-missing-vterm ()
  (cl-letf (((symbol-function 'require)
             (lambda (&rest _args) nil)))
    (should-error (my-codex--vterm-mode-with-scrollback-floor)
                  :type 'user-error)))

(ert-deftest my-codex-vterm-integration-does-not-mutate-vterm-keymaps ()
  (let* ((vterm-mode-map (make-sparse-keymap))
         (vterm-copy-mode-map (make-sparse-keymap))
         (vterm-mode-hook nil)
         (vterm-copy-mode-hook nil)
         (after-change-major-mode-hook nil)
         (my-codex--vterm-copy-mode-lighter :unset))
    (keymap-set vterm-mode-map "<f8>" #'ignore)
    (keymap-set vterm-copy-mode-map "<f8>" #'ignore)
    (my-codex--enable-vterm-integration)
    (keymap-set vterm-mode-map "<f8>" #'next-line)
    (keymap-set vterm-copy-mode-map "<f8>" #'previous-line)
    (my-codex--disable-vterm-integration)
    (should (eq (keymap-lookup vterm-mode-map "<f8>") #'next-line))
    (should (eq (keymap-lookup vterm-copy-mode-map "<f8>") #'previous-line))))

(ert-deftest my-codex-vterm-override-mode-provides-local-keys ()
  (let ((copy-map (make-sparse-keymap))
        (vterm-copy-mode t))
    (keymap-set copy-map "<f8>" #'ignore)
    (with-temp-buffer
      (let ((major-mode 'vterm-mode)
            (my-codex-session-id "test-session")
            (minor-mode-map-alist
             (cons (cons 'vterm-copy-mode copy-map) minor-mode-map-alist)))
        (unwind-protect
            (progn
              (my-codex--enable-vterm-buffer-integration)
              (should (bound-and-true-p my-codex-vterm-override-mode))
              (should (eq (key-binding (kbd "<f8>"))
                          #'my-codex-transient-preserve-selection))
              (should (eq (key-binding (kbd "S-<insert>"))
                          #'vterm-yank)))
          (my-codex--disable-vterm-buffer-integration))))))

(ert-deftest my-codex-vterm-integration-ignores-non-agent-vterms ()
  (with-temp-buffer
    (let ((major-mode 'vterm-mode)
          (company-mode t)
          (flyspell-mode t)
          (display-line-numbers-mode t)
          (vterm-copy-mode-hook nil))
      (my-codex--enable-vterm-buffer-integration)
      (should-not (bound-and-true-p my-codex-vterm-override-mode))
      (should company-mode)
      (should flyspell-mode)
      (should display-line-numbers-mode)
      (should-not (local-variable-p 'vterm-copy-mode-hook)))))

(ert-deftest my-codex-vterm-copy-mode-hook-is-buffer-local ()
  (let ((vterm-copy-mode-hook nil))
    (with-temp-buffer
      (let ((major-mode 'vterm-mode)
            (my-codex-session-id "test-session"))
        (my-codex--enable-vterm-buffer-integration)
        (should (local-variable-p 'vterm-copy-mode-hook))
        (should (memq #'my-codex--vterm-copy-mode-header-line
                      vterm-copy-mode-hook))))
    (should-not vterm-copy-mode-hook)))

(ert-deftest my-codex-does-not-prebind-vterm-shell ()
  (let* ((script '(progn
                    (setq load-prefer-newer t)
                    (package-initialize)
                    (require 'my-codex)
                    (require 'vterm)
                    (princ vterm-shell)))
         (output
          (with-temp-buffer
            (let ((exit-code
                   (call-process invocation-name nil t nil
                                 "--batch" "-Q" "-L" default-directory
                                 "--eval" (prin1-to-string script))))
              (unless (zerop exit-code)
                (error "Nested Emacs failed: %s" (buffer-string)))
              (buffer-string)))))
    (should (equal output shell-file-name))))


(provide 'my-codex-vterm-test)

;;; my-codex-vterm-test.el ends here
