;;; my-codex.el --- Codex integration -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Manlio Morini

;; Author: Manlio Morini
;; Keywords: tools, convenience
;; URL: https://github.com/morinim/my_codex
;; Version: 0.98.2
;; Package-Requires: ((emacs "29.1") (vterm "0") (transient "0"))

;; This file is not part of GNU Emacs.

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at https://mozilla.org/MPL/2.0/.

;;; Commentary:

;; my-codex.el runs OpenAI Codex CLI or Google Antigravity inside an Emacs
;; vterm buffer. It provides a two-column layout, project-specific agent
;; sessions, helpers for Git diffs, selected regions, diagnostics, build
;; output, and compiler or test errors.

;;; Code:

(require 'compile)
(require 'my-codex-core)
(require 'my-codex-layout)
(require 'my-codex-ui)
(require 'cl-lib)
(require 'ediff)
(require 'easymenu)
(require 'project)
(require 'subr-x)
(require 'transient)

(autoload 'vterm-mode "vterm" nil t)
(autoload 'vterm-send-string "vterm")
(autoload 'vterm-send-return "vterm")
(autoload 'vterm-yank "vterm" nil t)
(autoload 'vterm-copy-mode "vterm" nil t)
(autoload 'my-codex-session-links-mode "my-codex-links" nil t)
(autoload 'my-codex-vterm-integration-mode "my-codex-vterm" nil t)
(autoload 'my-codex--vterm-mode-with-scrollback-floor "my-codex-vterm")
(autoload 'my-codex--ensure-vterm-scrollback "my-codex-vterm")
(autoload 'my-codex--current-or-left-file-available-p "my-codex-git")
(autoload 'my-codex--request-marked-output "my-codex-prompts")
(autoload 'my-codex-send-prompt "my-codex-prompts")
(autoload 'my-codex-visible-window "my-codex-prompts")
(dolist (autoload-entry
         '((my-codex-send-region . "my-codex-prompts")
           (my-codex-copy-region-reference . "my-codex-prompts")
           (my-codex-review-defun-at-point . "my-codex-prompts")
           (my-codex-send-current-file . "my-codex-prompts")
           (my-codex-analyse-test-coverage . "my-codex-prompts")
           (my-codex-explain-symbol-at-point . "my-codex-prompts")
           (my-codex-explain-diagnostic-at-point . "my-codex-diagnostics")
           (my-codex-explain-buffer-diagnostics . "my-codex-diagnostics")
           (my-codex-explain-region-as-error . "my-codex-prompts")
           (my-codex-plan-refactor-region . "my-codex-prompts")
           (my-codex-open-project-instructions . "my-codex-prompts")
           (my-codex-toggle-focus . "my-codex-prompts")
           (my-codex-insert-selection-into-code . "my-codex-prompts")
           (my-codex-ask . "my-codex-prompts")
           (my-codex-ask-preset-transient . "my-codex-prompts")
           (my-codex-send-project-overview . "my-codex-git")
           (my-codex-send-git-diff . "my-codex-git")
           (my-codex-send-git-staged-diff . "my-codex-git")
           (my-codex-review-current-file-diff . "my-codex-git")
           (my-codex-show-git-diff . "my-codex-git")
           (my-codex-show-git-staged-diff . "my-codex-git")
           (my-codex-ediff-current-file-against-head . "my-codex-git")
           (my-codex-ediff-changed-file-against-head . "my-codex-git")
           (my-codex-git-commit-with-latest-message . "my-codex-git")
           (my-codex-list-open-issues . "my-codex-github")
           (my-codex-summarize-session-to-github-issue . "my-codex-github")
           (my-codex-doctor . "my-codex-doctor")))
  (autoload (car autoload-entry) (cdr autoload-entry) nil t))
(declare-function markdown-mode "markdown-mode")
(declare-function projectile-toggle-between-implementation-and-test "projectile")
(defvar vterm-copy-mode)
(defun my-codex--track-process-output-time (process)
  "Record output timestamps for PROCESS without replacing its behaviour."
  (unless (process-get process 'my-codex-output-time-filter)
    (let ((original-filter (process-filter process)))
      (process-put process 'my-codex-output-time-filter t)
      (set-process-filter
       process
       (lambda (proc output)
         (when (and output (not (string-empty-p output)))
           (when-let (buffer (process-buffer proc))
             (with-current-buffer buffer
               (setq-local my-codex-session-last-output-time (current-time))
               (force-mode-line-update))))
         (when original-filter
           (funcall original-filter proc output)))))))

(cl-defmethod my-codex-backend-start
  ((backend my-codex-vterm-backend) project-root command
   &optional session-name agent access-mode)
  "Start BACKEND's vterm process in PROJECT-ROOT with COMMAND."
  (let* ((agent (or agent my-codex-agent))
         (access-mode
          (or access-mode (my-codex--session-access-mode command agent)))
         (default-directory project-root)
         (buffer-name (my-codex--backend-buffer-name backend))
         (buffer (get-buffer-create buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'vterm-mode)
        (my-codex--vterm-mode-with-scrollback-floor))
      (my-codex--ensure-vterm-scrollback)
      (setq-local show-trailing-whitespace nil)
      (when my-codex-enable-session-links
        (my-codex-session-links-mode 1))
      (let ((proc (get-buffer-process buffer)))
        (unless (process-live-p proc)
          (user-error "Failed to start vterm process in %s" buffer-name))
        (set-process-query-on-exit-flag proc nil)
        (my-codex--track-process-output-time proc)
        (goto-char (point-max))
        (vterm-send-string (my-codex--shell-command-and-exit command))
        (vterm-send-return)))
    (if session-name
        (my-codex--mark-named-session
         buffer session-name project-root access-mode agent)
      (my-codex--mark-default-session
       buffer project-root access-mode agent))
    (when (bound-and-true-p my-codex-vterm-integration-mode)
      (with-current-buffer buffer
        (my-codex--enable-vterm-buffer-integration)))
    buffer))

(defun my-codex--selected-window-is-codex-p ()
  "Return non-nil if the selected window shows Codex."
  (eq (selected-window)
      (ignore-errors
        (my-codex-visible-window))))

(defun my-codex--vterm-shell-name ()
  "Return the configured vterm shell executable name, if known."
  (let ((shell (or (and (boundp 'vterm-shell)
                        (let ((value (symbol-value 'vterm-shell)))
                          (and (stringp value)
                               (not (string-empty-p value))
                               value)))
                   shell-file-name
                   "")))
    (file-name-nondirectory
     (replace-regexp-in-string "\\\\" "/" shell))))

(defun my-codex--shell-command-and-exit (command)
  "Return shell text that runs COMMAND, then exits with its status."
  (let ((shell (downcase (my-codex--vterm-shell-name))))
    (cond
     ((member shell '("cmd" "cmd.exe" "cmdproxy" "cmdproxy.exe"))
      (format "%s\nexit %%ERRORLEVEL%%" command))
     ((member shell '("powershell" "powershell.exe" "pwsh" "pwsh.exe"))
      (format (concat "%s\n"
                      "if ($LASTEXITCODE -ne $null) { exit $LASTEXITCODE }\n"
                      "if ($?) { exit 0 } else { exit 1 }")
              command))
     (t
      (format "%s\nstatus=$?\nexit $status" command)))))


;;;###autoload
(defun my-codex-hide-window ()
  "Hide visible windows showing the current agent buffer."
  (interactive)
  (let* ((buffer (my-codex-active-session-buffer))
         (label (with-current-buffer buffer
                  (if my-codex-session-agent
                      (my-codex--agent-label my-codex-session-agent)
                    (my-codex--active-agent-label))))
         (windows (get-buffer-window-list buffer nil t)))
    (unless windows
      (user-error "%s window is not visible" label))
    (dolist (window windows)
      (when (window-live-p window)
        (quit-window nil window)))
    (message "%s window hidden" label)))

(defun my-codex--show-default-session (agent access-mode)
  "Show AGENT's default session using ACCESS-MODE."
  (my-codex-two-column-layout-with-command
   (my-codex--agent-command agent access-mode)
   nil nil agent access-mode))

;;;###autoload
(defun my-codex-read-only ()
  "Show the configured agent, starting it in read-only mode if needed."
  (interactive)
  (my-codex--show-default-session my-codex-agent 'read-only))

;;;###autoload
(defun my-codex-workspace ()
  "Show the configured agent with workspace write access if needed."
  (interactive)
  (my-codex--show-default-session my-codex-agent 'workspace-write))

;;;###autoload
(defun my-codex-default-read-only (agent)
  "Show the default AGENT session in read-only mode."
  (interactive (list (my-codex--read-agent)))
  (my-codex--show-default-session agent 'read-only))

;;;###autoload
(defun my-codex-default-workspace (agent)
  "Show the default AGENT session with workspace write access."
  (interactive (list (my-codex--read-agent)))
  (my-codex--show-default-session agent 'workspace-write))

(defun my-codex--session-action-context (action &optional require-live)
  "Return (BUFFER AGENT INPUT) for ACTION in the active session.
When REQUIRE-LIVE is non-nil, require a running session process."
  (let* ((buffer (my-codex-active-session-buffer require-live))
         (agent (with-current-buffer buffer my-codex-session-agent))
         (input (and agent (my-codex--session-action agent action))))
    (unless input
      (user-error "Agent %s does not support session action %s"
                  (if agent (my-codex--agent-label agent) "session") action))
    (list buffer agent input)))

(defun my-codex--session-action-available-p (action)
  "Return non-nil when ACTION is supported by the active live session."
  (and (ignore-errors (my-codex--session-action-context action t)) t))

(defun my-codex--run-session-action (action)
  "Run ACTION in the active session."
  (pcase-let ((`(,buffer ,_agent ,input)
               (my-codex--session-action-context action t)))
    (my-codex-send-prompt input buffer)))

(defun my-codex--compact-session-available-p ()
  "Return non-nil when the active session supports compaction."
  (my-codex--session-action-available-p 'compact))

;;;###autoload
(defun my-codex-compact-session ()
  "Compact the active session when its agent supports that action."
  (interactive)
  (my-codex--run-session-action 'compact))

(defun my-codex--read-session-access-mode ()
  "Read and return an access mode for a new named session."
  (pcase (minibuffer-with-setup-hook
             (lambda () (minibuffer-completion-help))
           (completing-read
            "Session access: "
            '("read-only" "workspace-write")
            nil t nil nil "read-only"))
    ("read-only" 'read-only)
    ("workspace-write" 'workspace-write)))

(defcustom my-codex-session-handoff-prompt
  "Create a concise Markdown handoff for a fresh agent session.

Include the objective, relevant decisions, constraints, required files or
references, completed work, and unresolved questions.  Do not duplicate
content already captured in project artefacts; reference those artefacts by
path or URL instead.  Redact secrets and personal information.  Do not edit
files."
  "Prompt used by `my-codex-new-session-from-handoff'."
  :type 'string
  :group 'my-codex)

;;;###autoload
(defun my-codex-new-session (name agent &optional access-mode)
  "Start or show a named agent session NAME using AGENT and ACCESS-MODE."
  (interactive
   (list
    (read-string "Session name: ")
    (my-codex--read-agent)
    (my-codex--read-session-access-mode)))
  (let ((session-name (my-codex--normalise-session-name name)))
    (my-codex-two-column-layout-with-command
     (my-codex--agent-command agent access-mode)
     nil session-name agent access-mode)))

;;;###autoload
(defun my-codex-new-session-from-handoff (name agent access-mode)
  "Create named session NAME using AGENT and ACCESS-MODE from a handoff.
Ask the active session for compact context, then send only that context to
the new session."
  (interactive
   (list
    (read-string "New session name: ")
    (my-codex--read-agent)
    (my-codex--read-session-access-mode)))
  (let* ((source-buffer (my-codex-active-session-buffer t))
         (root (with-current-buffer source-buffer
                 (or my-codex-session-project-root
                     (my-codex-project-root))))
         (session-name (my-codex--normalise-session-name name))
         (default-directory root)
         (target-name (my-codex-session-buffer-name session-name agent)))
    (with-current-buffer source-buffer
      (when (timerp my-codex--handoff-wait-timer)
        (user-error "A session handoff is already pending")))
    (when (get-buffer target-name)
      (user-error "Session %s already exists" session-name))
    (my-codex--request-marked-output
     :name "SESSION_HANDOFF"
     :buffer source-buffer
     :prompt my-codex-session-handoff-prompt
     :placeholder "<Markdown handoff here>"
     :callback
     (lambda (handoff)
       (let ((default-directory root))
         (when (get-buffer target-name)
           (user-error "Session %s was created while waiting for its handoff"
                       session-name))
         (my-codex-new-session session-name agent access-mode)
         (my-codex-send-prompt handoff (get-buffer target-name))))
     :timeout-message "Timed out waiting for agent session handoff."
     :ready-message (format "Started session %s from handoff." session-name)
     :poll-interval my-codex-generated-output-poll-interval
     :poll-attempts my-codex-generated-output-poll-attempts
     :timer-var 'my-codex--handoff-wait-timer)
    (message "Asked the active agent for a handoff; waiting to start %s."
             session-name)))

;;;###autoload
(defun my-codex-resume ()
  "Show the configured agent, resuming a previous session if needed."
  (interactive)
  (my-codex-two-column-layout-with-command
   (my-codex--agent-command my-codex-agent 'resume)
   t nil my-codex-agent 'resume))

;;;###autoload
(defun my-codex-export-session-to-markdown ()
  "Export the current project's agent session transcript to Markdown."
  (interactive)
  (let* ((buffer (my-codex-active-session-buffer))
         (root (with-current-buffer buffer
                 (or my-codex-session-project-root
                     (my-codex-project-root))))
         (transcript (my-codex-session-transcript))
         (export-buffer
          (get-buffer-create (my-codex--session-export-buffer-name root))))
    (when (string-empty-p transcript)
      (user-error "Agent session transcript is empty"))
    (with-current-buffer export-buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (my-codex--insert-session-export-markdown
         transcript root (buffer-name buffer))
        (goto-char (point-min)))
      (my-codex--session-export-mode))
    (pop-to-buffer export-buffer)
    (message "%s session exported to Markdown."
             (my-codex--active-agent-label root))))

;;;###autoload
(defun my-codex-summarize-session-to-markdown ()
  "Ask the agent to summarize the current conversation as Markdown notes.
Open the generated notes in an editable Markdown buffer when they are ready."
  (interactive)
  (require 'my-codex-prompts)
  (let* ((buffer (my-codex-active-session-buffer t))
         (root (with-current-buffer buffer
                 (or my-codex-session-project-root
                     (my-codex-project-root)))))
    (my-codex--request-marked-output
     :name "SESSION_SUMMARY"
     :buffer buffer
     :prompt my-codex-session-summary-prompt
     :placeholder "<Markdown notes here>"
     :callback (lambda (summary)
                 (my-codex-edit-session-summary summary root))
     :timeout-message "Timed out waiting for agent session summary."
     :ready-message "Agent session summary is ready for editing."
     :poll-interval my-codex-generated-output-poll-interval
     :poll-attempts my-codex-generated-output-poll-attempts
     :timer-var 'my-codex--generated-artifact-wait-timer)
    (message "Asked %s to summarize the session; waiting to open editor."
             (my-codex--active-agent-label root))))

(eval-and-compile
  (defun my-codex-send-region-or-current-file ()
    "Send the active region, or the current file when no region is active."
    (interactive)
    (call-interactively
     (if (use-region-p)
         #'my-codex-send-region
       #'my-codex-send-current-file)))

  (defun my-codex--region-available-p ()
    "Return non-nil when the region is active."
    (use-region-p))

  (defun my-codex--current-file-available-p ()
    "Return non-nil when the current buffer visits a file."
    (and buffer-file-name t))

  (defun my-codex--agent-selection-available-p ()
    "Return non-nil when selected agent text can be inserted into code."
    (and (my-codex--selected-window-is-codex-p)
         (or my-codex--captured-selection (use-region-p))))

  (defconst my-codex-command-catalogue
    '((:command my-codex-read-only :key "o" :label "Read-only" :group "Session" :menu "Show/start read-only" :help "Show the configured agent in read-only mode")
      (:command my-codex-workspace :key "w" :label "Workspace" :group "Session" :menu "Show/start workspace-write" :help "Show the configured agent with workspace write access")
      (:command my-codex-session-transient :key "S" :label "Sessions" :group "Session" :menu "Session commands" :help "Open default and future agent session commands")
      (:command my-codex-git-review-transient :key "r" :label "Review diff..." :group "Git" :menu "Review Git diff" :help "Open Git diff review commands")
      (:command my-codex-hide-window :key "q" :label "Hide agent" :group "Session" :menu "Hide agent window" :help "Hide the visible agent window")
      (:command my-codex-toggle-focus :key "<tab>" :label "Toggle focus" :group "Session" :menu "Toggle focus" :menu-key "TAB" :help "Toggle focus between the agent and the previous window")
      (:command my-codex-toggle-focus :key "TAB")
      (:command my-codex-ask :key "a" :label "Ask" :group "Send" :menu "Ask agent..." :help "Prompt for a question and send it to the active agent")
      (:command my-codex-ask-preset-transient :key "A" :label "Preset menu" :group "Send" :menu "Preset menu" :help "Open the prompt preset menu")
      (:command my-codex-send-region :key "s" :label "Region" :group "Send" :menu "Send selected region" :available my-codex--region-available-p :help "Send the selected region to the active agent")
      (:command my-codex-send-region-or-current-file :key "<right>" :label "Region or file" :group "Send")
      (:command my-codex-plan-refactor-region :key "R" :label "Refactor plan" :group "Send" :menu "Plan refactor for selected region" :available my-codex--region-available-p :help "Ask the active agent for a low-risk refactoring plan")
      (:command my-codex-insert-selection-into-code :key "<left>" :label "Insert selection" :group "Send" :menu "Insert selection" :menu-key "Left" :available my-codex--agent-selection-available-p :help "Insert the captured agent selection into the code buffer")
      (:command my-codex-review-defun-at-point :key "f" :label "Current defun" :group "Send" :menu "Review current defun" :help "Ask the active agent to review the defun at point")
      (:command my-codex-send-current-file :key "F" :label "Current file" :group "Send" :menu "Inspect current file" :available my-codex--current-file-available-p :help "Ask the active agent to inspect the current file directly")
      (:command my-codex-analyse-test-coverage :key "C" :label "Coverage gaps" :group "Send" :menu "Analyse test coverage" :available my-codex--current-file-available-p :help "Ask the active agent to analyse missing test scenarios")
      (:command my-codex-explain-symbol-at-point :key "x" :label "Explain symbol" :group "Send" :menu "Explain symbol at point" :available my-codex--current-file-available-p :help "Ask the active agent to explain the symbol at point")
      (:command my-codex-git-transient :key "g" :label "Inspect diff..." :group "Git" :menu "Inspect Git diff" :help "Open local Git diff and ediff commands")
      (:command my-codex-git-commit-with-latest-message :key "c" :label "Commit with agent message" :group "Git" :menu "Edit commit with agent message" :help "Use the latest agent commit message, or ask for one, then edit before committing")
      (:command my-codex-explain-region-as-error :key "e" :label "Explain error" :group "Context" :menu "Explain selected error" :available my-codex--region-available-p :help "Ask the active agent to explain the selected compiler/test error")
      (:command my-codex-copy-region-reference :key "y" :label "Copy reference" :group "Context" :menu "Copy selected region reference" :available my-codex--region-available-p :help "Copy a compact file-and-line reference for the selected region")
      (:command my-codex-open-project-instructions :key "i" :label "Project instructions" :group "Context" :menu "Open project instructions" :help "Open AGENTS.md, CODEX.md, or .codex/instructions.md")
      (:command my-codex-summarize-session-to-markdown :key "M" :label "Summarize session" :group "Context" :menu "Summarize session to Markdown" :help "Ask the active agent to summarize the conversation as Markdown notes")
      (:command my-codex-tools-transient :key "T" :label "Tools" :group "Context")
      (:command my-codex-default-read-only :key "o" :label "Read-only" :group "Default session" :prefix my-codex-session-transient :path "S" :menu "Show/start default read-only" :help "Show the default agent session in read-only mode")
      (:command my-codex-default-workspace :key "w" :label "Workspace" :group "Default session" :prefix my-codex-session-transient :path "S" :menu "Show/start default workspace-write" :help "Show the default agent session with workspace write access")
      (:command my-codex-top :key "l" :label "Dashboard" :group "Session" :prefix my-codex-session-transient :path "S" :menu "Session dashboard" :help "Display a dashboard of all agent sessions")
      (:command my-codex-new-session :key "n" :label "New named" :group "Session" :prefix my-codex-session-transient :path "S" :menu "New named session" :help "Start or show a named agent session")
      (:command my-codex-new-session-from-handoff :key "h" :label "From handoff" :group "Session" :prefix my-codex-session-transient :path "S" :menu "Start fresh with handoff" :help "Create a named session containing only a compact handoff")
      (:command my-codex-resume :key "r" :label "Resume" :group "Session" :prefix my-codex-session-transient :path "S" :menu "Resume session" :help "Resume a previous agent session")
      (:command my-codex-compact-session :key "k" :label "Compact context" :group "Session" :prefix my-codex-session-transient :path "S" :menu "Compact session context" :available my-codex--compact-session-available-p :help "Compact context in the active session when supported")
      (:command my-codex-hide-window :key "q" :label "Hide agent" :group "Session" :prefix my-codex-session-transient :path "S" :menu "Hide selected session window" :help "Hide the agent window associated with the selected session")
      (:command my-codex-send-project-overview :key "p" :label "Project overview" :group "Tools" :prefix my-codex-tools-transient :path "T" :menu "Project overview" :help "Send the active agent a compact project overview")
      (:command my-codex-export-session-to-markdown :key "X" :label "Export session" :group "Tools" :prefix my-codex-tools-transient :path "T" :menu "Export session" :help "Export the current agent session transcript to Markdown")
      (:command my-codex-diagnostics-transient :key "E" :label "Diagnostics" :group "Tools" :prefix my-codex-tools-transient :path "T" :menu "Diagnostics" :help "Open diagnostic explanation commands")
      (:command my-codex-doctor :key "!" :label "Doctor" :group "Tools" :prefix my-codex-tools-transient :path "T" :menu "Doctor" :help "Check Emacs, agent, vterm, Git, gh, project, configuration, and terminal startup")
      (:command my-codex-send-git-diff :key "a" :label "All changes" :group "Review diff" :prefix my-codex-git-review-transient :path "r" :menu "Review all Git changes" :help "Ask the active agent to review the current Git diff")
      (:command my-codex-send-git-staged-diff :key "s" :label "Staged changes" :group "Review diff" :prefix my-codex-git-review-transient :path "r" :menu "Review staged Git changes" :help "Ask the active agent to review the staged Git diff")
      (:command my-codex-review-current-file-diff :key "f" :label "Current file" :group "Review diff" :prefix my-codex-git-review-transient :path "r" :menu "Review current-file Git diff" :available my-codex--current-or-left-file-available-p :help "Ask the active agent to review only the current file's Git diff")
      (:command my-codex-show-git-diff :key "v" :label "View diff" :group "Inspect diff" :prefix my-codex-git-transient :path "g" :menu "View Git diff" :help "Show the current Git diff in a diff-mode buffer")
      (:command my-codex-show-git-staged-diff :key "V" :label "View staged diff" :group "Inspect diff" :prefix my-codex-git-transient :path "g" :menu "View staged Git diff" :help "Show the staged Git diff in a diff-mode buffer")
      (:command my-codex-ediff-current-file-against-head :key "d" :label "Ediff current file" :group "Inspect diff" :prefix my-codex-git-transient :path "g" :menu "Ediff current file against HEAD" :available my-codex--current-or-left-file-available-p :help "Review the current file's uncommitted changes against HEAD")
      (:command my-codex-ediff-changed-file-against-head :key "D" :label "Ediff changed file" :group "Inspect diff" :prefix my-codex-git-transient :path "g" :menu "Ediff changed file against HEAD" :help "Choose a tracked changed file and review it against HEAD")
      (:command my-codex-list-open-issues :key "t" :label "List issues" :group "GitHub" :menu "List issues" :help "List open GitHub issues for the current repository in a buffer")
      (:command my-codex-summarize-session-to-github-issue :key "I" :label "Draft issue" :group "GitHub" :menu "Draft issue" :help "Ask the active agent to draft a GitHub issue, then edit it before creating it with gh")
      (:command my-codex-explain-diagnostic-at-point :key "p" :label "At point" :group "Diagnostics" :prefix my-codex-diagnostics-transient)
      (:command my-codex-explain-buffer-diagnostics :key "a" :label "All" :group "Diagnostics" :prefix my-codex-diagnostics-transient))
    "Commands used to generate the prefix keymap and command menus.")

  (defun my-codex--validate-command-catalogue (catalogue &optional resolve)
    "Validate command CATALOGUE and return it.
When RESOLVE is non-nil, also require availability predicates to be defined."
    (let ((known-properties
           '(:command :key :label :group :menu :menu-key :help
             :available :prefix :path))
          (bindings (make-hash-table :test #'equal)))
      (dolist (entry catalogue)
        (let ((properties entry))
          (while properties
            (let ((property (pop properties)))
              (unless (memq property known-properties)
                (error "Unknown command catalogue property: %S" property))
              (unless properties
                (error "Missing value for command catalogue property: %S"
                       property))
              (pop properties))))
        (let* ((command (plist-get entry :command))
               (key (plist-get entry :key))
               (label (plist-get entry :label))
               (group (plist-get entry :group))
               (available (plist-get entry :available))
               (prefix (or (plist-get entry :prefix) 'my-codex-transient))
               (binding (and key (cons prefix (key-description (kbd key)))))
               (existing (and binding (gethash binding bindings))))
          (unless command
            (error "Command catalogue entry lacks :command: %S" entry))
          (unless (stringp key)
            (error "Command catalogue entry lacks string :key: %S" entry))
          (unless (eq (and label t) (and group t))
            (error "Transient command needs both :label and :group: %S" entry))
          (when (and available (not (symbolp available)))
            (error "Availability predicate is not a symbol: %S" available))
          (when (and resolve available (not (fboundp available)))
            (error "Unknown availability predicate: %S" available))
          (when (and existing (not (eq existing command)))
            (error "Duplicate command binding %s %s" prefix key))
          (puthash binding command bindings)))
      catalogue))

  (my-codex--validate-command-catalogue my-codex-command-catalogue)

  (defun my-codex--catalogue-transient-layout (prefix)
    "Return the transient layout for PREFIX from the command catalogue."
    (let (groups)
      (dolist (entry my-codex-command-catalogue)
        (when (and (eq (or (plist-get entry :prefix)
                           'my-codex-transient)
                       prefix)
                   (plist-get entry :label))
          (let* ((group (plist-get entry :group))
                 (cell (assoc group groups))
                 (suffix (append (list (plist-get entry :key)
                                       (plist-get entry :label)
                                       (plist-get entry :command))
                                 (when-let ((predicate
                                             (plist-get entry :available)))
                                   (list :inapt-if-not predicate)))))
            (if cell
                (setcdr cell (append (cdr cell) (list suffix)))
              (setq groups (append groups (list (list group suffix))))))))
      (mapcar (lambda (group) (vconcat (list (car group)) (cdr group))) groups)))

  (defmacro my-codex--define-catalogue-transient (name doc)
    "Define transient NAME with DOC from `my-codex-command-catalogue'."
    `(transient-define-prefix ,name () ,doc
       ,(vconcat
         (list [:description my-codex--transient-target-description])
         (my-codex--catalogue-transient-layout name))
       (interactive)
       (transient-setup ',name nil nil
                        :scope (ignore-errors
                                 (my-codex-active-session-buffer))))))

;; Autoload forms are not evaluated while this file is byte-compiled, so
;; resolve predicates only when the source or compiled package is loaded.
(my-codex--validate-command-catalogue my-codex-command-catalogue t)

(defun my-codex--catalogue-prefix-keymap ()
  "Return the prefix keymap described by the command catalogue."
  (let ((map (make-sparse-keymap)))
    (dolist (entry my-codex-command-catalogue map)
      (unless (plist-get entry :prefix)
        (keymap-set map (plist-get entry :key)
                    (plist-get entry :command))))))

;; Prefix keymap for agent commands.
(defvar my-codex-map (my-codex--catalogue-prefix-keymap)
  "Prefix keymap for agent commands.")

;;;###autoload (autoload 'my-codex-session-transient "my-codex" nil t)
(my-codex--define-catalogue-transient my-codex-session-transient
  "Show agent session commands.")

;;;###autoload (autoload 'my-codex-diagnostics-transient "my-codex" nil t)
(my-codex--define-catalogue-transient my-codex-diagnostics-transient
  "Show diagnostic explanation commands.")

;;;###autoload (autoload 'my-codex-tools-transient "my-codex" nil t)
(my-codex--define-catalogue-transient my-codex-tools-transient
  "Show infrequent agent tools.")

;;;###autoload (autoload 'my-codex-git-review-transient "my-codex" nil t)
(my-codex--define-catalogue-transient my-codex-git-review-transient
  "Show Git diff review commands.")

;;;###autoload (autoload 'my-codex-git-transient "my-codex" nil t)
(my-codex--define-catalogue-transient my-codex-git-transient
  "Show local Git diff commands.")

;;;###autoload (autoload 'my-codex-transient "my-codex" nil t)
(my-codex--define-catalogue-transient my-codex-transient
  "Show agent commands.")

;;;###autoload
(defun my-codex-transient-preserve-selection ()
  "Show Codex commands without disturbing the active region."
  (interactive)
  (setq my-codex--captured-selection
        (when (and (my-codex--selected-window-is-codex-p)
                   (use-region-p))
          (prog1
              (filter-buffer-substring
               (region-beginning)
               (region-end))
            (deactivate-mark))))
  (my-codex-transient))


;;;###autoload
(defun my-codex-project-build ()
  "Run the project build command with `compile'."
  (interactive)
  (let ((default-directory (my-codex-project-root)))
    (compile (or my-codex-project-build-command compile-command))))

(defvar-keymap my-codex-global-mode-map
  :doc "Keymap for `my-codex-global-mode'."
  "<f7>" #'my-codex-project-build
  "<f8>" #'my-codex-transient-preserve-selection)

(defun my-codex--enable-display-defaults ()
  "Enable default editing display helpers."
  (unless my-codex--display-defaults-enabled-by-mode
    (setq my-codex--saved-show-trailing-whitespace
          (default-value 'show-trailing-whitespace))
    (setq my-codex--saved-column-number-mode
          (bound-and-true-p column-number-mode))
    (setq my-codex--display-defaults-enabled-by-mode t))
  (setq-default show-trailing-whitespace
                my-codex--display-show-trailing-whitespace-value)
  (column-number-mode
   (if my-codex--display-column-number-mode-value 1 -1)))

(defun my-codex--restore-display-defaults ()
  "Restore display defaults changed by `my-codex-global-mode'."
  (when my-codex--display-defaults-enabled-by-mode
    (when (eq (default-value 'show-trailing-whitespace)
              my-codex--display-show-trailing-whitespace-value)
      (setq-default show-trailing-whitespace
                    my-codex--saved-show-trailing-whitespace))
    (when (eq (bound-and-true-p column-number-mode)
              my-codex--display-column-number-mode-value)
      (column-number-mode
       (if my-codex--saved-column-number-mode 1 -1)))
    (setq my-codex--saved-show-trailing-whitespace nil)
    (setq my-codex--saved-column-number-mode nil)
    (setq my-codex--display-defaults-enabled-by-mode nil)))

(defun my-codex--catalogue-easy-menu ()
  "Return an Easy Menu specification from the command catalogue."
  (let (groups)
    (dolist (entry my-codex-command-catalogue)
      (when-let ((label (plist-get entry :menu)))
        (let* ((group-name
                (if (member (plist-get entry :group)
                            '("Default session" "Session"))
                    "Session"
                  (plist-get entry :group)))
               (group (assoc group-name groups))
               (path (plist-get entry :path))
               (key (or (plist-get entry :menu-key)
                        (plist-get entry :key)))
               (available (plist-get entry :available))
               (item (vector label (plist-get entry :command)
                             :keys (string-join
                                    (delq nil (list "F8" path key)) " ")
                             :active (or (and available (list available))
                                         t)
                             :help (plist-get entry :help))))
          (if group
              (setcdr group (append (cdr group) (list item)))
            (setq groups
                  (append groups (list (list group-name item))))))))
    (append (list "Agent")
            groups
            (list "---"
                  ["Compile project" my-codex-project-build
                   :keys "F7"
                   :help "Run the project build command"]))))

(easy-menu-define my-codex-menu my-codex-global-mode-map
  "Menu for agent commands."
  (my-codex--catalogue-easy-menu))

;;;###autoload
(define-minor-mode my-codex-global-mode
  "Global minor mode for seamless Codex integration."
  :global t
  :group 'my-codex
  :keymap my-codex-global-mode-map
  (if my-codex-global-mode
      (progn
        (when my-codex-enable-display-defaults
          (my-codex--enable-display-defaults))
        (when (and my-codex-enable-vterm-integration
                   (not my-codex--vterm-integration-enabled-by-mode)
                   (not (bound-and-true-p my-codex-vterm-integration-mode)))
          (setq my-codex--vterm-integration-enabled-by-mode t)
          (my-codex-vterm-integration-mode 1))
        (when (and my-codex-enable-global-auto-revert
                   (not my-codex--auto-revert-enabled-by-mode)
                   (not (bound-and-true-p global-auto-revert-mode)))
          (setq my-codex--auto-revert-enabled-by-mode t)
          (global-auto-revert-mode 1)))
    (when (and my-codex--auto-revert-enabled-by-mode
               (bound-and-true-p global-auto-revert-mode))
      (global-auto-revert-mode -1))
    (when (and my-codex--vterm-integration-enabled-by-mode
               (bound-and-true-p my-codex-vterm-integration-mode))
      (my-codex-vterm-integration-mode -1))
    (my-codex--restore-display-defaults)
    (setq my-codex--vterm-integration-enabled-by-mode nil)
    (setq my-codex--auto-revert-enabled-by-mode nil)))

(provide 'my-codex)

;;; my-codex.el ends here
