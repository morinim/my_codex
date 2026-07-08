;;; my-codex-doctor-test.el --- Tests for my-codex-doctor -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Code:

(require 'ert)
(require 'my-codex-doctor)

(ert-deftest my-codex-doctor-command-executable-token-handles-shell-prefixes ()
  (should
   (equal
    (my-codex--doctor-command-executable-token
     "FOO=1 command -v env BAR=2 --unset BAZ codex exec")
    "codex")))

(ert-deftest my-codex-doctor-command-executable-token-returns-nil-for-blank ()
  (should-not (my-codex--doctor-command-executable-token "  ")))

(ert-deftest my-codex-doctor-vterm-scrollback-warns-when-disabled ()
  (let ((my-codex-vterm-min-scrollback nil))
    (should
     (equal
      (my-codex--doctor-vterm-scrollback t)
      '("Codex vterm scrollback" warn
        "Scrollback floor is disabled; marked output can be truncated")))))

(ert-deftest my-codex-doctor-vterm-scrollback-reports-local-raise ()
  (let ((was-bound (boundp 'vterm-max-scrollback))
        (original-value (and (boundp 'vterm-max-scrollback)
                             (symbol-value 'vterm-max-scrollback)))
        (my-codex-vterm-min-scrollback 10000))
    (unwind-protect
        (progn
          (set 'vterm-max-scrollback 1000)
          (should
           (equal
            (my-codex--doctor-vterm-scrollback t)
            '("Codex vterm scrollback" ok
              "Codex buffers raise 1000 to 10000 lines"))))
      (if was-bound
          (set 'vterm-max-scrollback original-value)
        (makunbound 'vterm-max-scrollback)))))

(ert-deftest my-codex-doctor-eat-scrollback-reports-unlimited ()
  (let ((my-codex-eat-min-scrollback nil))
    (should
     (equal
      (my-codex--doctor-eat-scrollback t)
      '("Codex Eat scrollback" ok
        "Unlimited scrollback configured")))))

(ert-deftest my-codex-doctor-terminal-rows-use-vterm-selection ()
  (let ((my-codex-terminal-backend 'vterm))
    (cl-letf (((symbol-function 'my-codex--doctor-require-vterm)
               (lambda () (cons nil "stub vterm missing")))
              ((symbol-function 'my-codex--doctor-require-eat)
               (lambda () (error "Should not inspect Eat"))))
      (let ((rows (my-codex--doctor-terminal-rows)))
        (should (equal (car rows)
                       '("vterm package" fail "stub vterm missing")))
        (should-not (seq-find (lambda (row)
                                (string-prefix-p "Eat" (car row)))
                              rows))))))

(ert-deftest my-codex-doctor-terminal-rows-use-eat-selection ()
  (let ((my-codex-terminal-backend 'eat))
    (cl-letf (((symbol-function 'my-codex--doctor-require-eat)
               (lambda () (cons nil "stub Eat missing")))
              ((symbol-function 'my-codex--doctor-require-vterm)
               (lambda () (error "Should not inspect vterm"))))
      (let ((rows (my-codex--doctor-terminal-rows)))
        (should (equal (car rows)
                       '("Eat package" fail "stub Eat missing")))
        (should-not (seq-find (lambda (row)
                                (string-prefix-p "vterm" (car row)))
                              rows))))))

(ert-deftest my-codex-doctor-codex-service-tier-warns-for-fast ()
  (let ((config (make-temp-file "my-codex-config-" nil ".toml")))
    (unwind-protect
        (progn
          (with-temp-file config
            (insert "service_tier = \"fast\"\n"))
          (should
            (equal
             (my-codex--doctor-codex-service-tier config)
             '("Codex user config: service_tier" warn
              "fast in top level uses priority processing and increases costs; use it only when lower latency is worth it"))))
      (delete-file config))))

(ert-deftest my-codex-doctor-codex-service-tier-accepts-non-fast ()
  (let ((config (make-temp-file "my-codex-config-" nil ".toml")))
    (unwind-protect
        (progn
          (with-temp-file config
            (insert "service_tier = \"auto\"\n"))
          (should
           (equal
            (my-codex--doctor-codex-service-tier config)
            '("Codex user config: service_tier" ok
              "Configured as \"auto\" in top level"))))
      (delete-file config))))

(ert-deftest my-codex-doctor-codex-service-tier-respects-codex-home ()
  (let* ((codex-home (make-temp-file "my-codex-home-" t))
         (config (expand-file-name "config.toml" codex-home))
         (process-environment (cons (format "CODEX_HOME=%s" codex-home)
                                    process-environment)))
    (unwind-protect
        (progn
          (with-temp-file config
            (insert "service_tier = \"fast\"\n"))
          (should
            (equal
             (my-codex--doctor-codex-service-tier)
             '("Codex user config: service_tier" warn
              "fast in top level uses priority processing and increases costs; use it only when lower latency is worth it"))))
      (delete-directory codex-home t))))

(ert-deftest my-codex-doctor-codex-service-tier-ignores-inactive-profile ()
  (let ((config (make-temp-file "my-codex-config-" nil ".toml")))
    (unwind-protect
        (progn
          (with-temp-file config
            (insert "profile = \"default\"\n"
                    "\n"
                    "[profiles.default]\n"
                    "service_tier = \"auto\"\n"
                    "\n"
                    "[profiles.fast-profile]\n"
                    "service_tier = \"fast\"\n"))
          (should
           (equal
            (my-codex--doctor-codex-service-tier config)
            '("Codex user config: service_tier" ok
              "Configured as \"auto\" in profile \"default\""))))
      (delete-file config))))

(ert-deftest my-codex-doctor-codex-service-tier-honours-active-profile ()
  (let ((config (make-temp-file "my-codex-config-" nil ".toml")))
    (unwind-protect
        (progn
          (with-temp-file config
            (insert "profile = \"fast-profile\"\n"
                    "service_tier = \"auto\"\n"
                    "\n"
                    "[profiles.default]\n"
                    "service_tier = \"auto\"\n"
                    "\n"
                    "[profiles.fast-profile]\n"
                    "service_tier = \"fast\"\n"))
          (should
            (equal
             (my-codex--doctor-codex-service-tier config)
             '("Codex user config: service_tier" warn
              "fast in profile \"fast-profile\" uses priority processing and increases costs; use it only when lower latency is worth it"))))
      (delete-file config))))

(ert-deftest my-codex-doctor-codex-service-tier-accepts-missing-config ()
  (let ((config (make-temp-file "my-codex-config-" nil ".toml")))
    (delete-file config)
    (should
     (equal
      (my-codex--doctor-codex-service-tier config)
      '("Codex user config: service_tier" ok
        "Not found in user-level config; another configuration layer may override it")))))

(ert-deftest my-codex-doctor-codex-context-rows-report-configured-values ()
  (let ((config (make-temp-file "my-codex-config-" nil ".toml")))
    (unwind-protect
        (progn
          (with-temp-file config
            (insert "tool_output_token_limit = 8000\n"
                    "model_auto_compact_token_limit = 120_000\n"))
          (should
           (equal
            (my-codex--doctor-codex-context-rows config)
            '(("Codex user config: tool_output_token_limit" ok
               "8,000 tokens per tool/function output retained in history")
              ("Codex user config: model_auto_compact_token_limit" ok "120,000 tokens")
              ("Codex user config: project_doc_max_bytes" ok
               "Not found in user-level config; another configuration layer may override it")))))
      (delete-file config))))

(ert-deftest my-codex-doctor-codex-context-rows-honour-active-profile ()
  (let ((config (make-temp-file "my-codex-config-" nil ".toml")))
    (unwind-protect
        (progn
          (with-temp-file config
            (insert "profile = \"compact\"\n"
                    "tool_output_token_limit = 8000\n"
                    "\n"
                    "[profiles.compact]\n"
                    "tool_output_token_limit = 4000\n"))
          (should
           (equal
            (my-codex--doctor-codex-context-rows config)
            '(("Codex user config: tool_output_token_limit" ok
               "4,000 tokens per tool/function output retained in history")
              ("Codex user config: model_auto_compact_token_limit" ok
               "Not found in user-level config; another configuration layer may override it")
              ("Codex user config: project_doc_max_bytes" ok
               "Not found in user-level config; another configuration layer may override it")))))
      (delete-file config))))

(ert-deftest my-codex-doctor-agent-rows-use-profile-callback ()
  (let ((my-codex-agent-profiles
         '((codex :doctor-function my-codex-test--doctor-rows)
           (antigravity :label "Antigravity"))))
    (cl-letf (((symbol-function 'my-codex-test--doctor-rows)
               (lambda () '(("Codex setting" ok "configured")))))
      (should
       (equal (my-codex--doctor-agent-rows 'codex)
              '(("Codex setting" ok "configured"))))
      (should-not (my-codex--doctor-agent-rows 'antigravity)))))

(ert-deftest my-codex-doctor-project-instructions-reports-total-size ()
  (let ((root (make-temp-file "my-codex-project-" t))
        (my-codex-agent 'codex))
    (unwind-protect
        (let ((first (expand-file-name "AGENTS.md" root))
              (second (expand-file-name "CODEX.md" root)))
          (with-temp-file first (insert (make-string 1024 ?a)))
          (with-temp-file second (insert (make-string 512 ?b)))
          (cl-letf (((symbol-function
                      'my-codex--doctor-codex-integer-setting-value)
                     (lambda (&rest _) 4096)))
            (should
             (equal (my-codex--doctor-project-instructions-row
                    root (list first second))
                    '("Project instructions" ok
                      "1.5 KiB discovered across 2 files; 4.0 KiB allowance: AGENTS.md, CODEX.md")))))
      (delete-directory root t))))

(ert-deftest my-codex-doctor-project-instructions-warns-near-allowance ()
  (let ((root (make-temp-file "my-codex-project-" t))
        (my-codex-agent 'codex))
    (unwind-protect
        (let ((file (expand-file-name "AGENTS.md" root)))
          (with-temp-file file (insert (make-string 620 ?a)))
          (cl-letf (((symbol-function
                      'my-codex--doctor-codex-integer-setting-value)
                     (lambda (&rest _) 1024)))
            (should
             (eq (cadr (my-codex--doctor-project-instructions-row
                        root (list file)))
                 'warn))))
      (delete-directory root t))))

(ert-deftest my-codex-doctor-project-instructions-warns-at-allowance ()
  (let ((root (make-temp-file "my-codex-project-" t))
        (my-codex-agent 'codex))
    (unwind-protect
        (let ((file (expand-file-name "AGENTS.md" root)))
          (with-temp-file file (insert (make-string 1024 ?a)))
          (cl-letf (((symbol-function
                      'my-codex--doctor-codex-integer-setting-value)
                     (lambda (&rest _) 1024)))
            (should
             (equal (my-codex--doctor-project-instructions-row
                     root (list file))
                    '("Project instructions" warn
                      "1.0 KiB discovered across 1 file; 1.0 KiB allowance; Codex may omit or truncate instructions: AGENTS.md")))))
      (delete-directory root t))))

(ert-deftest my-codex-doctor-project-instructions-uses-codex-default-allowance ()
  (let ((root (make-temp-file "my-codex-project-" t))
        (my-codex-agent 'codex))
    (unwind-protect
        (let ((file (expand-file-name "AGENTS.md" root)))
          (with-temp-file file (insert (make-string (* 27 1024) ?a)))
          (cl-letf (((symbol-function
                      'my-codex--doctor-codex-integer-setting-value)
                     (lambda (&rest _) nil)))
            (should
             (equal (my-codex--doctor-project-instructions-row
                    root (list file))
                    '("Project instructions" warn
                      "27.0 KiB discovered across 1 file; 32.0 KiB allowance: AGENTS.md")))))
      (delete-directory root t))))

(ert-deftest my-codex-doctor-eat-startup-passes-resolved-shell ()
  (let (eat-args)
    (cl-letf (((symbol-function 'eat)
               (lambda (&rest args)
                 (setq eat-args args)))
              ((symbol-function 'get-buffer-process)
               (lambda (_buffer) 'eat-process))
              ((symbol-function 'process-live-p)
               (lambda (process) (eq process 'eat-process)))
              ((symbol-function 'process-name)
               (lambda (_process) "eat-process"))
              ((symbol-function 'delete-process)
               #'ignore)
              ((symbol-function 'kill-buffer)
               #'ignore))
      (let ((explicit-shell-file-name "")
            (process-environment
             (cons "ESHELL=" process-environment))
            (shell-file-name "/bin/sh"))
        (should
         (equal (my-codex--doctor-eat-terminal-start)
                '("terminal startup" ok "Eat process `eat-process' is live")))
        (should (equal eat-args '("/bin/sh")))))))


(provide 'my-codex-doctor-test)

;;; my-codex-doctor-test.el ends here
