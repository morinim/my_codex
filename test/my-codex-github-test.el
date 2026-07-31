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

(ert-deftest my-codex-github-issue-list-parses-tabulated-entries ()
  (with-temp-buffer
    (insert "[{\"number\":12,\"title\":\"Fix refresh\","
            "\"url\":\"https://example.test/issues/12\","
            "\"author\":{\"login\":\"octo\"},"
            "\"updatedAt\":\"2026-07-31T12:34:56Z\"}]")
    (let* ((issues (my-codex--github-parse-issue-list-buffer))
           (entry (my-codex--github-issue-list-entry (car issues))))
      (should
       (equal entry
              '(12 ["12" "Fix refresh" "octo" "2026-07-31"]))))))

(ert-deftest my-codex-github-issue-list-mode-provides-actions ()
  (with-temp-buffer
    (my-codex-github-issue-list-mode)
    (should (eq (lookup-key (current-local-map) (kbd "RET"))
                #'my-codex-github-view-issue))
    (should (eq (lookup-key (current-local-map) (kbd "b"))
                #'my-codex-github-browse-issue))
    (should (eq (lookup-key (current-local-map) (kbd "g"))
                #'revert-buffer))))

(ert-deftest my-codex-github-issue-list-sorts-numbers-numerically ()
  (should
   (my-codex--github-issue-number-less-p
    '(20 ["20" "Second" "octo" "2026-07-31"])
    '(100 ["100" "First" "octo" "2026-07-31"]))))

(ert-deftest my-codex-github-browse-issue-opens-row-url ()
  (with-temp-buffer
    (my-codex-github-issue-list-mode)
    (setq my-codex--github-issue-list-items
          '((12 . ((number . 12)
                   (url . "https://example.test/issues/12")))))
    (setq tabulated-list-entries '((12 ["12" "Fix" "octo" "2026-07-31"])))
    (tabulated-list-print)
    (goto-char (point-min))
    (let (opened)
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url &rest _) (setq opened url))))
        (my-codex-github-browse-issue)
        (should (equal opened "https://example.test/issues/12"))))))

(ert-deftest my-codex-github-view-issue-cancels-previous-view ()
  (let ((list-buffer (generate-new-buffer " *my-codex-issue-list-test*"))
        (processes '(first second))
        cancelled
        detail-buffer)
    (unwind-protect
        (with-current-buffer list-buffer
          (setq default-directory "/mock/project/")
          (cl-letf (((symbol-function 'my-codex--github-issue-at-point)
                     (lambda () '((number . 12))))
                    ((symbol-function 'pop-to-buffer) #'ignore)
                    ((symbol-function 'make-process)
                     (lambda (&rest args)
                       (setq detail-buffer (plist-get args :buffer))
                       (pop processes)))
                    ((symbol-function 'process-live-p)
                     (lambda (process) (eq process 'first)))
                    ((symbol-function 'delete-process)
                     (lambda (process) (setq cancelled process))))
            (my-codex-github-view-issue)
            (my-codex-github-view-issue)
            (should (eq cancelled 'first))
            (with-current-buffer detail-buffer
              (should (eq my-codex--github-issue-view-process 'second)))))
      (kill-buffer list-buffer)
      (when (buffer-live-p detail-buffer)
        (kill-buffer detail-buffer)))))

(ert-deftest my-codex-list-open-issues-requests-json ()
  (let ((buffer (get-buffer-create "*my-codex-issues-test*"))
        command target stdout stderr)
    (unwind-protect
        (cl-letf (((symbol-function 'executable-find) (lambda (_) "gh"))
                  ((symbol-function 'my-codex-project-root)
                   (lambda () default-directory))
                  ((symbol-function 'my-codex--github-buffer-name)
                   (lambda (&rest _) (buffer-name buffer)))
                  ((symbol-function 'pop-to-buffer) #'ignore)
                  ((symbol-function 'make-process)
                   (lambda (&rest args)
                     (setq command (plist-get args :command))
                     (setq stdout (plist-get args :buffer))
                     (setq stderr (plist-get args :stderr))
                     'mock-process))
                  ((symbol-function 'process-put)
                   (lambda (_process property value)
                     (when (eq property 'my-codex-target-buffer)
                       (setq target value)))))
          (my-codex-list-open-issues)
          (should (eq target buffer))
          (should (member "--json" command))
          (should (member "number,title,url,author,updatedAt" command))
          (should (buffer-live-p stdout))
          (should (buffer-live-p stderr))
          (should-not (eq stdout stderr))
          (with-current-buffer stdout
            (insert "[]")
            (should-not (my-codex--github-parse-issue-list-buffer)))
          (with-current-buffer stderr
            (insert "debug diagnostic"))
          (with-current-buffer stdout
            (should-not (my-codex--github-parse-issue-list-buffer)))
          (with-current-buffer buffer
            (should (derived-mode-p 'my-codex-github-issue-list-mode))))
      (dolist (temporary (list stdout stderr))
        (when (buffer-live-p temporary)
          (kill-buffer temporary)))
      (kill-buffer buffer))))


(provide 'my-codex-github-test)

;;; my-codex-github-test.el ends here
