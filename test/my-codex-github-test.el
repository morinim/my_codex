;;; my-codex-github-test.el --- Tests for my-codex-github -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Code:

(require 'ert)
(require 'my-codex-github)

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

(ert-deftest my-codex-dynamic-helper-buffer-names-support-active-agent ()
  (let* ((root "/mock/project")
         (my-codex-agent-profiles
          '((codex
             :label "Codex"
             :buffer-prefix "codex")
            (antigravity
             :label "Antigravity"
             :buffer-prefix "agy")))
         (my-codex--project-active-agents (make-hash-table :test #'equal)))
    (puthash (file-name-as-directory "/mock/project") 'antigravity
             my-codex--project-active-agents)
    (should
     (string-prefix-p "*Antigravity prompt preview:"
                      (my-codex--prompt-preview-buffer-name root)))
    (should
     (string-prefix-p "*Antigravity GitHub issue:"
                      (my-codex--github-buffer-name root 'issue)))
    (should
     (string-prefix-p "*Antigravity open issues:"
                      (my-codex--github-buffer-name root 'issue-list)))
    (should
     (string-prefix-p "*Antigravity GitHub issue draft:"
                      (my-codex--github-buffer-name root 'issue-draft)))))


(provide 'my-codex-github-test)

;;; my-codex-github-test.el ends here
