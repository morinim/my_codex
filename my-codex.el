;;; my-codex.el --- Codex integration -*- lexical-binding: t; -*-

(require 'seq)
(require 'project)
(require 'vterm)
(require 'compile)
(require 'easymenu)

(defgroup my-codex nil
  "Customisation options for the Codex development tool."
  :group 'convenience
  :prefix "my/codex-")

(defcustom my/codex-buffer-name "*codex*"
  "Name of the vterm buffer used for Codex."
  :type 'string
  :group 'my-codex)

(defcustom my/codex-read-only-command
  "codex --sandbox read-only --ask-for-approval on-request"
  "Command used to start Codex in read-only mode."
  :type 'string
  :group 'my-codex)

(defcustom my/codex-workspace-command
  "codex --sandbox workspace-write --ask-for-approval on-request"
  "Command used to start Codex with workspace write access."
  :type 'string
  :group 'my-codex)

(defcustom my/codex-resume-command
  "codex resume"
  "Command used to resume a previous Codex session."
  :type 'string
  :group 'my-codex)

(defcustom my/codex-left-width 80
  "Width of the editing window in the Codex two-column layout."
  :type 'natnum
  :group 'my-codex)

(defcustom my/codex-min-right-width 80
  "Minimum width of the Codex vterm window."
  :type 'natnum
  :group 'my-codex)

(defcustom my/codex-project-instruction-files
  '("AGENTS.md" "CODEX.md" ".codex/instructions.md")
  "Candidate project instruction files for Codex."
  :type '(repeat string)
  :group 'my-codex)

(defcustom my/codex-project-build-command "./setup_build"
  "Command used to build the current project."
  :type 'string
  :group 'my-codex)

(defun my/codex-project-root ()
  "Return the current project root, or `default-directory' if not in a project."
  (if-let ((project (project-current)))
      (project-root project)
    default-directory))

(defun my/codex-two-column-layout-with-command (codex-command)
  "Open a two-column layout and run CODEX-COMMAND in vterm if not running."
  (let ((root (my/codex-project-root)))
    ;; Defer the entire layout engine to ensure the GUI menu loop has finished collapsing
    (run-at-time
     0 nil
     (lambda (cmd root-dir)
       (let ((required-width (+ my/codex-left-width my/codex-min-right-width))
             (existing-buf (get-buffer my/codex-buffer-name))
             (default-directory root-dir))

         (when (< (frame-width) required-width)
           (set-frame-width (selected-frame) required-width)
           (redisplay t))

         (when (< (frame-width) required-width)
           (user-error "Frame is too narrow: need at least %d columns" required-width))

         (when (and existing-buf
                    (not (get-buffer-process existing-buf)))
           (kill-buffer existing-buf)
           (setq existing-buf nil))

         (delete-other-windows)

         (let ((edit-window (selected-window))
               (term-window (condition-case nil
                                (split-window-right my/codex-left-width)
                              (error (split-window-right)))))
           (select-window term-window)

           (if (and existing-buf (get-buffer-process existing-buf))
               (switch-to-buffer existing-buf)
             (let ((buffer (vterm my/codex-buffer-name)))
               (with-current-buffer buffer
                 (goto-char (point-max))
                 (vterm-send-string cmd)
                 (vterm-send-return))))

           (select-window edit-window))))
     codex-command root)))

(defun my/codex-read-only ()
  "Show Codex, starting it in read-only mode if needed."
  (interactive)
  (my/codex-two-column-layout-with-command my/codex-read-only-command))

(defun my/codex-workspace ()
  "Show Codex, starting it with workspace write access if needed."
  (interactive)
  (my/codex-two-column-layout-with-command my/codex-workspace-command))

(defun my/codex-resume ()
  "Show Codex, resuming a previous session if needed."
  (interactive)
  (my/codex-two-column-layout-with-command my/codex-resume-command))

(defun my/codex-buffer ()
  "Return the Codex vterm buffer, or raise an error."
  (let ((buffer (get-buffer my/codex-buffer-name)))
    (unless buffer
      (user-error "No %s buffer found" my/codex-buffer-name))
    (unless (get-buffer-process buffer)
      (user-error "No running Codex process in %s" my/codex-buffer-name))
    buffer))

(defun my/codex-send-prompt (prompt)
  "Send PROMPT to the Codex vterm buffer and show it."
  (let ((buffer (my/codex-buffer)))
    ;; Defer layout switching and string insertion outside of the menu evaluation frame
    (run-at-time
     0 nil
     (lambda (buf str)
       (when (buffer-live-p buf)
         (if-let ((window (get-buffer-window buf t)))
             (select-window window)
           (pop-to-buffer buf))
         (redisplay t)
         (with-current-buffer buf
           (goto-char (point-max))
           (vterm-send-string str)
           (vterm-send-return))))
     buffer prompt)))

(defun my/codex-send-region (beg end)
  "Send the selected region to the Codex vterm buffer."
  (interactive "r")
  (unless (use-region-p)
    (user-error "No active region"))
  (my/codex-send-prompt
   (format "Please review this code and report findings:\n\n%s"
           (buffer-substring-no-properties beg end))))

(defun my/save-current-buffer-if-file ()
  "Save the current file-visiting buffer if it has unsaved changes."
  (when (and buffer-file-name (buffer-modified-p))
    (save-buffer)))

(defun my/codex-send-current-file ()
  "Ask Codex to inspect the current file directly, saving modifications first."
  (interactive)
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a file"))

  (my/save-current-buffer-if-file)

  (let* ((root (my/codex-project-root))
         (file (file-relative-name buffer-file-name root)))
    (my/codex-send-prompt
     (format "Please inspect `%s` directly and report findings. Do not edit it unless I explicitly ask.\n"
             file))))

(defun my/git-repository-p ()
  "Return non-nil if `default-directory' is inside a Git repository."
  (and (executable-find "git")
       (with-temp-buffer
         (zerop (call-process "git" nil t nil "rev-parse" "--is-inside-work-tree")))))

(defun my/ensure-git-repository ()
  "Raise an error unless `default-directory' is inside a Git repository."
  (unless (executable-find "git")
    (user-error "Git executable not found"))
  (unless (my/git-repository-p)
    (user-error "Not inside a Git repository")))

(defun my/codex-send-git-diff ()
  "Ask Codex to review the current Git diff."
  (interactive)
  (let ((default-directory (my/codex-project-root)))
    (my/ensure-git-repository)
    (my/codex-send-prompt
     "Please review the current Git diff using `git diff -- .`. Focus on correctness, regressions, edge cases, naming, and maintainability. Do not edit files unless I explicitly ask.\n")))

(defun my/codex-send-git-staged-diff ()
  "Ask Codex to review the staged Git diff."
  (interactive)
  (let ((default-directory (my/codex-project-root)))
    (my/ensure-git-repository)
    (my/codex-send-prompt
     "Please review the staged Git diff using `git diff --cached -- .`. Focus on correctness, regressions, edge cases, and commit readiness. Do not edit files unless I explicitly ask.\n")))

(defun my/codex-commit-message-from-diff ()
  "Ask Codex to draft a commit message from the staged Git diff."
  (interactive)
  (let ((default-directory (my/codex-project-root)))
    (my/ensure-git-repository)
    (my/codex-send-prompt
     "Please inspect the staged Git diff using `git diff --cached -- .` and write a concise but comprehensive conventional commit message. Use an imperative subject and a short explanatory body when useful. Do not edit files.\n")))

(defun my/codex-explain-region-as-error ()
  "Ask Codex to explain the selected compiler or test error."
  (interactive)
  (unless (use-region-p)
    (user-error "No active region"))
  (my/codex-send-prompt
   (format "Please explain this compiler/test error and suggest the most likely fix:\n\n%s"
           (buffer-substring-no-properties
            (region-beginning)
            (region-end)))))

(defun my/codex-open-project-instructions ()
  "Open the project Codex/agent instruction file, if present."
  (interactive)
  (let* ((root (my/codex-project-root))
         (file (seq-find
                (lambda (name)
                  (file-exists-p (expand-file-name name root)))
                my/codex-project-instruction-files)))
    (if file
        (find-file (expand-file-name file root))
      (user-error "No project instruction file found"))))

(defun my/codex-help ()
  "Show Codex key bindings."
  (interactive)
  (message
   "Codex: F7=build, F8 o=show/start read-only, w=show/start workspace, r=resume, s=send region, f=file, g=diff, G=staged diff, m=commit message, e=explain error, i=instructions, ?=help"))

(define-prefix-command 'my/codex-map)
(global-set-key (kbd "<f8>") 'my/codex-map)

(define-key my/codex-map (kbd "o") #'my/codex-read-only)
(define-key my/codex-map (kbd "w") #'my/codex-workspace)
(define-key my/codex-map (kbd "r") #'my/codex-resume)
(define-key my/codex-map (kbd "s") #'my/codex-send-region)
(define-key my/codex-map (kbd "f") #'my/codex-send-current-file)
(define-key my/codex-map (kbd "g") #'my/codex-send-git-diff)
(define-key my/codex-map (kbd "G") #'my/codex-send-git-staged-diff)
(define-key my/codex-map (kbd "m") #'my/codex-commit-message-from-diff)
(define-key my/codex-map (kbd "e") #'my/codex-explain-region-as-error)
(define-key my/codex-map (kbd "i") #'my/codex-open-project-instructions)
(define-key my/codex-map (kbd "?") #'my/codex-help)

(defun my/codex-project-build ()
  "Run the project build command with `compile'."
  (interactive)
  (let ((default-directory (my/codex-project-root)))
    (compile my/codex-project-build-command)))

(global-set-key (kbd "<f7>") #'my/codex-project-build)

(easy-menu-define my/codex-menu nil
  "Menu for Codex commands."
  '("Codex"
    ["Show/start read-only" my/codex-read-only
     :help "Show Codex, starting it in read-only mode if needed"]
    ["Show/start workspace-write" my/codex-workspace
     :help "Show Codex, starting it with workspace write access if needed"]
    ["Resume session" my/codex-resume
     :help "Resume a previous Codex session"]
    "---"
    ["Send selected region" my/codex-send-region
     :active (use-region-p)
     :help "Send the selected region to Codex"]
    ["Explain selected error" my/codex-explain-region-as-error
     :active (use-region-p)
     :help "Ask Codex to explain the selected compiler/test error"]
    ["Inspect current file" my/codex-send-current-file
     :active buffer-file-name
     :help "Ask Codex to inspect the current file directly"]
    "---"
    ["Review Git diff" my/codex-send-git-diff
     :help "Ask Codex to review the current Git diff"]
    ["Review staged Git diff" my/codex-send-git-staged-diff
     :help "Ask Codex to review the staged Git diff"]
    ["Draft commit message" my/codex-commit-message-from-diff
     :help "Ask Codex to draft a commit message from the staged Git diff"]
    "---"
    ["Open project instructions" my/codex-open-project-instructions
     :help "Open AGENTS.md, CODEX.md, or .codex/instructions.md"]
    ["Show key bindings" my/codex-help
     :help "Show Codex key bindings"]
    "---"
    ["Compile project" my/codex-project-build
     :help "Run the project build command"]))

(easy-menu-add-item nil '("Tools") my/codex-menu)

(provide 'my-codex)

;;; my-codex.el ends here
