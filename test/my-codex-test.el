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

(ert-deftest my-codex-latest-marked-output-after-finds-output-after-marker ()
  (with-temp-buffer
    (insert "old output\n")
    (let ((start (copy-marker (point))))
      (insert "BEGIN_COMMIT_MESSAGE\n"
              "fix: extract latest commit message\n"
              "END_COMMIT_MESSAGE\n")
      (should
       (equal
        (my-codex-latest-commit-message-after (current-buffer) start)
        "fix: extract latest commit message")))))

(ert-deftest my-codex-latest-marked-output-after-ignores-before-marker ()
  (with-temp-buffer
    (insert "BEGIN_COMMIT_MESSAGE\n"
            "fix: stale message\n"
            "END_COMMIT_MESSAGE\n")
    (let ((start (copy-marker (point))))
      (insert "no generated output yet\n")
      (should-not
       (my-codex-latest-commit-message-after (current-buffer) start)))))

(ert-deftest my-codex-latest-marked-output-after-uses-latest-block ()
  (with-temp-buffer
    (let ((start (copy-marker (point))))
      (insert "BEGIN_COMMIT_MESSAGE\n"
              "fix: first message\n"
              "END_COMMIT_MESSAGE\n"
              "BEGIN_COMMIT_MESSAGE\n"
              "fix: latest message\n"
              "END_COMMIT_MESSAGE\n")
      (should
       (equal
        (my-codex-latest-commit-message-after (current-buffer) start)
        "fix: latest message")))))

(ert-deftest my-codex-latest-marked-output-after-ignores-placeholders ()
  (with-temp-buffer
    (let ((start (copy-marker (point))))
      (insert "BEGIN_COMMIT_MESSAGE\n"
              "...\n"
              "END_COMMIT_MESSAGE\n")
      (should-not
       (my-codex-latest-commit-message-after (current-buffer) start)))))

(ert-deftest my-codex-latest-marked-output-after-tolerates-terminal-spacing ()
  (with-temp-buffer
    (let ((start (copy-marker (point))))
      (insert "B \r\nE\tG I N_COMMIT_MESSAGE\n"
              "    fix: tolerate terminal spacing\r\n"
              "E \r\nN\tD_COMMIT_MESSAGE\n")
      (should
       (equal
        (my-codex-latest-commit-message-after (current-buffer) start)
        "fix: tolerate terminal spacing")))))

(ert-deftest my-codex-approx-token-count-rounds-up ()
  (should (= (my-codex--approx-token-count "") 0))
  (should (= (my-codex--approx-token-count "abcd") 1))
  (should (= (my-codex--approx-token-count "abcde") 2)))

