;;; my-codex-core.el --- Core definitions for my-codex -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Manlio Morini

;; Author: Manlio Morini
;; Keywords: tools, convenience
;; URL: https://github.com/morinim/my_codex

;; This file is not part of GNU Emacs.

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at https://mozilla.org/MPL/2.0/.

;;; Commentary:

;; Shared configuration, session state, backend protocol, and project/session
;; lookup helpers for my-codex modules.

;;; Code:

(require 'ansi-color)
(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'subr-x)

(declare-function markdown-mode "markdown-mode")
(defvar vterm-max-scrollback)

(defun my-codex--prepare-edit-buffer
    (text root mode header accept-command cancel-command)
  "Prepare the current buffer for editing TEXT from ROOT.
MODE is the major-mode function.  HEADER is shown in the header line.
ACCEPT-COMMAND and CANCEL-COMMAND are bound to `C-c C-c' and `C-c C-k'."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert text)
    (goto-char (point-min)))
  (setq default-directory root)
  (funcall mode)
  (setq-local header-line-format header)
  (let ((map (define-keymap :parent (current-local-map)
               "C-c C-c" accept-command
               "C-c C-k" cancel-command)))
    (use-local-map map)))

(defgroup my-codex nil
  "Customisation options for the Codex development tool."
  :group 'convenience
  :prefix "my-codex-")

(defconst my-codex-default-buffer-name "*codex*"
  "Default name of the vterm buffer used for Codex.")

(defcustom my-codex-buffer-name my-codex-default-buffer-name
  "Name of the vterm buffer used for Codex."
  :type 'string
  :group 'my-codex)

(defcustom my-codex-agent 'codex
  "Agent profile used by default agent commands.
Commands such as `my-codex-read-only', `my-codex-workspace', and
`my-codex-resume' use this profile.  Named sessions can choose a
different profile interactively."
  :type 'symbol
  :group 'my-codex)

(defcustom my-codex-agent-profiles
  '((codex
     :label "Codex"
     :buffer-prefix "codex"
     :commands
     ((read-only . "codex --sandbox read-only --ask-for-approval on-request")
      (workspace-write . "codex --sandbox workspace-write --ask-for-approval on-request")
      (resume . "codex resume"))
     :session-actions
     ((compact . "/compact"))
     :instruction-files
     ("AGENTS.override.md" "AGENTS.md" "CODEX.md" ".codex/instructions.md")
     :instruction-strategy hierarchical-first
     :file-reference-format "@%s"
     :doctor-function my-codex--doctor-codex-rows)
    (antigravity
     :label "Antigravity"
     :buffer-prefix "agy"
     :commands
     ((read-only . "agy --sandbox -i \"System policy: This is a read-only session. Do not write/edit files or execute commands that alter the codebase.\"")
      (workspace-write . "agy")
      (resume . "agy resume"))
     :session-actions ()
     :instruction-files
     ("ANTIGRAVITY.md" ".antigravity/instructions.md")
     :instruction-strategy root-all
     :file-reference-format "%s"
     :doctor-function nil))
  "Agent profiles available to my-codex.
Each entry has the form:

  (ID :label LABEL
      :buffer-prefix PREFIX
      :commands ((read-only . COMMAND)
                 (workspace-write . COMMAND)
                 (resume . COMMAND))
      :session-actions ((ACTION . INPUT) ...)
      :instruction-files (FILE ...)
      :instruction-strategy STRATEGY
      :file-reference-format FORMAT
      :doctor-function FUNCTION)

ID is a symbol used for configuration and session metadata.  PREFIX is
used in buffer names, so different agents can have sessions with the
same project and session name without colliding.  STRATEGY is either
`hierarchical-first' (select the first matching file in each directory)
or `root-all' (select every matching file at the project root).  FUNCTION
may be nil or a function returning backend-specific doctor rows.  FORMAT
is a `format' string used for project-relative file references."
  :type '(repeat
          (list :tag "Agent profile"
                (symbol :tag "Identifier")
                (const :format "" :value :label)
                (string :tag "Display label")
                (const :format "" :value :buffer-prefix)
                (string :tag "Buffer prefix")
                (const :format "" :value :commands)
                (alist :tag "Commands"
                       :key-type (choice (const read-only)
                                         (const workspace-write)
                                         (const resume))
                       :value-type string)
                (const :format "" :value :session-actions)
                (alist :tag "Session actions"
                       :key-type symbol
                       :value-type string)
                (const :format "" :value :instruction-files)
                (repeat :tag "Instruction files" string)
                (const :format "" :value :instruction-strategy)
                (choice :tag "Instruction strategy"
                        (const hierarchical-first)
                        (const root-all))
                (const :format "" :value :file-reference-format)
                (string :tag "File reference format")
                (const :format "" :value :doctor-function)
                (choice :tag "Doctor function"
                        (const :tag "None" nil)
                        (function :tag "Function"))))
  :group 'my-codex)

(cl-defun my-codex-define-agent
    (id &key label buffer-prefix commands session-actions instruction-files
        (instruction-strategy 'root-all) (file-reference-format "%s")
        doctor-function)
  "Define or replace agent profile ID and return ID.
COMMANDS is an alist mapping access modes to shell commands.  Supported
access modes are `read-only', `workspace-write', and `resume'.
SESSION-ACTIONS maps action symbols to text sent to the agent.
INSTRUCTION-FILES lists project instruction file names.  The remaining
keywords correspond to properties documented by
`my-codex-agent-profiles'."
  (unless (and id (symbolp id) (not (keywordp id)))
    (error "Agent ID must be a non-keyword symbol: %S" id))
  (unless (and (listp commands) commands)
    (error "Agent %s must define commands" id))
  (dolist (command commands)
    (unless (and (consp command)
                 (memq (car command) '(read-only workspace-write resume))
                 (stringp (cdr command))
                 (not (string-empty-p (cdr command))))
      (error "Invalid command in agent %s: %S" id command)))
  (dolist (action session-actions)
    (unless (and (consp action) (symbolp (car action))
                 (stringp (cdr action)) (not (string-empty-p (cdr action))))
      (error "Invalid session action in agent %s: %S" id action)))
  (unless (and (listp instruction-files)
               (seq-every-p #'stringp instruction-files))
    (error "Agent %s instruction files must be strings" id))
  (unless (memq instruction-strategy '(hierarchical-first root-all))
    (error "Invalid instruction strategy for agent %s: %S"
           id instruction-strategy))
  (unless (and (stringp file-reference-format)
               (not (string-empty-p file-reference-format)))
    (error "Agent %s file reference format must be a non-empty string" id))
  (unless (or (null doctor-function) (symbolp doctor-function)
              (functionp doctor-function))
    (error "Invalid doctor function for agent %s: %S" id doctor-function))
  (let ((profile
         (list :label (or label (capitalize (symbol-name id)))
               :buffer-prefix (or buffer-prefix (symbol-name id))
               :commands commands
               :session-actions session-actions
               :instruction-files instruction-files
               :instruction-strategy instruction-strategy
               :file-reference-format file-reference-format
               :doctor-function doctor-function)))
    (unless (stringp (plist-get profile :label))
      (error "Agent %s label must be a string" id))
    (unless (and (stringp (plist-get profile :buffer-prefix))
                 (not (string-empty-p (plist-get profile :buffer-prefix))))
      (error "Agent %s buffer prefix must be a non-empty string" id))
    (setf (alist-get id my-codex-agent-profiles nil nil #'eq) profile))
  id)

(defcustom my-codex-left-width 81
  "Width of the editing window text area in the Codex right-side layout."
  :type 'natnum
  :group 'my-codex)

(defcustom my-codex-min-right-width nil
  "Optional minimum width of the Codex vterm window.
When nil, `my-codex-right-width' is used directly."
  :type '(choice (const :tag "No minimum" nil)
                 natnum)
  :group 'my-codex)

(defcustom my-codex-right-width 80
  "Target width of the Codex vterm window."
  :type 'natnum
  :group 'my-codex)

(defcustom my-codex-enforce-right-side-layout nil
  "When non-nil, resize the frame and edit window for right-side Codex.
Leave this nil when another package or window manager controls window sizes."
  :type 'boolean
  :group 'my-codex)

(defcustom my-codex-display-buffer-action
  '((display-buffer-in-side-window)
    (side . right)
    (slot . 0)
    (window-width . my-codex--right-window-width))
  "Display action used for Codex buffers.

The value is passed to `display-buffer'.  Customise this when you prefer a
different placement, such as a bottom side window or a dedicated frame."
  :type 'sexp
  :group 'my-codex)

(defun my-codex--instruction-target-directory (root)
  "Return the instruction discovery directory below ROOT."
  (let ((directory (file-name-as-directory
                    (file-truename
                     (if buffer-file-name
                         (file-name-directory buffer-file-name)
                       default-directory))))
        (root (file-name-as-directory (file-truename root))))
    (if (file-in-directory-p directory root) directory root)))

(defun my-codex--directories-to (root target)
  "Return directories from ROOT through TARGET, inclusive."
  (let* ((root (file-name-as-directory (file-truename root)))
         (relative (file-relative-name (file-truename target) root))
         (parts (unless (string= relative ".")
                  (split-string (directory-file-name relative) "/" t)))
         (directories (list root))
         (directory root))
    (dolist (part parts (nreverse directories))
      (setq directory (file-name-as-directory
                       (expand-file-name part directory)))
      (push directory directories))))

(defun my-codex-project-instruction-files (&optional root target agent)
  "Return effective instruction files for AGENT.
ROOT defaults to the current project root and TARGET to the current buffer's
directory.  Discovery follows the agent profile's instruction strategy."
  (let* ((root (or root (my-codex-project-root)))
         (target (or target (my-codex--instruction-target-directory root)))
         (agent (or agent (my-codex--active-agent root))))
    (let* ((profile (my-codex--agent-profile agent))
           (names (plist-get profile :instruction-files)))
      (pcase (plist-get profile :instruction-strategy)
        ('hierarchical-first
         (delq nil
               (mapcar
                (lambda (directory)
                  (seq-find #'file-regular-p
                            (mapcar (lambda (name)
                                      (expand-file-name name directory))
                                    names)))
                (my-codex--directories-to root target))))
        ('root-all
         (seq-filter
          #'file-regular-p
          (mapcar (lambda (name) (expand-file-name name root)) names)))
        (_
         (user-error "Agent %s has an invalid instruction strategy" agent))))))

(defcustom my-codex-project-build-command nil
  "Command used to build the current project.
When nil, use `compile-command'."
  :type '(choice (const :tag "Use compile-command" nil)
                 string)
  :group 'my-codex)

(defcustom my-codex-warn-about-unsaved-project-buffers t
  "When non-nil, warn before sending prompts if project buffers are unsaved."
  :type 'boolean
  :group 'my-codex)

(defun my-codex-modified-project-buffers ()
  "Return modified file-visiting buffers belonging to the current project."
  (if-let (project (project-current))
      (seq-filter (lambda (buf)
                    (and (buffer-file-name buf)
                         (buffer-modified-p buf)))
                  (project-buffers project))
    (let ((root (file-truename default-directory)))
      (seq-filter (lambda (buf)
                    (when-let (file (buffer-file-name buf))
                      (and (buffer-modified-p buf)
                           (file-in-directory-p (file-truename file) root))))
                  (buffer-list)))))

(defun my-codex--warn-about-unsaved-project-buffers ()
  "Display a non-blocking warning if project buffers have unsaved changes."
  (when my-codex-warn-about-unsaved-project-buffers
    (when-let (buffers (my-codex-modified-project-buffers))
      (message "Agent warning: unsaved buffer(s): %s"
               (mapconcat #'buffer-name buffers ", ")))))

(defcustom my-codex-enable-global-auto-revert t
  "When non-nil, enable `global-auto-revert-mode' with `my-codex-global-mode'.
This defaults to non-nil so buffers follow changes made on disk by an agent,
reducing the risk of users continuing to edit stale buffer contents."
  :type 'boolean
  :group 'my-codex)

(defcustom my-codex-enable-display-defaults nil
  "When non-nil, enable editing display helpers with `my-codex-global-mode'."
  :type 'boolean
  :group 'my-codex)

(defcustom my-codex-enable-session-links t
  "When non-nil, make URLs and file references clickable in agent buffers."
  :type 'boolean
  :group 'my-codex)

(defcustom my-codex-enable-vterm-integration t
  "When non-nil, enable vterm helpers with `my-codex-global-mode'."
  :type 'boolean
  :group 'my-codex)

(defcustom my-codex-vterm-min-scrollback 10000
  "Minimum `vterm-max-scrollback' used in agent vterm buffers.
This protects marked-output extraction from losing markers when
the agent emits verbose output.  When nil, do not adjust vterm scrollback."
  :type '(choice (const :tag "Do not adjust" nil)
                 natnum)
  :group 'my-codex)

(defvar my-codex--auto-revert-enabled-by-mode nil
  "Non-nil when `my-codex-global-mode' enabled `global-auto-revert-mode'.")

(defvar my-codex--vterm-integration-enabled-by-mode nil
  "Non-nil when `my-codex-global-mode' enabled vterm integration.")

(defvar my-codex--saved-show-trailing-whitespace nil
  "Previous default value of `show-trailing-whitespace'.")

(defvar my-codex--saved-column-number-mode nil
  "Previous value of `column-number-mode'.")

(defvar my-codex--display-defaults-enabled-by-mode nil
  "Non-nil when `my-codex-global-mode' changed display defaults.")

(defconst my-codex--display-show-trailing-whitespace-value t
  "Default `show-trailing-whitespace' value set by `my-codex-global-mode'.")

(defconst my-codex--display-column-number-mode-value t
  "Default `column-number-mode' value set by `my-codex-global-mode'.")

(defvar-local my-codex--prompt-preview-origin-window nil
  "Window selected before opening the current prompt preview.")

(defvar-local my-codex--edit-fill-column-indicator-state nil
  "Previous fill-column indicator state saved by my-codex.")

(defvar my-codex--edit-fill-column-indicator-buffers nil
  "Buffers whose fill-column indicator state is temporarily managed.")

(defcustom my-codex-generated-output-poll-interval 0.5
  "Seconds between checks for generated agent output."
  :type 'number
  :group 'my-codex)

(defcustom my-codex-generated-output-poll-attempts 600
  "Maximum number of checks for generated agent output."
  :type 'natnum
  :group 'my-codex)

(defvar-local my-codex--generated-artifact-wait-timer nil
  "Active timer waiting for a generated session artefact.")

(defvar-local my-codex--handoff-wait-timer nil
  "Active timer waiting for a generated session handoff.")

(defvar-local my-codex-session-id nil
  "Identifier for the agent session owned by the current buffer.")

(defvar-local my-codex-session-name nil
  "Human-readable agent session name for the current buffer.")

(defvar-local my-codex-session-project-root nil
  "Project root associated with the current agent session buffer.")

(defvar-local my-codex-session-access-mode nil
  "Access mode used for the current agent session buffer.")

(defvar-local my-codex-session-agent nil
  "Agent profile used for the current agent session buffer.")

(defvar-local my-codex-session-start-time nil
  "Time when the agent session started.")

(defvar-local my-codex-session-last-activity nil
  "Time of the last prompt sent to the agent.")

(defvar-local my-codex-session-last-output-time nil
  "Time of the last output received from the agent process.")

(defvar-local my-codex-session-prompt-count 0
  "Number of prompts sent during this agent session.")

(defface my-codex-workspace-write-face
  '((t :inherit warning :weight bold))
  "Face used to mark workspace-write agent sessions."
  :group 'my-codex)

(defface my-codex-read-only-face
  '((t :inherit shadow))
  "Face used to mark read-only agent sessions."
  :group 'my-codex)

(defun my-codex--access-mode-label (access-mode &optional plain)
  "Return a visual label for ACCESS-MODE.
When PLAIN is non-nil, do not apply text properties."
  (let* ((label
          (pcase access-mode
            ('workspace-write "WORKSPACE WRITE")
            ('read-only "read-only [lock]")
            ('resume "resume")
            ('custom "custom")
            ('unknown "unknown")
            (_ (if access-mode (symbol-name access-mode) "unknown"))))
         (face
          (pcase access-mode
            ('workspace-write 'my-codex-workspace-write-face)
            ('read-only 'my-codex-read-only-face)
            (_ nil))))
    (if (or plain (null face))
        label
      (propertize label 'face face))))

(defun my-codex--session-title (&optional agent session access-mode plain)
  "Return the display title for an agent session."
  (format "%s · %s · %s"
          (my-codex--agent-label (or agent my-codex-agent))
          (my-codex--access-mode-label access-mode plain)
          (or session "default")))

(defun my-codex--terminal-type-label ()
  "Return a short label for the current terminal buffer type."
  (cond
   ((derived-mode-p 'vterm-mode) "vterm")
   ((derived-mode-p 'term-mode) "ansi-term")
   ((derived-mode-p 'shell-mode) "shell")
   (t (format-mode-line mode-name))))

(defun my-codex--short-directory-name (directory)
  "Return DIRECTORY abbreviated for compact display."
  (if (and directory (not (string-empty-p directory)))
      (directory-file-name (abbreviate-file-name directory))
    "-"))

(defun my-codex--process-status-label (&optional process)
  "Return a compact state label for PROCESS."
  (if process
      (pcase (process-status process)
        ('run "running")
        ('stop "stopped")
        ('exit (format "exited %s" (process-exit-status process)))
        ('signal (format "signalled %s" (process-exit-status process)))
        (status (symbol-name status)))
    "idle"))

(defun my-codex--last-status-label (&optional process)
  "Return the last command status label for PROCESS."
  (if process
      (pcase (process-status process)
        ('exit (number-to-string (process-exit-status process)))
        ('signal (pcase (process-exit-status process)
                   (2 "SIGINT")
                   (15 "SIGTERM")
                   (9 "SIGKILL")
                   (status (format "signal %s" status))))
        (_ "-"))
    "-"))

(defun my-codex--last-output-label ()
  "Return the latest output time for the current session."
  (if my-codex-session-last-output-time
      (format-time-string "%H:%M" my-codex-session-last-output-time)
    "-"))

(defun my-codex--session-footer ()
  "Return the dynamic footer text for the current agent session."
  (let ((process (get-buffer-process (current-buffer))))
    (format " %s · %s · %s · %s · last %s"
            (my-codex--terminal-type-label)
            (my-codex--short-directory-name
             (or my-codex-session-project-root default-directory))
            (my-codex--process-status-label process)
            (my-codex--last-status-label process)
            (my-codex--last-output-label))))

(defun my-codex--refresh-session-title ()
  "Refresh the current buffer's agent session title surfaces."
  (let ((title (my-codex--session-title
                my-codex-session-agent
                my-codex-session-name
                my-codex-session-access-mode)))
    (setq-local header-line-format title)
    (setq-local mode-line-format
                '((:eval (my-codex--session-footer))))))

(defvar my-codex--captured-selection nil
  "Text captured before opening a transient from an active region.")


(cl-defstruct (my-codex-vterm-backend
               (:constructor my-codex--make-vterm-backend (buffer-name)))
  "Backend implementation that runs an agent in a vterm buffer."
  buffer-name)

(defvar my-codex--project-active-agents (make-hash-table :test #'equal)
  "Agent profile identifiers keyed by project root.")

(defvar my-codex--project-active-sessions (make-hash-table :test #'equal)
  "Active agent session buffers keyed by project root.")

(cl-defgeneric my-codex-backend-start
    (backend project-root command &optional session-name agent access-mode)
  "Start BACKEND in PROJECT-ROOT with COMMAND and return its buffer.
When SESSION-NAME is non-nil, mark the buffer as that named session.")

(cl-defgeneric my-codex-backend-send (backend prompt)
  "Send PROMPT through BACKEND.")

(cl-defgeneric my-codex-backend-live-p (backend)
  "Return non-nil when BACKEND has a live agent process.")

(autoload 'vterm-send-string "vterm")
(autoload 'vterm-send-return "vterm")

(defun my-codex--backend-buffer-name (backend)
  "Return BACKEND's buffer name."
  (my-codex-vterm-backend-buffer-name backend))

(defun my-codex--backend-buffer (backend)
  "Return BACKEND's buffer, or nil when it does not exist."
  (get-buffer (my-codex--backend-buffer-name backend)))

(defun my-codex--backend-for-buffer-name (buffer-name)
  "Return the backend for BUFFER-NAME."
  (my-codex--make-vterm-backend buffer-name))

(defun my-codex--current-backend ()
  "Return the backend for the current project default agent session."
  (my-codex--backend-for-buffer-name (my-codex-current-buffer-name)))

(defun my-codex--agent-profile (agent)
  "Return the profile for AGENT, or raise an error."
  (or (alist-get agent my-codex-agent-profiles)
      (user-error "Unknown my-codex agent profile: %s" agent)))

(defun my-codex--agent-ids ()
  "Return configured agent profile identifiers."
  (mapcar #'car my-codex-agent-profiles))

(defun my-codex--agent-label (agent)
  "Return the display label for AGENT."
  (or (plist-get (my-codex--agent-profile agent) :label)
      (symbol-name agent)))

(defun my-codex--agent-buffer-prefix (agent)
  "Return the buffer prefix for AGENT."
  (let ((prefix (plist-get (my-codex--agent-profile agent) :buffer-prefix)))
    (cond
     ((and (stringp prefix) (not (string-empty-p prefix))) prefix)
     ((symbolp prefix) (symbol-name prefix))
     (t (symbol-name agent)))))

(defun my-codex--agent-command (agent access-mode)
  "Return AGENT's command string for ACCESS-MODE."
  (unless (memq access-mode '(read-only workspace-write resume))
    (user-error "Unknown access mode: %s" access-mode))
  (let* ((profile (my-codex--agent-profile agent))
         (command (alist-get access-mode (plist-get profile :commands))))
    (if (and (stringp command) (not (string-empty-p command)))
        command
      (user-error "Agent %s has no %s command" agent access-mode))))

(defun my-codex--session-action (agent action)
  "Return AGENT input for session ACTION, or nil when unsupported."
  (let ((input (alist-get action
                          (plist-get (my-codex--agent-profile agent)
                                     :session-actions))))
    (when (and (stringp input) (not (string-empty-p input)))
      input)))

(defun my-codex--read-agent ()
  "Read and return an agent profile identifier."
  (intern
   (minibuffer-with-setup-hook
       (lambda () (minibuffer-completion-help))
     (completing-read
      "Agent: "
      (mapcar #'symbol-name (my-codex--agent-ids))
      nil t nil nil (symbol-name my-codex-agent)))))

(cl-defmethod my-codex-backend-live-p ((backend my-codex-vterm-backend))
  "Return non-nil when BACKEND's vterm process is live."
  (when-let (buffer (my-codex--backend-buffer backend))
    (process-live-p (get-buffer-process buffer))))

(cl-defmethod my-codex-backend-send
  ((backend my-codex-vterm-backend) prompt)
  "Send PROMPT through BACKEND's vterm buffer."
  (let ((buffer (or (my-codex--backend-buffer backend)
                    (user-error "No %s buffer found"
                                (my-codex--backend-buffer-name backend)))))
    (with-current-buffer buffer
      (goto-char (point-max))
      (vterm-send-string prompt t)
      (vterm-send-return)
      (setq my-codex-session-last-activity (current-time))
      (setq my-codex-session-prompt-count
            (1+ (or my-codex-session-prompt-count 0))))))

(defun my-codex--session-access-mode (command &optional agent)
  "Return the session access mode represented by COMMAND."
  (let ((agent (or agent my-codex-agent)))
    (cond
     ((equal command (my-codex--agent-command agent 'workspace-write))
      'workspace-write)
     ((equal command (my-codex--agent-command agent 'read-only))
      'read-only)
     ((equal command (my-codex--agent-command agent 'resume)) 'resume)
     (t 'custom))))

(defun my-codex--default-session-id (project-root &optional agent)
  "Return the default session identifier for PROJECT-ROOT."
  (format "%s:default:%s"
          (or agent my-codex-agent)
          (substring (secure-hash 'sha1 (file-truename project-root)) 0 8)))

(defun my-codex--session-id (project-root session-name &optional agent)
  "Return the named session identifier for PROJECT-ROOT and SESSION-NAME."
  (format "%s:session:%s:%s"
          (or agent my-codex-agent)
          (substring (secure-hash 'sha1 (file-truename project-root)) 0 8)
          (my-codex--safe-session-name session-name)))

(defun my-codex--mark-session
    (buffer session-id session-name project-root access-mode agent)
  "Mark BUFFER as SESSION-ID named SESSION-NAME for PROJECT-ROOT."
  (with-current-buffer buffer
    (setq-local my-codex-session-id session-id)
    (setq-local my-codex-session-name session-name)
    (setq-local my-codex-session-project-root
                (file-name-as-directory (file-truename project-root)))
    (setq-local my-codex-session-access-mode access-mode)
    (setq-local my-codex-session-agent agent)
    (setq-local my-codex-session-start-time (current-time))
    (setq-local my-codex-session-last-activity (current-time))
    (setq-local my-codex-session-last-output-time nil)
    (setq-local my-codex-session-prompt-count 0)
    (add-hook 'kill-buffer-hook #'my-codex--forget-active-session nil t)
    (my-codex--refresh-session-title)))

(defun my-codex--mark-default-session
    (buffer project-root access-mode &optional agent)
  "Mark BUFFER as the default agent session for PROJECT-ROOT."
  (let ((agent (or agent my-codex-agent)))
    (my-codex--mark-session
     buffer
     (my-codex--default-session-id project-root agent)
     "default"
     project-root
     access-mode
     agent)))

(defun my-codex--mark-named-session
    (buffer session-name project-root access-mode &optional agent)
  "Mark BUFFER as SESSION-NAME for PROJECT-ROOT."
  (let ((agent (or agent my-codex-agent)))
    (my-codex--mark-session
     buffer
     (my-codex--session-id project-root session-name agent)
     session-name
     project-root
     access-mode
     agent)))

(defun my-codex--safe-root-name (root)
  "Return a buffer-name-safe representation of ROOT."
  (replace-regexp-in-string
   "[^[:alnum:]._-]+" "!"
   (directory-file-name (file-truename root))))

(defun my-codex-project-root ()
  "Return the current project root, or `default-directory' if not in a project."
  (file-name-as-directory
   (if-let (project (project-current))
       (project-root project)
     default-directory)))

(defun my-codex--project-key (&optional root)
  "Return the stable project key for ROOT or the current project."
  (file-name-as-directory
   (file-truename (or root (my-codex-project-root)))))

(defun my-codex--active-agent (&optional root)
  "Return the active agent profile for ROOT or the current project."
  (or (gethash (my-codex--project-key root)
               my-codex--project-active-agents)
      my-codex-agent))

(defun my-codex--active-agent-label (&optional root)
  "Return the display label for the active agent."
  (my-codex--agent-label (my-codex--active-agent root)))

(defun my-codex--set-active-agent (agent &optional root)
  "Record AGENT as the active agent for ROOT or the current project."
  (puthash (my-codex--project-key root)
           agent
           my-codex--project-active-agents))

(defun my-codex--set-active-session (buffer)
  "Record BUFFER as the active session for its project."
  (unless (buffer-live-p buffer)
    (user-error "Session buffer is no longer live"))
  (with-current-buffer buffer
    (unless (and (bound-and-true-p my-codex-session-id)
                 my-codex-session-project-root)
      (user-error "%s is not an agent session" (buffer-name buffer)))
    (let ((root my-codex-session-project-root))
      (puthash (my-codex--project-key root)
               buffer
               my-codex--project-active-sessions)
      (when my-codex-session-agent
        (my-codex--set-active-agent my-codex-session-agent root)))))

(defun my-codex--forget-active-session ()
  "Forget the current buffer when it is its project's active session."
  (when (and (bound-and-true-p my-codex-session-id)
             my-codex-session-project-root)
    (let ((key (my-codex--project-key my-codex-session-project-root)))
      (when (eq (gethash key my-codex--project-active-sessions)
                (current-buffer))
        (remhash key my-codex--project-active-sessions)))))

(defun my-codex-current-buffer-name (&optional agent)
  "Return the buffer name for the current agent session."
  (let ((agent (or agent (my-codex--active-agent))))
    (if-let* ((project (project-current))
              (root (file-truename (project-root project)))
              (name (file-name-nondirectory (directory-file-name root)))
              (hash (substring (secure-hash 'sha1 root) 0 8)))
        (format "*%s:%s:%s*"
                (my-codex--agent-buffer-prefix agent) name hash)
      (if (and (eq agent 'codex)
               (not (equal my-codex-buffer-name
                           my-codex-default-buffer-name)))
          my-codex-buffer-name
        (let* ((root (file-truename (my-codex-project-root)))
               (name (file-name-nondirectory (directory-file-name root)))
               (hash (substring (secure-hash 'sha1 root) 0 8)))
          (format "*%s:%s:%s*"
                  (my-codex--agent-buffer-prefix agent) name hash))))))

(defun my-codex--normalise-session-name (name)
  "Return a normalised agent session NAME, or raise an error."
  (let ((normalised (string-trim name)))
    (when (string-empty-p normalised)
      (user-error "Session name cannot be empty"))
    (when (string-equal normalised "default")
      (user-error "Use F8 S o or F8 S w for the default session"))
    normalised))

(defun my-codex--safe-session-name (name)
  "Return a buffer-name-safe representation of session NAME."
  (let* ((normalised (my-codex--normalise-session-name name))
         (slug (replace-regexp-in-string
                "[^[:alnum:]._-]+" "!"
                normalised))
         (hash (substring (secure-hash 'sha1 normalised) 0 8)))
    (format "%s-%s" slug hash)))

(defun my-codex-session-buffer-name (session-name &optional agent)
  "Return the buffer name for SESSION-NAME in the current project."
  (let* ((safe-name (my-codex--safe-session-name session-name))
         (default-name (my-codex-current-buffer-name agent)))
    (if (string-suffix-p "*" default-name)
        (concat (substring default-name 0 -1) ":" safe-name "*")
      (format "%s:%s" default-name safe-name))))


(defun my-codex--session-buffer-live-p (buffer)
  "Return non-nil when BUFFER has a live process."
  (when-let ((process (and (buffer-live-p buffer)
                           (get-buffer-process buffer))))
    (process-live-p process)))

(defun my-codex--project-session-buffer-p (buffer root)
  "Return non-nil when BUFFER is an agent session for ROOT."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (and (bound-and-true-p my-codex-session-id)
              (equal my-codex-session-project-root
                     (file-name-as-directory
                      (file-truename root)))))))

(defun my-codex--session-buffer-for-window (window root)
  "Return WINDOW's project session buffer for ROOT, if any."
  (when (window-live-p window)
    (or (when-let ((buffer (window-parameter window 'my-codex-term-buffer)))
          (when (my-codex--project-session-buffer-p buffer root)
            buffer))
        (let ((buffer (window-buffer window)))
          (when (my-codex--project-session-buffer-p buffer root)
            buffer)))))

(defun my-codex--project-active-session-buffer (root)
  "Return the explicitly active session buffer for ROOT, if valid."
  (let* ((key (my-codex--project-key root))
         (buffer (gethash key my-codex--project-active-sessions)))
    (if (and buffer (my-codex--project-session-buffer-p buffer root))
        buffer
      (when buffer
        (remhash key my-codex--project-active-sessions))
      nil)))

(defun my-codex--transient-session-buffer (root)
  "Return the current transient's captured session buffer for ROOT."
  (when (fboundp 'transient-scope)
    (let ((buffer (ignore-errors (transient-scope))))
      (when (and (bufferp buffer)
                 (my-codex--project-session-buffer-p buffer root))
        buffer))))

(defun my-codex-active-session-buffer (&optional require-live)
  "Return the active agent session buffer.
When REQUIRE-LIVE is non-nil, require the returned buffer to have a live
process."
  (let* ((root (my-codex-project-root))
         (buffer
          (or (my-codex--transient-session-buffer root)
              (my-codex--session-buffer-for-window (selected-window) root)
              (my-codex--project-active-session-buffer root)
              (my-codex--session-buffer))))
    (when (and require-live
               (not (my-codex--session-buffer-live-p buffer)))
      (if (buffer-live-p buffer)
          (user-error "No running agent process in %s" (buffer-name buffer))
        (user-error "No agent session available")))
    buffer))

(defun my-codex--transient-target-description ()
  "Return the target heading for the current transient."
  (let ((buffer (ignore-errors (my-codex-active-session-buffer))))
    (if (buffer-live-p buffer)
        (with-current-buffer buffer
          (format "Target: %s · %s · %s"
                  (my-codex--agent-label
                   (or my-codex-session-agent (my-codex--active-agent)))
                  (or my-codex-session-name "default")
                  (or my-codex-session-access-mode 'unknown)))
      "Target: unavailable")))

(defun my-codex-active-session-window ()
  "Return the visible window for the active agent session."
  (let ((buffer (my-codex-active-session-buffer)))
    (or (get-buffer-window buffer)
        (user-error "No visible agent window in selected frame"))))

(defun my-codex--process-output-lines (program &rest args)
  "Return PROGRAM output lines for ARGS, or nil when PROGRAM fails."
  (with-temp-buffer
    (when (eq 0 (apply #'process-file program nil t nil args))
      (split-string (string-trim-right (buffer-string)) "\n" t))))

(defun my-codex--process-output-result (program &rest args)
  "Run PROGRAM with ARGS and return (STATUS . LINES).

STATUS is an integer exit status, a signal description string, or the
symbol `file-error' when the process cannot be started.  LINES contains
all non-empty output lines."
  (with-temp-buffer
    (condition-case nil
        (let ((status (apply #'process-file program nil t nil args)))
          (cons status
                (split-string (string-trim-right (buffer-string)) "\n" t)))
      (file-error
       (cons 'file-error nil)))))


(defun my-codex--session-export-buffer-name (root)
  "Return the session export buffer name for ROOT."
  (format "*%s session export:%s*"
          (my-codex--active-agent-label root)
          (my-codex--safe-root-name root)))

(defun my-codex--session-summary-buffer-name (root)
  "Return the session summary buffer name for ROOT."
  (format "*%s session summary:%s*"
          (my-codex--active-agent-label root)
          (my-codex--safe-root-name root)))

(defun my-codex--unique-output-markers (name)
  "Return unique begin and end output markers for NAME."
  (let ((suffix (substring
                 (secure-hash
                  'sha1
                  (format "%s-%s-%s" name (float-time) (random)))
                 0 12)))
    (cons (format "BEGIN_%s_%s" name suffix)
          (format "END_%s_%s" name suffix))))

(defun my-codex--marked-output-instructions (begin-marker end-marker placeholder)
  "Return prompt instructions for marked output.
BEGIN-MARKER and END-MARKER delimit the output.  PLACEHOLDER is
shown between them as an example."
  (format "Put only the final answer between these exact markers:\n\n%s\n%s\n%s"
          begin-marker
          placeholder
          end-marker))

(defun my-codex--terminal-marker-regexp (marker)
  "Return a regexp matching MARKER with terminal whitespace artefacts."
  (mapconcat
   (lambda (char)
     (regexp-quote (char-to-string char)))
   marker
   "[[:space:]\r\n]*"))

(defun my-codex--trim-blank-lines (text)
  "Return TEXT without leading or trailing blank lines."
  (setq text (replace-regexp-in-string "\\`[ \t\n]*\n" "" text))
  (setq text (replace-regexp-in-string "\n[ \t\n]*\\'" "" text))
  text)

(defun my-codex--common-leading-whitespace-width (text)
  "Return the common leading whitespace width among nonblank lines in TEXT."
  (let (width)
    (dolist (line (split-string text "\n"))
      (unless (string-blank-p line)
        (let ((line-width
               (if (string-match "\\`[ \t]*" line)
                   (length (match-string 0 line))
                 0)))
          (setq width
                (if width
                    (min width line-width)
                  line-width)))))
    (or width 0)))

(defun my-codex--remove-leading-whitespace-width (text width)
  "Return TEXT with WIDTH leading whitespace characters removed per line."
  (if (<= width 0)
      text
    (mapconcat
     (lambda (line)
       (if (string-blank-p line)
           ""
         (replace-regexp-in-string
          (format "\\`[ \t]\\{0,%d\\}" width)
          ""
          line
          nil
          nil)))
     (split-string text "\n")
     "\n")))

(defun my-codex--normalize-marked-output (text)
  "Return generated marked output TEXT without terminal layout indentation."
  (let ((output (my-codex--trim-blank-lines
                 (replace-regexp-in-string "\r" "" text))))
    (my-codex--remove-leading-whitespace-width
     output
     (my-codex--common-leading-whitespace-width output))))

(defun my-codex--latest-marked-output-after
    (buffer start-point begin-marker end-marker &optional ignored-values)
  "Return marked output in BUFFER after START-POINT, or nil.
BEGIN-MARKER and END-MARKER delimit the generated output.  Ignore
empty output and any exact string in IGNORED-VALUES."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (save-restriction
        (widen)
        (save-excursion
          (goto-char (point-max))
          (let* ((valid-start-point-p
                  (and start-point
                       (integer-or-marker-p start-point)
                       (or (not (markerp start-point))
                           (eq (marker-buffer start-point) buffer))
                       (<= (point-min) start-point)
                       (< start-point (point))))
                 (bound (when valid-start-point-p start-point)))
            (when (or (null start-point) bound)
              (when (re-search-backward
                     (my-codex--terminal-marker-regexp begin-marker)
                     bound t)
                (let ((marker-beg (match-beginning 0))
                      (beg (match-end 0)))
                  (when (re-search-forward
                         (my-codex--terminal-marker-regexp end-marker)
                         nil t)
                    (when (or (null bound) (>= marker-beg bound))
                      (let ((output
                             (my-codex--normalize-marked-output
                              (buffer-substring-no-properties
                               beg
                               (match-beginning 0)))))
                        (unless (member output
                                        (append '("") ignored-values))
                          output)))))))))))))

(defun my-codex--clear-marker (marker)
  "Detach MARKER from its buffer when MARKER is a marker."
  (when (markerp marker)
    (set-marker marker nil)))

(defun my-codex--clear-buffer-local-timer (buffer timer-var)
  "Cancel and clear TIMER-VAR in BUFFER when it names a timer."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (timerp (symbol-value timer-var))
        (cancel-timer (symbol-value timer-var)))
      (set timer-var nil))))

(defun my-codex--wait-for-marked-output
    (buffer start-point begin-marker end-marker callback timeout-message
            ready-message poll-interval poll-attempts &optional
            ignored-values attempts timer-var)
  "Poll BUFFER after START-POINT for marked output, then run CALLBACK.
BEGIN-MARKER and END-MARKER delimit the output.  CALLBACK receives
the extracted text.  ATTEMPTS tracks polling cycles."
  (let ((attempts (or attempts 0))
        (output (my-codex--latest-marked-output-after
                 buffer start-point begin-marker end-marker ignored-values)))
    (cond
     (output
      (my-codex--clear-marker start-point)
      (when timer-var
        (my-codex--clear-buffer-local-timer buffer timer-var))
      (funcall callback output)
      (message "%s" ready-message))
     ((>= attempts poll-attempts)
      (my-codex--clear-marker start-point)
      (when timer-var
        (my-codex--clear-buffer-local-timer buffer timer-var))
      (message "%s" timeout-message))
     (t
      (let ((timer
             (run-with-timer
              poll-interval nil
              #'my-codex--wait-for-marked-output
              buffer start-point begin-marker end-marker callback timeout-message
              ready-message poll-interval poll-attempts ignored-values
              (1+ attempts) timer-var)))
        (when (and timer-var (buffer-live-p buffer))
          (with-current-buffer buffer
            (set timer-var timer))))))))

(defun my-codex--strip-terminal-control-codes (text)
  "Return TEXT without common terminal control codes."
  (let ((cleaned (ansi-color-filter-apply text)))
    (setq cleaned
          (replace-regexp-in-string
           "\x1b\\][^\a\x1b]*\\(\a\\|\x1b\\\\\\)" "" cleaned))
    (setq cleaned
          (replace-regexp-in-string
           "\x1b\\[[0-?]*[ -/]*[@-~]" "" cleaned))
    (setq cleaned
          (replace-regexp-in-string "\r" "" cleaned))
    cleaned))

(defun my-codex--clean-session-transcript (text)
  "Return cleaned agent session transcript TEXT."
  (with-temp-buffer
    (insert (my-codex--strip-terminal-control-codes text))
    (goto-char (point-min))
    (while (re-search-forward "[[:blank:]]+$" nil t)
      (replace-match ""))
    (goto-char (point-min))
    (while (re-search-forward "\n\\{4,\\}" nil t)
      (replace-match "\n\n\n"))
    (string-trim (buffer-string))))

(defun my-codex--delete-temp-file (file)
  "Delete temporary FILE, reporting cleanup failures as messages."
  (when file
    (with-demoted-errors "Failed to delete temporary file: %S"
      (delete-file file))))

(defun my-codex--process-result (process)
  "Return (STATUS . BUFFER) when PROCESS has finished, or nil otherwise."
  (when (memq (process-status process) '(exit signal))
    (cons (process-exit-status process) (process-buffer process))))

(defun my-codex-buffer ()
  "Return the current project's agent backend buffer, or raise an error."
  (let* ((backend (my-codex--current-backend))
         (buffer-name (my-codex--backend-buffer-name backend))
         (buffer (get-buffer buffer-name)))
    (unless buffer
      (user-error "No %s buffer found" buffer-name))
    (unless (my-codex-backend-live-p backend)
      (user-error "No running %s process in %s"
                  (my-codex--active-agent-label)
                  buffer-name))
    buffer))

(defun my-codex--session-buffer ()
  "Return the current project's agent session buffer, or raise an error."
  (let* ((buffer-name (my-codex-current-buffer-name))
         (buffer (get-buffer buffer-name)))
    (unless buffer
      (user-error "No %s buffer found" buffer-name))
    buffer))

(defun my-codex-session-transcript ()
  "Return the cleaned transcript from the current project's agent buffer."
  (let ((buffer (my-codex-active-session-buffer)))
    (with-current-buffer buffer
      (my-codex--clean-session-transcript
       (buffer-substring-no-properties (point-min) (point-max))))))

(defun my-codex--session-export-mode ()
  "Use a suitable mode for a session export buffer."
  (if (require 'markdown-mode nil t)
      (markdown-mode)
    (text-mode)))

(defun my-codex--markdown-code-fence (text)
  "Return a Markdown code fence delimiter that does not occur in TEXT."
  (let ((max-length 2)
        (start 0))
    (while (string-match "`+" text start)
      (setq max-length (max max-length
                            (- (match-end 0) (match-beginning 0)))
            start (match-end 0)))
    (make-string (1+ max-length) ?`)))

(defun my-codex--insert-session-export-markdown (transcript root source-buffer)
  "Insert Markdown for TRANSCRIPT from ROOT and SOURCE-BUFFER."
  (let ((fence (my-codex--markdown-code-fence transcript)))
    (insert (format "# %s Session\n\n" (my-codex--active-agent-label root)))
    (insert (format "- Project root: `%s`\n" root))
    (insert (format "- Source buffer: `%s`\n" source-buffer))
    (insert (format "- Exported: `%s`\n\n"
                    (format-time-string "%Y-%m-%d %H:%M:%S %Z")))
    (insert "## Transcript\n\n")
    (insert fence "text\n")
    (insert transcript)
    (insert "\n" fence "\n")))

(provide 'my-codex-core)

;;; my-codex-core.el ends here
