;;; my-codex-ui-test.el --- Tests for my-codex-ui -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Code:

(require 'ert)
(require 'my-codex-ui)

(ert-deftest my-codex-top-renders-dashboard-buffer ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-top" t)))
        (session-buffer (get-buffer-create "*codex-top-render*")))
    (unwind-protect
        (progn
          (my-codex--mark-named-session
           session-buffer "review" root 'workspace-write)
          (cl-letf (((symbol-function 'get-buffer-process)
                     (lambda (buffer)
                       (eq buffer session-buffer)))
                    ((symbol-function 'process-live-p)
                     (lambda (process) process))
                    ((symbol-function 'process-id)
                     (lambda (_) 9999))
                    ((symbol-function 'my-codex--process-output-result)
                     (lambda (program &rest args)
                       (cond
                        ((and (equal program "git") (member "branch" args))
                         '(0 "feature-x"))
                        ((and (equal program "git") (member "status" args))
                         '(0 " M my-codex.el"))
                        (t '(1)))))
                    ((symbol-function 'pop-to-buffer) #'ignore))
            (my-codex-top))
          (with-current-buffer "*Agents Top*"
            (should (derived-mode-p 'my-codex-top-mode))
            (should (string-match-p "review" (buffer-string)))
            (should (string-match-p "Codex" (buffer-string)))
            (should (string-match-p "\\*codex-top-render\\*" (buffer-string)))
            (should (string-match-p "WORKSPACE WRITE" (buffer-string)))
            (should (string-match-p "feature-x" (buffer-string)))
            (should (string-match-p "dirty" (buffer-string)))
            (should (string-match-p "9999" (buffer-string)))
            (should (string-match-p "live" (buffer-string)))))
      (delete-directory root t)
      (when (buffer-live-p session-buffer)
        (kill-buffer session-buffer))
      (when-let ((buffer (get-buffer "*Agents Top*")))
        (kill-buffer buffer)))))

(ert-deftest my-codex-top-header-scrolls-horizontally ()
  (with-temp-buffer
    (my-codex-top-mode)
    (let ((my-codex--header-string "Project Session"))
      (cl-letf (((symbol-function 'window-hscroll) (lambda (&rest _) 8)))
        (should (equal (eval (cadr (nth 2 header-line-format)) t)
                       "Session"))))))

(ert-deftest my-codex-top-sort-refreshes-custom-header ()
  (with-temp-buffer
    (my-codex-top-mode)
    (setq tabulated-list-entries
          '((one ["b" "" "" "" "" "" "" "" "" "" "" "" "" ""])
            (two ["a" "" "" "" "" "" "" "" "" "" "" "" "" ""])))
    (tabulated-list-print)
    (should (eq (command-remapping 'tabulated-list-sort)
                #'my-codex-top-sort))
    (my-codex-top-sort 0)
    (should (eq (caar tabulated-list-entries) 'two))
    (should (equal (car header-line-format) ""))
    (should (memq 'header-line-indent header-line-format))))

(ert-deftest my-codex-top-mouse-sort-refreshes-custom-header ()
  (with-temp-buffer
    (my-codex-top-mode)
    (save-window-excursion
      (let ((window (selected-window)))
        (set-window-buffer window (current-buffer))
        (cl-letf (((symbol-function 'event-start) (lambda (_) (list window)))
                  ((symbol-function 'tabulated-list-col-sort)
                   (lambda (_) (tabulated-list-init-header))))
          (my-codex-top-col-sort 'event))))
    (should (eq (lookup-key my-codex-top-sort-button-map
                            [header-line mouse-1])
                #'my-codex-top-col-sort))
    (should (equal (car header-line-format) ""))
    (should (memq 'header-line-indent header-line-format))))

(ert-deftest my-codex-top-column-resizing-refreshes-custom-header ()
  (with-temp-buffer
    (my-codex-top-mode)
    (setq tabulated-list-entries
          '((one ["project" "" "" "" "" "" "" "" "" "" "" "" "" ""])))
    (tabulated-list-print)
    (goto-char (point-min))
    (should (eq (command-remapping 'tabulated-list-widen-current-column)
                #'my-codex-top-widen-current-column))
    (should (eq (command-remapping 'tabulated-list-narrow-current-column)
                #'my-codex-top-narrow-current-column))
    (my-codex-top-widen-current-column 2)
    (should (= (cadr (aref tabulated-list-format 0)) 8))
    (should (equal (car header-line-format) ""))
    (my-codex-top-narrow-current-column 1)
    (should (= (cadr (aref tabulated-list-format 0)) 7))
    (should (equal (car header-line-format) ""))
    (should (memq 'header-line-indent header-line-format))))

(ert-deftest my-codex-top-git-info-reports-status-failure ()
  (cl-letf (((symbol-function 'my-codex--process-output-result)
             (lambda (_program &rest args)
               (if (member "branch" args)
                   '(0 "feature-x")
                 '(128)))))
    (should (equal (my-codex-top--git-info default-directory)
                   '("feature-x" . "error")))))

(ert-deftest my-codex-top-caches-git-info-by-project-root ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-top" t)))
        (first (get-buffer-create "*codex-top-cache-1*"))
        (second (get-buffer-create "*codex-top-cache-2*"))
        (calls 0))
    (unwind-protect
        (progn
          (my-codex--mark-named-session first "first" root 'read-only)
          (my-codex--mark-named-session second "second" root 'read-only)
          (cl-letf (((symbol-function 'my-codex--all-session-buffers)
                     (lambda () (list first second)))
                    ((symbol-function 'my-codex-top--git-info)
                     (lambda (_root)
                       (setq calls (1+ calls))
                       '("main" . "clean"))))
            (my-codex-top--make-entries)
            (should (= calls 1))))
      (delete-directory root t)
      (kill-buffer first)
      (kill-buffer second))))

(ert-deftest my-codex-top-marks-the-project-active-session ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-top" t)))
        (session (get-buffer-create "*codex-top-active*"))
        (my-codex--project-active-sessions
         (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (my-codex--mark-named-session session "active" root 'read-only)
          (my-codex--set-active-session session)
          (cl-letf (((symbol-function 'my-codex--all-session-buffers)
                     (lambda () (list session)))
                    ((symbol-function 'my-codex-top--cached-git-info)
                     (lambda (_root) '("main" . "clean"))))
            (should (equal (aref (cadar (my-codex-top--make-entries)) 0)
                           "*"))))
      (delete-directory root t)
      (when (buffer-live-p session) (kill-buffer session)))))

(ert-deftest my-codex-top-labels-session-with-removed-agent-profile ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-top" t)))
        (session (get-buffer-create "*codex-top-removed-agent*")))
    (unwind-protect
        (progn
          (my-codex--mark-named-session session "legacy" root 'read-only)
          (with-current-buffer session
            (setq-local my-codex-session-agent 'legacy-agent))
          (let ((my-codex-agent-profiles nil))
            (cl-letf (((symbol-function 'my-codex--all-session-buffers)
                       (lambda () (list session)))
                      ((symbol-function 'my-codex-top--cached-git-info)
                       (lambda (_root) '("main" . "clean"))))
              (should
               (equal (aref (cadar (my-codex-top--make-entries)) 1)
                      "legacy-agent")))))
      (delete-directory root t)
      (when (buffer-live-p session) (kill-buffer session)))))

(ert-deftest my-codex-top-reuses-git-info-across-refreshes ()
  (let ((my-codex-top--git-cache (make-hash-table :test #'equal))
        (my-codex-top-git-cache-ttl 5)
        (calls 0))
    (cl-letf (((symbol-function 'float-time) (lambda (&optional _) 10.0))
              ((symbol-function 'my-codex-top--git-info)
               (lambda (_root)
                 (setq calls (1+ calls))
                 '("main" . "clean"))))
      (my-codex-top--cached-git-info "/project/")
      (my-codex-top--cached-git-info "/project/")
      (should (= calls 1)))))

(ert-deftest my-codex-top-git-cache-expires ()
  (let ((my-codex-top--git-cache (make-hash-table :test #'equal))
        (my-codex-top-git-cache-ttl 5)
        (now 10.0)
        (calls 0))
    (cl-letf (((symbol-function 'float-time) (lambda (&optional _) now))
              ((symbol-function 'my-codex-top--git-info)
               (lambda (_root)
                 (setq calls (1+ calls))
                 (cons (number-to-string calls) "clean"))))
      (my-codex-top--cached-git-info "/project/")
      (setq now 15.0)
      (should (equal (my-codex-top--cached-git-info "/project/")
                     '("2" . "clean"))))))

(ert-deftest my-codex-top-kill-dead-sessions-preserves-live-buffers ()
  (let ((live (get-buffer-create "*codex-top-live*"))
        (dead (get-buffer-create "*codex-top-dead*")))
    (unwind-protect
        (cl-letf (((symbol-function 'my-codex--all-session-buffers)
                   (lambda () (list live dead)))
                  ((symbol-function 'my-codex--session-buffer-live-p)
                   (lambda (buffer) (eq buffer live)))
                  ((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                  ((symbol-function 'revert-buffer) #'ignore))
          (my-codex-top-kill-dead-sessions)
          (should (buffer-live-p live))
          (should-not (buffer-live-p dead)))
      (when (buffer-live-p live) (kill-buffer live))
      (when (buffer-live-p dead) (kill-buffer dead)))))

(ert-deftest my-codex-top-rename-session-refreshes-session-title ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-top" t)))
        (session-buffer (get-buffer-create "*codex-top-rename*")))
    (unwind-protect
        (progn
          (my-codex--mark-named-session
           session-buffer "before" root 'workspace-write)
          (cl-letf (((symbol-function 'get-buffer-process)
                       (lambda (buffer)
                         (eq buffer session-buffer)))
                      ((symbol-function 'process-live-p)
                       (lambda (process) process))
                      ((symbol-function 'process-id)
                       (lambda (_) 9999))
                      ((symbol-function 'my-codex--process-output-lines)
                       (lambda (&rest _) nil))
                      ((symbol-function 'pop-to-buffer) #'ignore)
                      ((symbol-function 'read-string)
                       (lambda (&rest _) "after")))
              (my-codex-top)
              (with-current-buffer "*Agents Top*"
                (goto-char (point-min))
                (search-forward "*codex-top-rename*")
                (beginning-of-line)
                (my-codex-top-rename-session)))
          (with-current-buffer session-buffer
            (should (equal my-codex-session-name "after"))
            (should (equal (buffer-name)
                           (my-codex-session-buffer-name
                            "after" my-codex-session-agent)))
            (should (string-match-p "Codex · WORKSPACE WRITE · after"
                                    header-line-format))
            (let ((footer (my-codex--session-footer)))
              (should (string-match-p
                       (regexp-quote (directory-file-name
                                      (abbreviate-file-name root)))
                       footer))
              (should-not (string-match-p "WORKSPACE WRITE" footer))
              (should-not (string-match-p "\\(^\\| · \\)after\\( · \\|$\\)" footer))
              (should (string-match-p "idle" footer)))
            (should-not (memq 'mode-line-position mode-line-format))))
      (delete-directory root t)
      (when (buffer-live-p session-buffer)
        (kill-buffer session-buffer))
      (when-let ((buffer (get-buffer "*Agents Top*")))
        (kill-buffer buffer)))))

(ert-deftest my-codex-top-rejects-renaming-to-existing-session ()
  (let* ((root (file-name-as-directory (make-temp-file "my-codex-top" t)))
         (source (get-buffer-create "*codex-top-rename-source*"))
         (target-name (let ((default-directory root))
                        (my-codex-session-buffer-name "target" 'codex)))
         (target (get-buffer-create target-name))
         source-name source-id source-title)
    (unwind-protect
        (progn
          (my-codex--mark-named-session
           source "source" root 'workspace-write 'codex)
          (my-codex--mark-named-session
           target "target" root 'workspace-write 'codex)
          (with-current-buffer source
            (setq source-name (buffer-name)
                  source-id my-codex-session-id
                  source-title header-line-format))
          (cl-letf (((symbol-function 'tabulated-list-get-id)
                     (lambda () (buffer-name source)))
                    ((symbol-function 'read-string)
                     (lambda (&rest _) "target")))
            (should-error (my-codex-top-rename-session)
                          :type 'user-error))
          (with-current-buffer source
            (should (equal (buffer-name) source-name))
            (should (equal my-codex-session-name "source"))
            (should (equal my-codex-session-id source-id))
            (should (equal header-line-format source-title))))
      (delete-directory root t)
      (when (buffer-live-p source)
        (kill-buffer source))
      (when (buffer-live-p target)
        (kill-buffer target)))))

(ert-deftest my-codex-top-rejects-renaming-default-session ()
  (let ((root (file-name-as-directory (make-temp-file "my-codex-default" t)))
        (session-buffer (get-buffer-create "*codex-default-rename*")))
    (unwind-protect
        (progn
          (my-codex--mark-default-session session-buffer root 'read-only)
          (cl-letf (((symbol-function 'tabulated-list-get-id)
                     (lambda () (buffer-name session-buffer))))
            (should-error (my-codex-top-rename-session)
                          :type 'user-error)))
      (delete-directory root t)
      (when (buffer-live-p session-buffer)
        (kill-buffer session-buffer)))))

(ert-deftest my-codex-top-visit-edit-window-selects-associated-window ()
  (let ((session-buffer (get-buffer-create "*codex-top-edit*"))
        dashboard-window)
    (unwind-protect
        (let ((edit-window (selected-window)))
          (setq dashboard-window (split-window-right))
          (set-window-parameter
           edit-window 'my-codex-term-buffer session-buffer)
          (set-window-buffer dashboard-window (get-buffer-create "*Agents Top*"))
          (with-current-buffer "*Agents Top*"
            (my-codex-top-mode)
            (setq tabulated-list-entries
                  `((,(buffer-name session-buffer)
                     ["" "" "project" "session" ,(buffer-name session-buffer)
                      "" "" "" "" "" "" "" "" ""])))
            (tabulated-list-print)
            (goto-char (point-min))
            (search-forward (buffer-name session-buffer))
            (beginning-of-line))
          (select-window dashboard-window)
          (my-codex-top-visit-edit-window)
          (should (eq (selected-window) edit-window)))
      (when (window-live-p dashboard-window)
        (delete-window dashboard-window))
      (when (buffer-live-p session-buffer)
        (kill-buffer session-buffer))
      (when-let ((buffer (get-buffer "*Agents Top*")))
        (kill-buffer buffer)))))

(ert-deftest my-codex-top-visit-edit-window-searches-all-frames ()
  (let ((session-buffer (get-buffer-create "*codex-top-other-frame*"))
        (edit-window (selected-window)))
    (unwind-protect
        (progn
          (set-window-parameter
           edit-window 'my-codex-term-buffer session-buffer)
          (with-temp-buffer
            (my-codex-top-mode)
            (setq tabulated-list-entries
                  `((,(buffer-name session-buffer)
                     ["" "" "project" "session" ,(buffer-name session-buffer)
                      "" "" "" "" "" "" "" "" ""])))
            (tabulated-list-print)
            (goto-char (point-min))
            (search-forward (buffer-name session-buffer))
            (beginning-of-line)
            (cl-letf (((symbol-function 'frame-list)
                       (lambda () '(dashboard-frame edit-frame)))
                      ((symbol-function 'window-list)
                       (lambda (frame &rest _)
                         (and (eq frame 'edit-frame)
                              (list edit-window)))))
              (my-codex-top-visit-edit-window)
              (should (eq (selected-window) edit-window)))))
      (set-window-parameter edit-window 'my-codex-term-buffer nil)
      (kill-buffer session-buffer))))

(ert-deftest my-codex-edit-windows-for-session-buffer-stays-frame-local ()
  (let ((session-buffer (get-buffer-create "*codex-frame-local*"))
        (edit-window (selected-window)))
    (unwind-protect
        (progn
          (set-window-parameter
           edit-window 'my-codex-term-buffer session-buffer)
          (cl-letf (((symbol-function 'window-list)
                     (lambda (frame &rest _)
                       (and (eq frame 'other-frame)
                            (list edit-window)))))
            (should-not
             (my-codex--edit-windows-for-session-buffer session-buffer))))
      (set-window-parameter edit-window 'my-codex-term-buffer nil)
      (kill-buffer session-buffer))))

(ert-deftest my-codex-top-visit-edit-window-requires-association ()
  (let ((session-buffer (get-buffer-create "*codex-top-no-edit*")))
    (unwind-protect
        (with-temp-buffer
          (my-codex-top-mode)
          (setq tabulated-list-entries
                `((,(buffer-name session-buffer)
                   ["" "" "project" "session" ,(buffer-name session-buffer)
                    "" "" "" "" "" "" "" "" ""])))
          (tabulated-list-print)
          (goto-char (point-min))
          (search-forward (buffer-name session-buffer))
          (beginning-of-line)
          (should-error (my-codex-top-visit-edit-window)
                        :type 'user-error))
      (kill-buffer session-buffer))))

(ert-deftest my-codex-top-visit-switches-session-window ()
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
                    ((symbol-function 'process-id) (lambda (_) 9999))
                    ((symbol-function 'my-codex--process-output-lines)
                     (lambda (&rest _) nil))
                    ((symbol-function 'pop-to-buffer)
                     (lambda (buffer-or-name &rest _args)
                       (set-window-buffer
                        (selected-window)
                        (get-buffer buffer-or-name))
                       (selected-window))))
            (my-codex-top)
            (with-current-buffer "*Agents Top*"
              (goto-char (point-min))
              (search-forward "*codex-sessions-select*")
              (beginning-of-line)
              (my-codex-top-visit))
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
      (when-let ((buffer (get-buffer "*Agents Top*")))
        (kill-buffer buffer)))))

(ert-deftest my-codex-top-visit-from-terminal-updates-edit-window ()
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
                    ((symbol-function 'process-id) (lambda (_) 9999))
                    ((symbol-function 'my-codex--process-output-lines)
                     (lambda (&rest _) nil))
                    ((symbol-function 'pop-to-buffer) #'ignore))
            (my-codex-top)
            (with-current-buffer "*Agents Top*"
              (goto-char (point-min))
              (search-forward "*codex-sessions-terminal-new*")
              (beginning-of-line)
              (my-codex-top-visit))
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
      (when-let ((buffer (get-buffer "*Agents Top*")))
        (kill-buffer buffer)))))


(provide 'my-codex-ui-test)

;;; my-codex-ui-test.el ends here