(ert-deftest my-codex-session-access-mode-recognizes-default-commands ()
  (should
   (eq (my-codex--session-access-mode my-codex-read-only-command)
       'read-only))
  (should
   (eq (my-codex--session-access-mode my-codex-workspace-command)
       'workspace-write))
  (should
   (eq (my-codex--session-access-mode my-codex-resume-command)
       'resume))
  (should
   (eq (my-codex--session-access-mode "codex --custom")
       'custom)))

(ert-deftest my-codex-agent-command-resolves-symbol-backed-commands ()
  (let ((my-codex-read-only-command "codex-ro")
        (my-codex-workspace-command "codex-ww")
        (my-codex-resume-command "codex-resume")
        (my-codex-antigravity-read-only-command "agy-ro")
        (my-codex-antigravity-workspace-command "agy-ww")
        (my-codex-antigravity-resume-command "agy-resume"))
    (should
     (equal (my-codex--agent-command 'codex 'read-only)
            "codex-ro"))
    (should
     (equal (my-codex--agent-command 'codex 'workspace-write)
            "codex-ww"))
    (should
     (equal (my-codex--agent-command 'codex 'resume)
            "codex-resume"))
    (should
     (equal (my-codex--agent-command 'antigravity 'read-only)
            "agy-ro"))
    (should
     (equal (my-codex--agent-command 'antigravity 'workspace-write)
            "agy-ww"))
    (should
     (equal (my-codex--agent-command 'antigravity 'resume)
            "agy-resume"))))

(ert-deftest my-codex-agent-buffer-name-supports-mixed-agents ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-buffer" t))))
    (unwind-protect
        (let ((default-directory root)
              (my-codex-agent 'codex))
          (should
           (string-match-p
            (rx bos "*codex:" (+ anything) ":" (= 8 xdigit) "*")
            (my-codex-current-buffer-name)))
          (should
           (string-match-p
            (rx bos "*agy:" (+ anything) ":" (= 8 xdigit) "*")
            (my-codex-current-buffer-name 'antigravity))))
      (delete-directory root t))))

(ert-deftest my-codex-current-buffer-name-uses-project-active-agent ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-buffer" t))))
    (unwind-protect
        (let ((default-directory root)
              (my-codex-agent 'codex)
              (my-codex--project-active-agents
               (make-hash-table :test #'equal)))
          (cl-letf (((symbol-function 'project-current)
                     (lambda (&optional _maybe-prompt _directory)
                       nil)))
            (my-codex--set-active-agent 'antigravity root)
            (should
             (string-match-p
              (rx bos "*agy:" (+ anything) ":" (= 8 xdigit) "*")
              (my-codex-current-buffer-name)))))
      (delete-directory root t))))

(ert-deftest my-codex-buffer-resolves-project-active-agent-session ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-buffer" t)))
        buffer)
    (unwind-protect
        (let ((default-directory root)
              (my-codex-agent 'codex)
              (my-codex--project-active-agents
               (make-hash-table :test #'equal)))
          (cl-letf (((symbol-function 'project-current)
                     (lambda (&optional _maybe-prompt _directory)
                       nil))
                    ((symbol-function 'get-buffer-process)
                     (lambda (candidate)
                       (eq candidate buffer)))
                    ((symbol-function 'process-live-p)
                     (lambda (process) process)))
            (setq buffer
                  (get-buffer-create
                   (my-codex-current-buffer-name 'antigravity)))
            (my-codex--mark-default-session
             buffer root 'workspace-write 'antigravity)
            (my-codex--set-active-agent 'antigravity root)
            (should (eq (my-codex-buffer) buffer))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest my-codex-mark-default-session-sets-buffer-local-metadata ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-session" t))))
    (unwind-protect
        (with-temp-buffer
          (my-codex--mark-default-session
           (current-buffer) root 'workspace-write)
          (should (local-variable-p 'my-codex-session-id))
          (should
           (string-prefix-p "codex:default:" my-codex-session-id))
          (should (equal my-codex-session-name "default"))
          (should
           (equal my-codex-session-project-root
                  (file-name-as-directory (file-truename root))))
          (should (eq my-codex-session-access-mode 'workspace-write))
          (should (eq my-codex-session-agent 'codex)))
      (delete-directory root t))))

(ert-deftest my-codex-mark-named-session-sets-buffer-local-metadata ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-session" t))))
    (unwind-protect
        (with-temp-buffer
          (my-codex--mark-named-session
           (current-buffer) "plan" root 'read-only 'antigravity)
          (should (local-variable-p 'my-codex-session-id))
          (should
           (string-prefix-p "antigravity:session:" my-codex-session-id))
          (should (string-match-p ":plan-[[:xdigit:]]\\{8\\}\\'"
                                  my-codex-session-id))
          (should (equal my-codex-session-name "plan"))
          (should
           (equal my-codex-session-project-root
                  (file-name-as-directory (file-truename root))))
          (should (eq my-codex-session-access-mode 'read-only))
          (should (eq my-codex-session-agent 'antigravity)))
      (delete-directory root t))))

(ert-deftest my-codex-session-buffer-name-appends-safe-session-name ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-buffer" t))))
    (unwind-protect
        (let ((default-directory root))
          (should
           (string-match-p
            (rx bos "*codex:" (+ anything)
                ":review!docs-" (= 8 xdigit) "*")
            (my-codex-session-buffer-name "review docs"))))
      (delete-directory root t))))

(ert-deftest my-codex-session-buffer-name-includes-agent-prefix ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-buffer" t))))
    (unwind-protect
        (let ((default-directory root))
          (should
           (string-match-p
            (rx bos "*agy:" (+ anything)
                ":review!docs-" (= 8 xdigit) "*")
            (my-codex-session-buffer-name "review docs" 'antigravity))))
      (delete-directory root t))))

(ert-deftest my-codex-safe-session-name-preserves-distinct-names ()
  (let ((names '("review docs" "review:docs" "review!docs")))
    (should
     (equal (length (delete-dups
                     (mapcar #'my-codex--safe-session-name names)))
            (length names)))))

(ert-deftest my-codex-session-buffers-returns-open-session-buffers ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-sessions" t)))
        (default-buffer (get-buffer-create "*codex-sessions-default*"))
        (named-buffer (get-buffer-create "*codex-sessions-named*"))
        (old-buffer (get-buffer-create "*codex-sessions-named*<old>"))
        (other-buffer (get-buffer-create "*codex-sessions-other*")))
    (unwind-protect
        (progn
          (my-codex--mark-default-session
           default-buffer root 'workspace-write)
          (my-codex--mark-named-session
           named-buffer "plan" root 'read-only)
          (my-codex--mark-named-session
           old-buffer "plan" root 'read-only)
          (with-current-buffer other-buffer
            (setq-local my-codex-session-name "not a session"))
          (cl-letf (((symbol-function 'get-buffer-process)
                     (lambda (buffer)
                       (memq buffer (list default-buffer named-buffer))))
                    ((symbol-function 'process-live-p)
                     (lambda (process) process)))
            (should
             (equal (mapcar #'buffer-name (my-codex--session-buffers))
                    '("*codex-sessions-default*"
                      "*codex-sessions-named*")))))
      (delete-directory root t)
      (mapc (lambda (buffer)
              (when (buffer-live-p buffer)
                (kill-buffer buffer)))
            (list default-buffer named-buffer old-buffer other-buffer)))))

(ert-deftest my-codex-list-sessions-renders-session-buffer ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-sessions" t)))
        (session-buffer (get-buffer-create "*codex-sessions-render*")))
    (unwind-protect
        (progn
          (my-codex--mark-named-session
           session-buffer "plan" root 'read-only)
          (cl-letf (((symbol-function 'get-buffer-process)
                     (lambda (buffer)
                       (eq buffer session-buffer)))
                    ((symbol-function 'process-live-p)
                     (lambda (process) process))
                    ((symbol-function 'pop-to-buffer) #'ignore))
            (my-codex-list-sessions))
          (with-current-buffer my-codex-sessions-buffer-name
            (should (derived-mode-p 'my-codex-sessions-mode))
            (should (string-match-p "\\*codex-sessions-render\\*"
                                    (buffer-string)))
            (should (string-match-p "codex" (buffer-string)))
            (should (string-match-p "plan" (buffer-string)))
            (should (string-match-p "read-only" (buffer-string)))))
      (delete-directory root t)
      (when (buffer-live-p session-buffer)
        (kill-buffer session-buffer))
      (when-let ((buffer (get-buffer my-codex-sessions-buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest my-codex-sessions-visit-switches-session-window ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-sessions" t)))
        (old-buffer (get-buffer-create "*codex-sessions-old*"))
        (session-buffer (get-buffer-create "*codex-sessions-select*"))
        term-window)
    (unwind-protect
        (let ((edit-window (selected-window)))
          (setq term-window (split-window-right))
          (set-window-buffer term-window old-buffer)
          (set-window-parameter
           edit-window 'my-codex-term-buffer old-buffer)
          (my-codex--mark-named-session
           old-buffer "old" root 'workspace-write)
          (my-codex--mark-named-session
           session-buffer "plan" root 'read-only)
          (cl-letf (((symbol-function 'get-buffer-process)
                     (lambda (buffer)
                       (memq buffer (list old-buffer session-buffer))))
                    ((symbol-function 'process-live-p)
                     (lambda (process) process))
                    ((symbol-function 'pop-to-buffer)
                     (lambda (buffer-or-name &rest _args)
                       (set-window-buffer
                        (selected-window)
                        (get-buffer buffer-or-name))
                       (selected-window))))
            (my-codex-list-sessions)
            (with-current-buffer my-codex-sessions-buffer-name
              (goto-char (point-min))
              (search-forward "*codex-sessions-select*")
              (beginning-of-line)
              (my-codex-sessions-visit))
            (should (eq (window-buffer term-window) session-buffer))
            (should (eq (selected-window) term-window))
            (should
             (eq (window-parameter edit-window 'my-codex-term-buffer)
                 session-buffer))))
      (delete-directory root t)
      (when (window-live-p term-window)
        (delete-window term-window))
      (when (buffer-live-p old-buffer)
        (kill-buffer old-buffer))
      (when (buffer-live-p session-buffer)
        (kill-buffer session-buffer))
      (when-let ((buffer (get-buffer my-codex-sessions-buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest my-codex-sessions-visit-from-terminal-updates-edit-window ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-sessions" t)))
        (old-buffer (get-buffer-create "*codex-sessions-terminal-old*"))
        (session-buffer (get-buffer-create "*codex-sessions-terminal-new*"))
        term-window)
    (unwind-protect
        (let ((edit-window (selected-window)))
          (setq term-window (split-window-right))
          (set-window-buffer term-window old-buffer)
          (set-window-parameter
           edit-window 'my-codex-term-buffer old-buffer)
          (my-codex--mark-named-session
           old-buffer "old" root 'workspace-write)
          (my-codex--mark-named-session
           session-buffer "plan" root 'read-only)
          (select-window term-window)
          (cl-letf (((symbol-function 'get-buffer-process)
                     (lambda (buffer)
                       (memq buffer (list old-buffer session-buffer))))
                    ((symbol-function 'process-live-p)
                     (lambda (process) process))
                    ((symbol-function 'pop-to-buffer) #'ignore))
            (my-codex-list-sessions)
            (with-current-buffer my-codex-sessions-buffer-name
              (goto-char (point-min))
              (search-forward "*codex-sessions-terminal-new*")
              (beginning-of-line)
              (my-codex-sessions-visit))
            (should (eq (window-buffer term-window) session-buffer))
            (should
             (eq (window-parameter edit-window 'my-codex-term-buffer)
                 session-buffer))
            (should-not
             (eq (window-parameter term-window 'my-codex-term-buffer)
                 session-buffer))))
      (delete-directory root t)
      (when (window-live-p term-window)
        (delete-window term-window))
      (when (buffer-live-p old-buffer)
        (kill-buffer old-buffer))
      (when (buffer-live-p session-buffer)
        (kill-buffer session-buffer))
      (when-let ((buffer (get-buffer my-codex-sessions-buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest my-codex-default-session-commands-use-selected-agent ()
  (let (called)
    (cl-letf (((symbol-function 'my-codex-two-column-layout-with-command)
               (lambda (command focus-term session-name agent access-mode)
                 (setq called
                       (list command focus-term session-name
                             agent access-mode)))))
      (my-codex-default-read-only 'antigravity)
      (should
       (equal called
              (list my-codex-antigravity-read-only-command
                    nil nil 'antigravity 'read-only))))
    (cl-letf (((symbol-function 'my-codex-two-column-layout-with-command)
               (lambda (command focus-term session-name agent access-mode)
                 (setq called
                       (list command focus-term session-name
                             agent access-mode)))))
      (my-codex-default-workspace 'antigravity)
      (should
       (equal called
              (list my-codex-antigravity-workspace-command
                    nil nil 'antigravity 'workspace-write))))))

(ert-deftest my-codex-default-session-layout-records-active-agent ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-active" t))))
    (unwind-protect
        (let ((default-directory root)
              (my-codex-agent 'codex)
              (my-codex--backends (make-hash-table :test #'equal))
              (my-codex--project-active-agents
               (make-hash-table :test #'equal)))
          (cl-letf (((symbol-function 'my-codex--fit-frame-to-right-layout)
                     #'ignore)
                    ((symbol-function 'my-codex--apply-display-window-width)
                     #'ignore)
                    ((symbol-function 'my-codex--resize-edit-window-for-right-layout)
                     #'ignore)
                    ((symbol-function 'my-codex--enable-edit-fill-column-indicator)
                     #'ignore)
                    ((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'my-codex-backend-start)
                     (lambda (&rest _args) nil))
                    ((symbol-function 'display-buffer)
                     (lambda (buf &rest _args)
                       (set-window-buffer (selected-window) buf)
                       (selected-window))))
            (my-codex-default-workspace 'antigravity)
            (should (eq (my-codex--active-agent root) 'antigravity))
            (should
             (string-match-p
              "\\`\\*agy:"
              (my-codex-current-buffer-name)))))
      (delete-directory root t))))

(ert-deftest my-codex-named-session-layout-starts-session-buffer ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-named" t)))
        started)
    (unwind-protect
        (let ((default-directory root)
              (my-codex--backends (make-hash-table :test #'equal)))
          (cl-letf (((symbol-function 'my-codex--fit-frame-to-right-layout)
                     #'ignore)
                    ((symbol-function 'my-codex--apply-display-window-width)
                     #'ignore)
                    ((symbol-function 'my-codex--resize-edit-window-for-right-layout)
                     #'ignore)
                    ((symbol-function 'my-codex--enable-edit-fill-column-indicator)
                     #'ignore)
                    ((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'my-codex-backend-start)
                     (lambda (backend project-root command
                              &optional session-name agent access-mode)
                       (setq started
                             (list
                              (my-codex--backend-buffer-name backend)
                              project-root command session-name
                              agent access-mode))))
                    ((symbol-function 'display-buffer)
                     (lambda (buf &rest _args)
                       (set-window-buffer (selected-window) buf)
                       (selected-window))))
            (my-codex-two-column-layout-with-command
             my-codex-read-only-command nil "plan")
            (should (equal (nth 1 started) root))
            (should (equal (nth 2 started) my-codex-read-only-command))
            (should (equal (nth 3 started) "plan"))
            (should (eq (nth 4 started) 'codex))
            (should-not (nth 5 started))
            (should
             (string-match-p ":plan-[[:xdigit:]]\\{8\\}\\*\\'"
                             (car started)))))
      (delete-directory root t))))

(ert-deftest my-codex-named-session-layout-starts-selected-agent-buffer ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-named" t)))
        started)
    (unwind-protect
        (let ((default-directory root)
              (my-codex--backends (make-hash-table :test #'equal)))
          (cl-letf (((symbol-function 'my-codex--fit-frame-to-right-layout)
                     #'ignore)
                    ((symbol-function 'my-codex--apply-display-window-width)
                     #'ignore)
                    ((symbol-function 'my-codex--resize-edit-window-for-right-layout)
                     #'ignore)
                    ((symbol-function 'my-codex--enable-edit-fill-column-indicator)
                     #'ignore)
                    ((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'my-codex-backend-start)
                     (lambda (backend project-root command
                              &optional session-name agent access-mode)
                       (setq started
                             (list
                              (my-codex--backend-buffer-name backend)
                              project-root command session-name
                              agent access-mode))))
                    ((symbol-function 'display-buffer)
                     (lambda (buf &rest _args)
                       (set-window-buffer (selected-window) buf)
                       (selected-window))))
            (my-codex-new-session "plan" 'antigravity 'workspace-write)
            (should (equal (nth 1 started) root))
            (should (equal (nth 2 started) "agy"))
            (should (equal (nth 3 started) "plan"))
            (should (eq (nth 4 started) 'antigravity))
            (should (eq (nth 5 started) 'workspace-write))
            (should
             (string-match-p "\\`\\*agy:.*:plan-[[:xdigit:]]\\{8\\}\\*\\'"
                             (car started)))))
      (delete-directory root t))))

(ert-deftest my-codex-restore-session-layout-hides-associated-session ()
  (let ((default-buffer (get-buffer-create "*codex-default-test*"))
        (session-buffer (get-buffer-create "*codex-session-test*"))
        term-window
        hidden)
    (unwind-protect
        (let ((edit-window (selected-window)))
          (setq term-window (split-window-right))
          (set-window-buffer term-window session-buffer)
          (set-window-parameter
           edit-window 'my-codex-term-buffer session-buffer)
          (select-window edit-window)
          (cl-letf (((symbol-function 'my-codex-current-buffer-name)
                     (lambda () (buffer-name default-buffer)))
                    ((symbol-function 'quit-window)
                     (lambda (&optional _kill window)
                       (setq hidden (window-buffer window)))))
            (my-codex-restore-session-layout)
            (should (eq hidden session-buffer))))
      (set-window-parameter
       (selected-window) 'my-codex-term-buffer nil)
      (when (window-live-p term-window)
        (delete-window term-window))
      (kill-buffer default-buffer)
      (kill-buffer session-buffer))))

(ert-deftest my-codex-reused-live-buffer-preserves-session-metadata ()
  (let ((root-a (file-name-as-directory (make-temp-file "my-codex-a" t)))
        (root-b (file-name-as-directory (make-temp-file "my-codex-b" t)))
        (buffer-name "*codex-shared-test*"))
    (unwind-protect
        (let ((buffer (get-buffer-create buffer-name))
              (my-codex-buffer-name buffer-name)
              (my-codex--backend nil))
          (my-codex--mark-default-session buffer root-a 'read-only)
          (let ((expected-id (with-current-buffer buffer my-codex-session-id))
                (expected-root
                 (with-current-buffer buffer my-codex-session-project-root)))
            (let ((default-directory root-b))
              (cl-letf (((symbol-function 'my-codex--fit-frame-to-right-layout)
                         #'ignore)
                        ((symbol-function 'my-codex--apply-display-window-width)
                         #'ignore)
                        ((symbol-function 'my-codex--resize-edit-window-for-right-layout)
                         #'ignore)
                        ((symbol-function 'my-codex--enable-edit-fill-column-indicator)
                         #'ignore)
                        ((symbol-function 'my-codex-project-root)
                         (lambda () root-b))
                        ((symbol-function 'my-codex-current-buffer-name)
                         (lambda (&optional _agent) buffer-name))
                        ((symbol-function 'my-codex-backend-live-p)
                         (lambda (_backend) t))
                        ((symbol-function 'my-codex-backend-start)
                         (lambda (&rest _args)
                           (error "Should not restart a live buffer")))
                        ((symbol-function 'display-buffer)
                         (lambda (buf &rest _args)
                           (set-window-buffer (selected-window) buf)
                           (selected-window))))
                (my-codex-two-column-layout-with-command
                 my-codex-workspace-command)))
            (with-current-buffer buffer
              (should (equal my-codex-session-id expected-id))
              (should (equal my-codex-session-project-root expected-root))
              (should (eq my-codex-session-access-mode 'read-only)))))
      (when-let ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer))
      (delete-directory root-a t)
      (delete-directory root-b t))))

(defmacro my-codex-test-with-vterm-shell (shell &rest body)
  "Bind `vterm-shell' to SHELL while running BODY."
  (declare (indent 1))
  `(let ((was-bound (boundp 'vterm-shell))
         (original-value (and (boundp 'vterm-shell)
                              (symbol-value 'vterm-shell))))
     (unwind-protect
         (progn
           (set 'vterm-shell ,shell)
           ,@body)
       (if was-bound
           (set 'vterm-shell original-value)
         (makunbound 'vterm-shell)))))

(ert-deftest my-codex-shell-command-and-exit-uses-posix-status ()
  (my-codex-test-with-vterm-shell "/bin/bash"
    (should
     (equal
      (my-codex--shell-command-and-exit "codex")
      "codex\nstatus=$?\nexit $status"))))

(ert-deftest my-codex-shell-command-and-exit-uses-cmd-errorlevel ()
  (my-codex-test-with-vterm-shell "C:\\Windows\\System32\\cmd.exe"
    (should
     (equal
      (my-codex--shell-command-and-exit "codex")
      "codex\nexit %ERRORLEVEL%"))))

(ert-deftest my-codex-shell-command-and-exit-uses-powershell-status ()
  (my-codex-test-with-vterm-shell "C:\\Program Files\\PowerShell\\7\\pwsh.exe"
    (should
     (equal
      (my-codex--shell-command-and-exit "codex")
      (concat "codex\n"
              "if ($LASTEXITCODE -ne $null) { exit $LASTEXITCODE }\n"
              "if ($?) { exit 0 } else { exit 1 }")))))

(ert-deftest my-codex-does-not-prebind-vterm-shell ()
  (let* ((script '(progn
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

(ert-deftest my-codex-git-autoload-command-loads-main-package ()
  (let* ((script '(progn
                    (require 'my-codex-git)
                    (condition-case err
                        (my-codex-send-git-diff)
                      (error (princ (format "%S\n" err))))
                    (princ (if (featurep 'my-codex)
                               "feature-loaded"
                             "feature-missing"))))
         (output
          (with-temp-buffer
            (let ((exit-code
                   (call-process invocation-name nil t nil
                                 "--batch" "-Q" "-L" default-directory
                                 "--eval" (prin1-to-string script))))
              (unless (zerop exit-code)
                (error "Nested Emacs failed: %s" (buffer-string)))
              (buffer-string)))))
    (should (string-match-p "feature-loaded" output))
    (should-not (string-match-p "void-variable" output))))

(defun my-codex-test--init-git-repository ()
  "Initialize a Git repository in `default-directory'."
  (unless (executable-find "git")
    (ert-skip "Git executable missing"))
  (should (eq 0 (process-file "git" nil nil nil "init" "-q"))))

(defun my-codex-test--write-file (file text)
  "Write TEXT to FILE under `default-directory'."
  (with-temp-file (expand-file-name file default-directory)
    (insert text)))

(ert-deftest my-codex-show-git-diff-populates-diff-mode-buffer ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-diff" t))))
    (let ((default-directory root))
      (my-codex-test--init-git-repository)
      (my-codex-test--write-file "tracked.txt" "old\n")
      (should (eq 0 (process-file "git" nil nil nil "add" "--" "tracked.txt")))
      (my-codex-test--write-file "tracked.txt" "new\n")
      (let ((buffer-name (my-codex--git-diff-buffer-name root nil)))
        (unwind-protect
            (cl-letf (((symbol-function 'my-codex-project-root)
                       (lambda () root))
                      ((symbol-function 'display-buffer)
                       (lambda (buffer &rest _args) buffer)))
              (my-codex-show-git-diff)
              (with-current-buffer buffer-name
                (should (derived-mode-p 'diff-mode))
                (should buffer-read-only)
                (should (equal default-directory root))
                (should (string-match-p "^-old" (buffer-string)))
                (should (string-match-p "^\\+new" (buffer-string)))))
          (when-let ((buffer (get-buffer buffer-name)))
            (kill-buffer buffer)))))))

(ert-deftest my-codex-show-git-staged-diff-populates-diff-mode-buffer ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-diff" t))))
    (let ((default-directory root))
      (my-codex-test--init-git-repository)
      (my-codex-test--write-file "staged.txt" "staged\n")
      (should (eq 0 (process-file "git" nil nil nil "add" "--" "staged.txt")))
      (let ((buffer-name (my-codex--git-diff-buffer-name root t)))
        (unwind-protect
            (cl-letf (((symbol-function 'my-codex-project-root)
                       (lambda () root))
                      ((symbol-function 'display-buffer)
                       (lambda (buffer &rest _args) buffer)))
              (my-codex-show-git-staged-diff)
              (with-current-buffer buffer-name
                (should (derived-mode-p 'diff-mode))
                (should buffer-read-only)
                (should (equal default-directory root))
                (should (string-match-p "^\\+staged" (buffer-string)))))
          (when-let ((buffer (get-buffer buffer-name)))
            (kill-buffer buffer)))))))

(ert-deftest my-codex-prompt-preset-transient-suffixes-empty-keeps-chooser ()
  (let* ((my-codex-prompt-presets nil)
         (suffixes (my-codex--prompt-preset-transient-suffixes nil))
         (choose-suffix (cadr suffixes))
         (properties (nth 2 choose-suffix)))
    (should (equal (car suffixes) ""))
    (should
     (equal (plist-get properties :description)
            "Choose by name"))
    (should (eq (plist-get properties :command)
                'my-codex-ask-with-preset))
    (should-not
     (seq-some (lambda (suffix)
                 (and (consp suffix)
                      (eq (plist-get (nth 2 suffix) :command) 'ignore)))
               suffixes))))

(ert-deftest my-codex-display-buffer-action-alist-returns-action-alist ()
  (let ((my-codex-display-buffer-action
         '((display-buffer-in-side-window)
           (side . right)
           (window-width . 80))))
    (should
     (equal (my-codex--display-buffer-action-alist)
            '((side . right)
              (window-width . 80))))))

(ert-deftest my-codex-display-buffer-action-alist-handles-functions ()
  (let ((my-codex-display-buffer-action #'display-buffer-same-window))
    (should-not (my-codex--display-buffer-action-alist))
    (should-not (my-codex--right-side-action-p))))

(ert-deftest my-codex-display-buffer-action-alist-handles-symbols ()
  (let ((my-codex-display-buffer-action 'display-buffer-same-window))
    (should-not (my-codex--display-buffer-action-alist))
    (should-not (my-codex--right-side-action-p))))

(ert-deftest my-codex-prompt-preview-header-shows-initial-size ()
  (should
   (equal
    (my-codex--prompt-preview-header "abcde")
    (concat "Initial size: 5 chars, approx. 2 tokens. Edit if needed; "
            "C-c C-c sends to Codex, C-c C-k cancels."))))

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

(ert-deftest my-codex-region-file-reference-formats-relative-lines ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-region" t))))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "src/example.el" root))
          (insert "first\nsecond\nthird\n")
          (set-buffer-modified-p nil)
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'verify-visited-file-modtime)
                     (lambda (_buffer) t)))
            (should
             (equal
              (my-codex--region-file-reference (point-min) (point-max))
              "@src/example.el lines 1-3"))))
      (delete-directory root t))))

(ert-deftest my-codex-region-file-reference-rejects-unsaved-files ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-region" t))))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "src/example.el" root))
          (insert "first\nsecond\nthird\n")
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root)))
            (should-error
             (my-codex--region-file-reference (point-min) (point-max))
             :type 'user-error)))
      (delete-directory root t))))

(ert-deftest my-codex-region-file-reference-rejects-stale-files ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-region" t))))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "src/example.el" root))
          (insert "first\nsecond\nthird\n")
          (set-buffer-modified-p nil)
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'verify-visited-file-modtime)
                     (lambda (_buffer) nil)))
            (should-error
             (my-codex--region-file-reference (point-min) (point-max))
             :type 'user-error)))
      (delete-directory root t))))

(ert-deftest my-codex-region-file-reference-rejects-outside-project-files ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-region" t)))
        (outside-root (file-name-as-directory
                       (make-temp-file "my-codex-outside" t))))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "example.el" outside-root))
          (insert "first\nsecond\nthird\n")
          (set-buffer-modified-p nil)
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'verify-visited-file-modtime)
                     (lambda (_buffer) t)))
            (should-error
             (my-codex--region-file-reference (point-min) (point-max))
             :type 'user-error)))
      (delete-directory root t)
      (delete-directory outside-root t))))

(ert-deftest my-codex-region-review-prompt-pastes-small-regions ()
  (let ((my-codex-region-reference-threshold-chars 100))
    (with-temp-buffer
      (insert "small region")
      (let ((prompt (my-codex--region-review-prompt
                     (point-min)
                     (point-max))))
        (should (string-match-p "small region" prompt))
        (should-not (string-match-p "@.* lines " prompt))))))

(ert-deftest my-codex-region-review-prompt-references-large-file-regions ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-region" t)))
        (my-codex-region-reference-threshold-chars 5))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "src/example.el" root))
          (insert "first\nsecond\nthird\n")
          (set-buffer-modified-p nil)
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'verify-visited-file-modtime)
                     (lambda (_buffer) t)))
            (let ((prompt (my-codex--region-review-prompt
                           (point-min)
                           (point-max))))
              (should (string-match-p "@src/example\\.el lines 1-3" prompt))
              (should-not (string-match-p "first\nsecond\nthird" prompt)))))
      (delete-directory root t))))

(ert-deftest my-codex-region-review-prompt-pastes-stale-file-regions ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-region" t)))
        (my-codex-region-reference-threshold-chars 5))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "src/example.el" root))
          (insert "first\nsecond\nthird\n")
          (set-buffer-modified-p nil)
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'verify-visited-file-modtime)
                     (lambda (_buffer) nil)))
            (let ((prompt (my-codex--region-review-prompt
                           (point-min)
                           (point-max))))
              (should (string-match-p "first\nsecond\nthird" prompt))
              (should-not
               (string-match-p "@src/example\\.el lines 1-3" prompt)))))
      (delete-directory root t))))

(ert-deftest my-codex-region-review-prompt-pastes-unsaved-file-regions ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-region" t)))
        (my-codex-region-reference-threshold-chars 5))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "src/example.el" root))
          (insert "first\nsecond\nthird\n")
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root)))
            (let ((prompt (my-codex--region-review-prompt
                           (point-min)
                           (point-max))))
              (should (string-match-p "first\nsecond\nthird" prompt))
              (should-not
               (string-match-p "@src/example\\.el lines 1-3" prompt)))))
      (delete-directory root t))))

(ert-deftest my-codex-region-review-prompt-pastes-unnamed-large-regions ()
  (let ((my-codex-region-reference-threshold-chars 5))
    (with-temp-buffer
      (insert "first\nsecond\nthird\n")
      (let ((prompt (my-codex--region-review-prompt
                     (point-min)
                     (point-max))))
        (should (string-match-p "first\nsecond\nthird" prompt))
        (should-not (string-match-p "@.* lines " prompt))))))

(ert-deftest my-codex-region-review-prompt-pastes-outside-project-regions ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-region" t)))
        (outside-root (file-name-as-directory
                       (make-temp-file "my-codex-outside" t)))
        (my-codex-region-reference-threshold-chars 5))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "example.el" outside-root))
          (insert "first\nsecond\nthird\n")
          (set-buffer-modified-p nil)
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'verify-visited-file-modtime)
                     (lambda (_buffer) t)))
            (let ((prompt (my-codex--region-review-prompt
                           (point-min)
                           (point-max))))
              (should (string-match-p "first\nsecond\nthird" prompt))
              (should-not (string-match-p "@.* lines " prompt)))))
      (delete-directory root t)
      (delete-directory outside-root t))))

(ert-deftest my-codex-region-prompt-context-references-large-file-regions ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-region" t)))
        (my-codex-region-reference-threshold-chars 5))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "src/example.el" root))
          (insert "first\nsecond\nthird\n")
          (set-buffer-modified-p nil)
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'verify-visited-file-modtime)
                     (lambda (_buffer) t)))
            (let ((context (my-codex--region-prompt-context
                            (point-min)
                            (point-max))))
              (should (string-match-p "@src/example\\.el lines 1-3" context))
              (should-not (string-match-p "first\nsecond\nthird" context)))))
      (delete-directory root t))))

(ert-deftest my-codex-region-prompt-context-pastes-stale-file-regions ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-region" t)))
        (my-codex-region-reference-threshold-chars 5))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "src/example.el" root))
          (insert "first\nsecond\nthird\n")
          (set-buffer-modified-p nil)
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'verify-visited-file-modtime)
                     (lambda (_buffer) nil)))
            (let ((context (my-codex--region-prompt-context
                            (point-min)
                            (point-max))))
              (should (string-match-p "first\nsecond\nthird" context))
              (should-not
               (string-match-p "@src/example\\.el lines 1-3" context)))))
      (delete-directory root t))))

(ert-deftest my-codex-region-prompt-context-pastes-unsaved-file-regions ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-region" t)))
        (my-codex-region-reference-threshold-chars 5))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "src/example.el" root))
          (insert "first\nsecond\nthird\n")
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root)))
            (let ((context (my-codex--region-prompt-context
                            (point-min)
                            (point-max))))
              (should (string-match-p "first\nsecond\nthird" context))
              (should-not
               (string-match-p "@src/example\\.el lines 1-3" context)))))
      (delete-directory root t))))

(ert-deftest my-codex-region-prompt-context-pastes-unnamed-regions ()
  (let ((my-codex-region-reference-threshold-chars 5))
    (with-temp-buffer
      (insert "first\nsecond\nthird\n")
      (let ((context (my-codex--region-prompt-context
                      (point-min)
                      (point-max))))
        (should (string-match-p "first\nsecond\nthird" context))
        (should-not (string-match-p "@.* lines " context))))))

(ert-deftest my-codex-region-prompt-context-pastes-outside-project-regions ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-region" t)))
        (outside-root (file-name-as-directory
                       (make-temp-file "my-codex-outside" t)))
        (my-codex-region-reference-threshold-chars 5))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory root)
          (setq buffer-file-name (expand-file-name "example.el" outside-root))
          (insert "first\nsecond\nthird\n")
          (set-buffer-modified-p nil)
          (cl-letf (((symbol-function 'my-codex-project-root)
                     (lambda () root))
                    ((symbol-function 'verify-visited-file-modtime)
                     (lambda (_buffer) t)))
            (let ((context (my-codex--region-prompt-context
                            (point-min)
                            (point-max))))
              (should (string-match-p "first\nsecond\nthird" context))
              (should-not (string-match-p "@.* lines " context)))))
      (delete-directory root t)
      (delete-directory outside-root t))))

(ert-deftest my-codex-test-coverage-prompt-puts-dynamic-context-late ()
  (let* ((my-codex-test-coverage-prompt "Stable coverage instructions.")
         (prompt (my-codex--test-coverage-prompt
                  "src/example.el"
                  "test/example-test.el")))
    (let ((instructions-pos
           (string-match "Stable coverage instructions\\." prompt))
          (context-pos (string-match "context:" prompt))
          (implementation-pos
           (string-match "implementation: @src/example\\.el" prompt))
          (test-pos
           (string-match "test: @test/example-test\\.el" prompt))
          (request-pos
           (string-match "request: Analyze test coverage now\\." prompt)))
      (should instructions-pos)
      (should context-pos)
      (should implementation-pos)
      (should test-pos)
      (should request-pos)
      (should (< instructions-pos context-pos))
      (should (< context-pos implementation-pos))
      (should (< implementation-pos test-pos))
      (should (< test-pos request-pos)))))

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

(ert-deftest my-codex-project-files-yaml-lists-files-at-default-threshold ()
  (let ((files (cl-loop for n from 1 to my-codex-project-overview-max-files
                        collect (format "file-%02d.el" n))))
    (should (equal (my-codex--project-files-yaml files)
                   (format "mode: full\nentries:\n%s"
                           (mapconcat
                            (lambda (file)
                              (format "  - \"%s\"" file))
                            files
                            "\n"))))))

(ert-deftest my-codex-project-files-yaml-uses-tree-above-default-threshold ()
  (let* ((files (cl-loop for n from 1
                         to (1+ my-codex-project-overview-max-files)
                         collect (format "src/file-%02d.el" n)))
         (text (my-codex--project-files-yaml files)))
    (should (string-match-p "mode: compact_tree" text))
    (should (string-match-p
             (format "total: %d" (length files))
             text))
    (should-not (string-match-p "mode: full" text))))

(ert-deftest my-codex-project-overview-puts-stable-files-before-status ()
  (let (prompt)
    (cl-letf (((symbol-function 'my-codex-project-root)
               (lambda () "/repo/"))
              ((symbol-function 'my-codex--project-files)
               (lambda (_root) '("README.md" "src/main.el")))
              ((symbol-function 'my-codex--git-status-text)
               (lambda (_root) " M src/main.el"))
              ((symbol-function 'my-codex--unsaved-project-buffer-text)
               (lambda (_root) "src/main.el"))
              ((symbol-function 'my-codex--preview-and-send-prompt)
               (lambda (text) (setq prompt text))))
      (my-codex-send-project-overview))
    (let ((files-pos (string-match "project_files:" prompt))
          (status-pos (string-match "git_status:" prompt))
          (unsaved-pos
           (string-match "unsaved_modified_project_buffers:" prompt)))
      (should files-pos)
      (should status-pos)
      (should unsaved-pos)
      (should (< files-pos status-pos))
      (should (< status-pos unsaved-pos)))))

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
            (should (string-match-p "definition_context:" section))
            (should (string-match-p
                     "location: \"src/example\\.el:1\""
                     section))
            (should (string-match-p "summary: \"alpha\"" section))
            (should (string-match-p "excerpt: |" section))
            (should (string-match-p "(defun alpha" section))
            (should-not (string-match-p "summary: \"beta\"" section))))
      (delete-directory root t))))

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
                      (my-codex--github-issue-output-buffer-name root)))
    (should
     (string-prefix-p "*Antigravity open issues:"
                      (my-codex--github-ticket-list-buffer-name root)))
    (should
     (string-prefix-p "*Antigravity GitHub issue draft:"
                      (my-codex--github-issue-draft-buffer-name root)))))

(provide 'my-codex-test)

;;; my-codex-test.el ends here
