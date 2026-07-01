;;; my-codex-test.el --- Test suite entry point -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Code:

(add-to-list 'load-path
             (file-name-directory (or load-file-name buffer-file-name)))

(require 'my-codex-core-test)
(require 'my-codex-ui-test)
(require 'my-codex-vterm-test)
(require 'my-codex-git-test)
(require 'my-codex-github-test)
(require 'my-codex-prompts-test)
(require 'my-codex-links-test)
(require 'my-codex-doctor-test)
(require 'my-codex-diagnostics-test)

(provide 'my-codex-test)

;;; my-codex-test.el ends here
