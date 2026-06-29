;;; my-codex-prompts.el --- Prompt and context helpers for my-codex -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Manlio Morini

;; This file is not part of GNU Emacs.

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at https://mozilla.org/MPL/2.0/.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'thingatpt)
(require 'transient)
(require 'xref)
(require 'my-codex-core)

(defvar my-codex--captured-selection)
(defvar my-codex--prompt-preview-origin-window)
(defvar-local my-codex--prompt-preview-target-buffer nil
  "Agent session buffer targeted by the current prompt preview.")
(defvar-local my-codex--prompt-preview-sent-message nil
  "Message to display after sending the current prompt preview.")
(defvar my-codex--region-send-override nil
  "Dynamically override region delivery with `reference' or `inline'.")
(defcustom my-codex-test-coverage-prompt
  "Analyse test coverage for this implementation and its test file.

Identify missing edge cases, unhandled exceptions, logical flaws and important behaviour that is not currently tested. Do not edit or write tests; list missing scenarios only."
  "Prompt used by `my-codex-analyse-test-coverage'."
  :type 'string
  :group 'my-codex)

(defcustom my-codex-refactor-plan-prompt
  "Draft a step-by-step, low-risk refactoring plan for this code.

Do not provide rewritten code or patches.

Focus on:
- current responsibilities and likely coupling
- small refactoring steps in a safe order
- potential breaking changes
- tests or checks to run after each step
- rollback points
- assumptions that need confirmation before editing

Finish with the smallest safe first edit worth making."
  "Prompt used by `my-codex-plan-refactor-region'."
  :type 'string
  :group 'my-codex)

(defcustom my-codex-enable-prompt-preview nil
  "When non-nil, show an editable preview before sending prompts."
  :type 'boolean
  :group 'my-codex)

(defcustom my-codex-prompt-warning-tokens 4000
  "Approximate prompt size in tokens that requires confirmation before sending.
When nil, do not warn about large prompts."
  :type '(choice (const :tag "Do not warn" nil)
                 natnum)
  :group 'my-codex)

(defcustom my-codex-prompt-error-tokens nil
  "Approximate prompt size in tokens that is refused before sending.
When nil, do not enforce a hard prompt size limit."
  :type '(choice (const :tag "No hard limit" nil)
                 natnum)
  :group 'my-codex)

(defcustom my-codex-region-send-policy 'prefer-reference
  "How selected regions are sent to the agent.
When `prefer-reference', send a file reference whenever the selected
region can be read safely from a saved project file, falling back to
inline text otherwise.  When `automatic', use
`my-codex-region-reference-threshold-chars'.  When `prefer-inline',
send selected text inline."
  :type '(choice (const :tag "Prefer file references" prefer-reference)
                 (const :tag "Automatic by size" automatic)
                 (const :tag "Prefer inline text" prefer-inline))
  :group 'my-codex)

(defcustom my-codex-region-reference-threshold-chars 5000
  "Region size in characters that sends a file reference instead of text.
This only applies when `my-codex-region-send-policy' is `automatic',
and only to file-visiting buffers.  When nil, automatic mode always
sends selected region text from `my-codex-send-region'."
  :type '(choice (const :tag "Always send selected text" nil)
                 natnum)
  :group 'my-codex)

(defcustom my-codex-symbol-context-lines 5
  "Number of surrounding lines to include for modified symbol buffers."
  :type 'natnum
  :group 'my-codex)

(defcustom my-codex-symbol-include-xref-context t
  "When non-nil, include xref definition and reference locations for symbols."
  :type 'boolean
  :group 'my-codex)

(defcustom my-codex-symbol-xref-definition-limit 1
  "Maximum number of xref definitions to include for symbol explanations."
  :type 'natnum
  :group 'my-codex)

(defcustom my-codex-symbol-xref-reference-limit 3
  "Maximum number of xref references to include for symbol explanations."
  :type 'natnum
  :group 'my-codex)

(defcustom my-codex-symbol-xref-context-lines 1
  "Number of surrounding lines to include for each modified xref buffer."
  :type 'natnum
  :group 'my-codex)

(defcustom my-codex-prompt-presets
  '(("Refactor" . "Review the following code and refactor it to improve readability and performance without changing its external behaviour.")
    ("Document" . "Write clear docstrings and comments for the following code. Avoid over-commenting obvious logic.")
    ("Test" . "Write focused unit tests for the following code.")
    ("Explain" . "Explain the following code clearly and concisely."))
  "Prompt presets offered by `my-codex-ask-with-preset'.
Each entry is a cons cell of the form (NAME . PROMPT)."
  :type '(alist :key-type string :value-type string)
  :group 'my-codex)

(defcustom my-codex-session-summary-prompt
  "Summarise our conversation so far into useful project notes.

Focus on:
- decisions made
- open questions
- action items
- proposed implementation details
- risks or constraints

Preserve concrete file names, command names, and technical details. Do not edit files."
  "Prompt used by `my-codex-summarize-session-to-markdown'."
  :type 'string
  :group 'my-codex)

(declare-function my-codex--project-files "my-codex-git" (root))
(defface my-codex-prompt-preview-reference-face
  '((t :inherit font-lock-constant-face))
  "Face used for references in prompt preview buffers.")

(defface my-codex-prompt-preview-embedded-face
  '((t :inherit font-lock-doc-face))
  "Face used for embedded text in prompt preview buffers.")

(defun my-codex-edit-session-summary (summary root)
  "Open an editable Markdown buffer with agent session SUMMARY from ROOT."
  (let ((buffer (get-buffer-create (my-codex--session-summary-buffer-name root))))
    (pop-to-buffer buffer)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (string-trim summary))
      (goto-char (point-min)))
    (setq default-directory root)
    (my-codex--session-export-mode)
    (setq-local header-line-format "Edit agent session summary Markdown.")
    (message "%s session summary is ready for editing."
             (my-codex--active-agent-label root))))

(defun my-codex--approx-token-count (text)
  "Estimate tokens in TEXT from its byte size."
  (ceiling (/ (float (string-bytes text)) 3.2)))

(defun my-codex--prompt-size-description (prompt)
  "Return a short human-readable size description for PROMPT."
  (format "%d chars; outbound prompt text: approximately %d tokens"
          (length prompt)
          (my-codex--approx-token-count prompt)))

(defun my-codex--prompt-target-buffer (&optional window noerror)
  "Return the agent session buffer targeted from WINDOW.
When NOERROR is non-nil, return nil instead of raising if no default
session is available."
  (if noerror
      (ignore-errors
        (with-selected-window (or window (selected-window))
          (my-codex-active-session-buffer)))
    (with-selected-window (or window (selected-window))
      (my-codex-active-session-buffer))))

(defun my-codex--prompt-target-description (&optional buffer)
  "Return a concise prompt target description for BUFFER."
  (let ((buffer (or buffer my-codex--prompt-preview-target-buffer)))
    (if (buffer-live-p buffer)
        (with-current-buffer buffer
          (let* ((agent (or my-codex-session-agent (my-codex--active-agent)))
                 (session (or my-codex-session-name "default"))
                 (access (or my-codex-session-access-mode 'unknown)))
            (format "%s / %s / %s"
                    (my-codex--agent-label agent)
                    session
                    (my-codex--access-mode-label access t))))
      (format "%s / default" (my-codex--active-agent-label)))))

(defun my-codex--ask-prompt-label ()
  "Return the minibuffer label for `my-codex-ask'."
  (if-let (buffer (my-codex--prompt-target-buffer (selected-window) t))
      (with-current-buffer buffer
        (format "%s [%s/%s]"
                (my-codex--agent-label
                 (or my-codex-session-agent (my-codex--active-agent)))
                (or my-codex-session-name "default")
                (my-codex--access-mode-label
                 (or my-codex-session-access-mode 'unknown) t)))
    (my-codex--active-agent-label)))

(defun my-codex--prompt-preview-header (prompt &optional target-buffer)
  "Return the prompt preview header line for PROMPT."
  (format (concat "Target: %s. Size: %s. Edit if needed; "
                  "C-c C-c sends to agent, C-c C-k cancels.")
          (my-codex--prompt-target-description target-buffer)
          (my-codex--prompt-size-description prompt)))

(defun my-codex--update-prompt-preview-header (&rest _)
  "Update the current prompt preview header from buffer contents."
  (setq-local header-line-format
              (my-codex--prompt-preview-header
               (buffer-string)
               my-codex--prompt-preview-target-buffer)))

(defun my-codex--prompt-preview-literal-block-matcher (limit)
  "Match YAML literal block bodies before LIMIT in prompt previews."
  (let (match)
    (while (and (not match)
                (re-search-forward "^[[:space:]]*[[:alnum:]_]+: |[[:space:]]*$"
                                   limit t))
      (let* ((indent (save-excursion
                       (goto-char (match-beginning 0))
                       (current-indentation)))
             (start (progn
                      (forward-line 1)
                      (point)))
             (end start))
        (while (and (< (point) limit)
                    (not (eobp))
                    (or (looking-at-p "^[[:space:]]*$")
                        (> (current-indentation) indent)))
          (forward-line 1)
          (setq end (point)))
        (when (> end start)
          (set-match-data (list start end))
          (setq match t))))
    match))

(defun my-codex--prompt-preview-embedded-tail-matcher (limit)
  "Match common embedded prompt payload tails before LIMIT."
  (when (re-search-forward
         (regexp-opt
          '("Review this code and report findings:"
            "Explain this compiler/test error and suggest the most likely fix:"))
         limit t)
    (let ((start (progn
                   (forward-line 1)
                   (if (looking-at-p "^[[:space:]]*$")
                       (progn
                         (forward-line 1)
                         (point))
                     (point))))
          (end limit))
      (when (> end start)
        (set-match-data (list start end))
        t))))

(defun my-codex--setup-prompt-preview-font-lock ()
  "Highlight references and embedded text in the current prompt preview."
  (setq-local font-lock-defaults
              '(((my-codex--prompt-preview-literal-block-matcher
                  . 'my-codex-prompt-preview-embedded-face)
                 (my-codex--prompt-preview-embedded-tail-matcher
                  . 'my-codex-prompt-preview-embedded-face)
                 ("^@[[:graph:]]+ lines [0-9]+-[0-9]+$"
                  . 'my-codex-prompt-preview-reference-face)
                 ("^[[:space:]]*\\(?:- +\\)?location: \"?\\([^\"\n]+\\)\"?[[:space:]]*$"
                  1 'my-codex-prompt-preview-reference-face)))))

(defun my-codex--check-prompt-size (prompt)
  "Raise or ask for confirmation when PROMPT is unusually large."
  (let ((tokens (my-codex--approx-token-count prompt)))
    (when (and my-codex-prompt-error-tokens
               (> tokens my-codex-prompt-error-tokens))
      (user-error "Prompt is too large to send (%s; limit is approx. %d tokens)"
                  (my-codex--prompt-size-description prompt)
                  my-codex-prompt-error-tokens))
    (when (and my-codex-prompt-warning-tokens
               (> tokens my-codex-prompt-warning-tokens)
               (not (y-or-n-p
                     (format "Send large %s prompt (%s)? "
                             (my-codex--active-agent-label)
                             (my-codex--prompt-size-description prompt)))))
      (user-error "%s prompt cancelled" (my-codex--active-agent-label)))))

(defun my-codex-send-prompt (prompt &optional target-buffer)
  "Send PROMPT to the agent backend buffer and show it."
  (my-codex--warn-about-unsaved-project-buffers)
  (my-codex--check-prompt-size prompt)
  (let* ((buffer (or target-buffer (my-codex-active-session-buffer t)))
         (backend (my-codex--backend-for-buffer-name (buffer-name buffer))))
    (unless (and (buffer-live-p buffer)
                 (my-codex-backend-live-p backend))
      (user-error "No running agent process in %s" (buffer-name buffer)))
    (if-let (window (get-buffer-window buffer t))
        (select-window window)
      (pop-to-buffer buffer))
    (redisplay t)
    (my-codex-backend-send backend prompt)))

(cl-defun my-codex--request-marked-output
    (&key name buffer prompt placeholder parser callback timeout-message
          ready-message poll-interval poll-attempts ignored-values timer-var
          start-callback)
  "Send PROMPT and wait for uniquely marked output named NAME.
CALLBACK receives the parsed output.  START-CALLBACK receives the request
marker, begin marker and end marker before PROMPT is sent."
  (let* ((markers (my-codex--unique-output-markers name))
         (begin-marker (car markers))
         (end-marker (cdr markers))
         (start-point (with-current-buffer buffer
                        (copy-marker (point-max))))
         (ignored-values
          (append (list "..." placeholder) ignored-values)))
    (when timer-var
      (my-codex--clear-buffer-local-timer buffer timer-var))
    (when start-callback
      (funcall start-callback start-point begin-marker end-marker))
    (my-codex-send-prompt
     (format "%s\n\n%s"
             prompt
             (my-codex--marked-output-instructions
              begin-marker end-marker placeholder))
     buffer)
    (my-codex--wait-for-marked-output
     buffer start-point begin-marker end-marker
     (lambda (output)
       (funcall callback (funcall (or parser #'identity) output)))
     timeout-message ready-message poll-interval poll-attempts
     ignored-values nil timer-var)
    start-point))

(defun my-codex--prompt-preview-buffer-name (root)
  "Return the prompt preview buffer name for ROOT."
  (let* ((agent (my-codex--active-agent root))
         (label (my-codex--agent-label agent)))
    (format "*%s prompt preview:%s*" label (my-codex--safe-root-name root))))

(defun my-codex--display-prompt-preview-buffer (buffer origin-window)
  "Display prompt preview BUFFER, preferring ORIGIN-WINDOW."
  (if-let* ((origin-frame (and (window-live-p origin-window)
                               (window-frame origin-window)))
            (codex-window (get-buffer-window
                           (with-selected-window origin-window
                             (my-codex-active-session-buffer))
                           origin-frame))
            (preview-window
             (cond
              ((not (eq origin-window codex-window))
               origin-window)
              (t
               (seq-find
                (lambda (window)
                  (not (eq window codex-window)))
                (sort (window-list (window-frame codex-window) 'no-minibuf)
                      (lambda (a b)
                        (or (< (window-left-column a)
                               (window-left-column b))
                            (and (= (window-left-column a)
                                    (window-left-column b))
                                 (< (window-top-line a)
                                    (window-top-line b)))))))))))
      (progn
        (set-window-buffer preview-window buffer)
        (select-window preview-window))
    (pop-to-buffer buffer)))

(defun my-codex--finish-prompt-preview ()
  "Send the current prompt preview buffer contents to the agent."
  (interactive)
  (let ((prompt (string-trim-right
                 (buffer-substring-no-properties (point-min) (point-max))))
        (root default-directory)
        (buffer (current-buffer)))
    (when (string-blank-p prompt)
      (user-error "Prompt is empty"))
    (let ((default-directory root))
      (my-codex-send-prompt prompt my-codex--prompt-preview-target-buffer))
    (when my-codex--prompt-preview-sent-message
      (message "%s" my-codex--prompt-preview-sent-message))
    (when (buffer-live-p buffer)
      (kill-buffer buffer))))

(defun my-codex--cancel-prompt-preview ()
  "Cancel the current agent prompt preview buffer."
  (interactive)
  (let ((origin-window my-codex--prompt-preview-origin-window))
    (kill-buffer (current-buffer))
    (when (window-live-p origin-window)
      (select-window origin-window)))
  (message "Agent prompt cancelled."))

(defun my-codex--preview-and-send-prompt (prompt &optional sent-message)
  "Preview PROMPT before sending it to the agent when enabled.
Display SENT-MESSAGE after the prompt is sent."
  (let* ((root (my-codex-project-root))
         (origin-window (selected-window))
         (target-buffer (my-codex--prompt-target-buffer origin-window)))
    (if my-codex-enable-prompt-preview
        (let ((buffer (get-buffer-create
                       (my-codex--prompt-preview-buffer-name root))))
          (my-codex--display-prompt-preview-buffer buffer origin-window)
          (my-codex--prepare-edit-buffer
           prompt root #'text-mode nil
           #'my-codex--finish-prompt-preview
           #'my-codex--cancel-prompt-preview)
          (my-codex--setup-prompt-preview-font-lock)
          (font-lock-ensure)
          (setq-local my-codex--prompt-preview-origin-window origin-window)
          (setq-local my-codex--prompt-preview-target-buffer target-buffer)
          (setq-local my-codex--prompt-preview-sent-message sent-message)
          (my-codex--update-prompt-preview-header)
          (add-hook 'after-change-functions
                    #'my-codex--update-prompt-preview-header nil t)
          (message "%s prompt preview opened."
                   (my-codex--active-agent-label root)))
      (my-codex-send-prompt prompt target-buffer)
      (when sent-message
        (message "%s" sent-message)))))

;;;###autoload
(defun my-codex-send-region (beg end)
  "Send the region between BEG and END to the agent with exact file context."
  (interactive "r")
  (unless (use-region-p)
    (user-error "No active region"))
  (pcase-let ((`(,prompt . ,sent-message)
               (my-codex--region-review-request beg end)))
    (my-codex--preview-and-send-prompt prompt sent-message)))

(defun my-codex--defun-bounds-at-point ()
  "Return the bounds of the defun at point."
  (or (bounds-of-thing-at-point 'defun)
      (user-error "No defun at point")))

;;;###autoload
(defun my-codex-review-defun-at-point ()
  "Ask the agent to review the defun at point."
  (interactive)
  (pcase-let ((`(,beg . ,end) (my-codex--defun-bounds-at-point)))
    (pcase-let ((`(,prompt . ,sent-message)
                 (my-codex--region-review-request beg end)))
      (my-codex--preview-and-send-prompt prompt sent-message))))

;;;###autoload
(defun my-codex-send-current-file ()
  "Ask the agent to inspect the current file directly."
  (interactive)
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a file"))
  (let* ((root (my-codex-project-root))
         (file (my-codex--project-relative-file buffer-file-name root)))
    (my-codex--ensure-file-reference-current buffer-file-name)
    (unless file
      (user-error "Current file is outside the current project"))
    (my-codex--preview-and-send-prompt
     (format "Inspect `%s` directly and report findings. Do not edit unless asked\n"
             file))))

(defun my-codex--project-relative-file (file root)
  "Return FILE relative to ROOT, or nil when FILE is outside ROOT."
  (let ((truename (file-truename file))
        (root-truename (file-name-as-directory (file-truename root))))
    (when (file-in-directory-p truename root-truename)
      (file-relative-name truename root-truename))))

(defun my-codex--ensure-file-reference-current (file &optional label)
  "Raise when FILE is visited by a stale or modified buffer.
LABEL describes FILE in user-facing errors."
  (let ((buffer (find-buffer-visiting file))
        (label (or label "buffer")))
    (when buffer
      (with-current-buffer buffer
        (when (buffer-modified-p)
          (user-error "Save the %s before sending a file reference" label))
        (unless (verify-visited-file-modtime buffer)
          (user-error
           "%s changed on disk; revert or save before sending a file reference"
           (capitalize label)))))))

(defun my-codex--projectile-counterpart-file ()
  "Return Projectile's implementation/test counterpart for current file, or nil."
  (when (fboundp 'projectile-toggle-between-implementation-and-test)
    (let ((current-file (buffer-file-name)))
      (when current-file
        (save-window-excursion
          (save-current-buffer
            (condition-case nil
                (progn
                  (call-interactively
                   #'projectile-toggle-between-implementation-and-test)
                  (let ((candidate (buffer-file-name)))
                    (when (and candidate
                               (not (file-equal-p candidate current-file))
                               (file-readable-p candidate))
                      candidate)))
              (error nil))))))))

(defun my-codex--test-file-candidates (file root)
  "Return likely test file candidates for FILE under ROOT."
  (let* ((relative (file-relative-name file root))
         (directory (or (file-name-directory relative) ""))
         (basename (file-name-base relative))
         (extension (or (file-name-extension relative t) ""))
         (file-name (file-name-nondirectory relative))
         (without-src (if (string-prefix-p "src/" relative)
                          (substring relative 4)
                        relative))
         (dir-without-src (or (file-name-directory without-src) ""))
         (common
          (delq nil
                (list
                 (concat "test/" without-src)
                 (concat "tests/" without-src)
                 (concat "spec/" without-src)
                 (concat "test/" dir-without-src "test_" file-name)
                 (concat "tests/" dir-without-src "test_" file-name)
                 (concat "test/" dir-without-src basename "_test" extension)
                 (concat "tests/" dir-without-src basename "_test" extension)
                 (concat "spec/" dir-without-src basename "_spec" extension)
                 (concat directory basename "-test" extension)
                 (concat directory basename "_test" extension)
                 (concat directory basename ".test" extension)
                 (concat directory basename "-spec" extension)
                 (concat directory basename "_spec" extension)
                 (concat directory basename ".spec" extension))))
         (seen nil)
         (candidates nil))
    (dolist (candidate common (nreverse candidates))
      (unless (member candidate seen)
        (push candidate seen)
        (push (expand-file-name candidate root) candidates)))))

(defun my-codex--read-test-file (implementation-file root)
  "Read a test file for IMPLEMENTATION-FILE under ROOT."
  (let* ((root (file-name-as-directory (expand-file-name root)))
         (projectile-file (my-codex--projectile-counterpart-file))
         (projectile-file
          (when (and projectile-file
                     (file-in-directory-p (file-truename projectile-file)
                                          (file-truename root)))
            projectile-file))
         (candidates (append (when projectile-file (list projectile-file))
                             (my-codex--test-file-candidates
                              implementation-file root)))
         (existing (seq-filter #'file-readable-p candidates))
         (default (car existing))
         (file (expand-file-name
                (read-file-name "Test file: " root default t)
                root)))
    (unless (file-in-directory-p (file-truename file)
                                 (file-truename root))
      (user-error "Test file is outside the current project"))
    file))

(defun my-codex--prompt-target-agent ()
  "Return the agent profile targeted by the current prompt command."
  (if-let ((buffer (my-codex--prompt-target-buffer (selected-window) t)))
      (with-current-buffer buffer
        (or my-codex-session-agent (my-codex--active-agent)))
    (my-codex--active-agent)))

(defun my-codex--format-file-reference (file &optional agent)
  "Format project-relative FILE for AGENT.
Use the current prompt target's agent when AGENT is nil."
  (let* ((agent (or agent (my-codex--prompt-target-agent)))
         (format-string
          (or (plist-get (my-codex--agent-profile agent)
                         :file-reference-format)
              "%s")))
    (format format-string file)))

(defun my-codex--test-coverage-prompt (implementation-relative test-relative
                                                               &optional agent)
  "Return a cache-friendly coverage prompt.
IMPLEMENTATION-RELATIVE and TEST-RELATIVE are project-relative file names.
AGENT is the agent profile used to format their references."
  (string-join
   (list my-codex-test-coverage-prompt
         (format "context:\n  implementation: %s\n  test: %s"
                 (my-codex--format-file-reference implementation-relative agent)
                 (my-codex--format-file-reference test-relative agent))
         "request: Analyze test coverage now.")
   "\n\n"))

;;;###autoload
(defun my-codex-analyse-test-coverage ()
  "Ask the agent to analyse coverage of the current file by its test file."
  (interactive)
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a file"))
  (let* ((root (my-codex-project-root))
         (implementation-file buffer-file-name)
         (test-file (my-codex--read-test-file implementation-file root))
         (implementation-relative
          (my-codex--project-relative-file implementation-file root))
         (test-relative (my-codex--project-relative-file test-file root)))
    (my-codex--ensure-file-reference-current implementation-file
                                             "implementation file")
    (my-codex--ensure-file-reference-current test-file "test file")
    (unless implementation-relative
      (user-error "Implementation file is outside the current project"))
    (unless test-relative
      (user-error "Test file is outside the current project"))
    (my-codex--preview-and-send-prompt
     (my-codex--test-coverage-prompt
      implementation-relative
      test-relative))))

(defun my-codex--symbol-at-point ()
  "Return the symbol at point, or raise a user error."
  (let ((symbol (thing-at-point 'symbol t)))
    (if (and symbol (not (string-blank-p symbol)))
        symbol
      (user-error "No symbol at point"))))

(defun my-codex--trim-excerpt-whitespace (text)
  "Trim trailing whitespace and boundary blank lines from TEXT."
  (setq text (replace-regexp-in-string "[ \t]+$" "" text))
  (setq text (replace-regexp-in-string "\\`\\(?:\n\\)+" "" text))
  (replace-regexp-in-string "\\(?:\n\\)+\\'" "" text))

(defun my-codex--line-context-around-point (context-lines)
  "Return text around point spanning CONTEXT-LINES before and after."
  (save-excursion
    (save-restriction
      (widen)
      (let* ((line (line-number-at-pos))
             (start-line (max 1 (- line context-lines)))
             (end-line (+ line context-lines))
             start end)
        (goto-char (point-min))
        (forward-line (1- start-line))
        (setq start (line-beginning-position))
        (goto-char (point-min))
        (forward-line (1- end-line))
        (setq end (line-end-position))
        (my-codex--trim-excerpt-whitespace
         (buffer-substring-no-properties start end))))))

(defun my-codex--xref-location-marker (xref-item)
  "Return a marker for XREF-ITEM, or nil when its location is unavailable."
  (my-codex--xref-call #'xref-location-marker (xref-item-location xref-item)))

(defun my-codex--xref-call (function &rest args)
  "Call xref FUNCTION with ARGS, returning nil when it fails."
  (condition-case err
      (apply function args)
    (error
     (message "Agent xref lookup failed: %s" (error-message-string err))
     nil)))

(defun my-codex--xref-location-label (marker root)
  "Return a project-relative location label for MARKER under ROOT."
  (with-current-buffer (marker-buffer marker)
    (let* ((file (or buffer-file-name (buffer-name)))
           (display-file (if buffer-file-name
                             (file-relative-name file root)
                           file))
           (line (line-number-at-pos marker)))
      (format "%s:%d" display-file line))))

(defun my-codex--line-context-around-marker (marker context-lines)
  "Return text around MARKER spanning CONTEXT-LINES before and after."
  (with-current-buffer (marker-buffer marker)
    (save-excursion
      (goto-char marker)
      (my-codex--line-context-around-point context-lines))))

(defun my-codex--yaml-string (value)
  "Return VALUE as a YAML double-quoted scalar."
  (let ((text (format "%s" value)))
    (setq text (replace-regexp-in-string "\\\\" "\\\\\\\\" text t t))
    (setq text (replace-regexp-in-string "\"" "\\\\\"" text t t))
    (setq text (replace-regexp-in-string "\r" "\\\\r" text t t))
    (setq text (replace-regexp-in-string "\n" "\\\\n" text t t))
    (format "\"%s\"" text)))

(defun my-codex--yaml-literal-block (text indent)
  "Return TEXT as YAML literal block content indented by INDENT spaces."
  (let ((prefix (make-string indent ?\s)))
    (mapconcat
     (lambda (line)
       (concat prefix line))
     (split-string text "\n")
     "\n")))

(defun my-codex--xref-items-section (title items root limit context-lines)
  "Format an xref location section named TITLE from ITEMS.

ROOT is used for project-relative paths.  LIMIT caps the number of entries,
and CONTEXT-LINES controls the excerpt radius for modified xref buffers."
  (let ((entries
         (seq-keep
          (lambda (item)
            (when-let ((marker (my-codex--xref-location-marker item)))
              (string-join
               (delq nil
                     (list
                      (format "  - location: %s"
                              (my-codex--yaml-string
                               (my-codex--xref-location-label marker root)))
                      (when (buffer-modified-p (marker-buffer marker))
                        (format "    excerpt: |\n%s"
                                (my-codex--yaml-literal-block
                                 (my-codex--line-context-around-marker
                                  marker context-lines)
                                 6)))))
               "\n")))
          (seq-take items limit))))
    (when entries
      (format "%s:\n%s"
              (replace-regexp-in-string
               "[^[:alnum:]]+"
               "_"
               (downcase title))
              (string-join entries "\n")))))

(defun my-codex--symbol-xref-context (symbol root)
  "Return formatted xref locations for SYMBOL under ROOT, or nil."
  (when my-codex-symbol-include-xref-context
    (when-let ((backend (my-codex--xref-call #'xref-find-backend)))
      (let* ((identifier (or (my-codex--xref-call
                              #'xref-backend-identifier-at-point backend)
                             symbol))
             (definitions
              (my-codex--xref-call
               #'xref-backend-definitions backend identifier))
             (references
              (my-codex--xref-call
               #'xref-backend-references backend identifier))
             (sections
              (delq nil
                    (list
                     (my-codex--xref-items-section
                      "Definitions"
                      definitions
                      root
                      my-codex-symbol-xref-definition-limit
                      my-codex-symbol-xref-context-lines)
                     (my-codex--xref-items-section
                      "References"
                      references
                      root
                      my-codex-symbol-xref-reference-limit
                      my-codex-symbol-xref-context-lines)))))
        (when sections
          (string-join sections "\n\n"))))))

;;;###autoload
(defun my-codex-explain-symbol-at-point ()
  "Ask the agent to explain the symbol at point with compact context."
  (interactive)
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a file"))
  (let* ((root (my-codex-project-root))
         (file (file-relative-name buffer-file-name root))
         (line (line-number-at-pos))
         (symbol (my-codex--symbol-at-point))
         (context (when (buffer-modified-p)
                    (my-codex--line-context-around-point
                     my-codex-symbol-context-lines)))
         (symbol-context
          (string-join
           (delq nil
                 (list
                  (format (concat "symbol_context:\n"
                                  "  symbol: %s\n"
                                  "  location: %s")
                          (my-codex--yaml-string symbol)
                          (my-codex--yaml-string
                           (format "%s:%d" file line)))
                  (when context
                    (format "  excerpt: |\n%s"
                            (my-codex--yaml-literal-block context 4)))))
           "\n"))
         (xref-context (my-codex--symbol-xref-context symbol root)))
    (my-codex--preview-and-send-prompt
     (string-join
      (delq nil
            (list
             (concat "Explain the role of this symbol using the YAML "
                     "context below.\n\n"
                     symbol-context)
             xref-context
             "Inspect the file directly if needed. Do not edit files."))
      "\n\n"))))

;;;###autoload
(defun my-codex-explain-region-as-error ()
  "Ask the agent to explain the selected compiler or test error."
  (interactive)
  (unless (use-region-p)
    (user-error "No active region"))
  (my-codex--preview-and-send-prompt
   (format "Explain this compiler/test error and suggest the most likely fix:\n\n%s"
           (buffer-substring-no-properties (region-beginning) (region-end)))))


(defun my-codex--region-file-reference (beg end)
  "Return an agent file reference for the region between BEG and END."
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a file"))
  (my-codex--ensure-file-reference-current buffer-file-name)
  (let* ((root (my-codex-project-root))
         (file (my-codex--project-relative-file buffer-file-name root))
         (line-start (line-number-at-pos beg t))
         (line-end (line-number-at-pos (max beg (1- end)) t)))
    (unless file
      (user-error "Current file is outside the current project"))
    (format "%s lines %d-%d"
            (my-codex--format-file-reference file)
            line-start line-end)))

;;;###autoload
(defun my-codex-copy-region-reference (beg end)
  "Copy an agent reference to the active region."
  (interactive "r")
  (unless (use-region-p)
    (user-error "No active region"))
  (let ((reference (my-codex--region-file-reference beg end)))
    (kill-new reference)
    (message "Copied %s" reference)))

(defun my-codex--region-reference-p (beg end)
  "Return non-nil when region BEG to END should be sent by reference."
  (and buffer-file-name
       (not (buffer-modified-p))
       (verify-visited-file-modtime (current-buffer))
       (my-codex--project-relative-file buffer-file-name
                                        (my-codex-project-root))
       (pcase my-codex--region-send-override
         ('reference t)
         ('inline nil)
         (_
          (pcase my-codex-region-send-policy
            ('prefer-reference t)
            ('automatic
             (and my-codex-region-reference-threshold-chars
                  (> (- end beg) my-codex-region-reference-threshold-chars)))
            (_ nil))))))

(defun my-codex--region-prefers-reference-p (beg end)
  "Return non-nil when policy prefers a reference for BEG to END."
  (pcase my-codex-region-send-policy
    ('prefer-reference t)
    ('automatic
     (and my-codex-region-reference-threshold-chars
          (> (- end beg) my-codex-region-reference-threshold-chars)))
    (_ nil)))

(defun my-codex--modified-region-send-choice (beg end)
  "Choose how to send a modified region between BEG and END.
Return `reference', `inline', or nil when no choice is needed."
  (when (and buffer-file-name
             (buffer-modified-p)
             (my-codex--project-relative-file buffer-file-name
                                              (my-codex-project-root))
             (my-codex--region-prefers-reference-p beg end))
    (let* ((large (and my-codex-region-reference-threshold-chars
                       (> (- end beg)
                          my-codex-region-reference-threshold-chars)))
           (default (if large "Save and send reference" "Send inline"))
           (choice (completing-read
                    "Modified region delivery: "
                    '("Save and send reference" "Send inline" "Cancel")
                    nil t nil nil default)))
      (pcase choice
        ("Save and send reference" (save-buffer) 'reference)
        ("Send inline" 'inline)
        (_ (user-error "Region send cancelled"))))))

(defun my-codex--region-sent-message (beg end mode)
  "Return a delivery message for region BEG to END sent using MODE."
  (if (eq mode 'reference)
      (let ((file (my-codex--project-relative-file
                   buffer-file-name (my-codex-project-root))))
        (format "Sent by file reference: %s lines %d-%d"
                file
                (line-number-at-pos beg t)
                (line-number-at-pos (max beg (1- end)) t)))
    (format "Sent inline; outbound prompt text: approximately %s tokens"
            (my-codex--approx-token-count
             (buffer-substring-no-properties beg end)))))

(defun my-codex--region-review-request (beg end)
  "Return review prompt and delivery message for BEG to END."
  (let ((beg-marker (copy-marker beg t))
        (end-marker (copy-marker end)))
    (unwind-protect
        (let* ((choice (my-codex--modified-region-send-choice
                        beg-marker end-marker))
               (my-codex--region-send-override choice)
               (mode (if (my-codex--region-reference-p
                          beg-marker end-marker)
                         'reference
                       'inline)))
          (cons (my-codex--region-review-prompt beg-marker end-marker)
                (my-codex--region-sent-message
                 beg-marker end-marker mode)))
      (set-marker beg-marker nil)
      (set-marker end-marker nil))))

(defun my-codex--region-context-request (beg end)
  "Return prompt context and delivery message for BEG to END."
  (let ((beg-marker (copy-marker beg t))
        (end-marker (copy-marker end)))
    (unwind-protect
        (let* ((choice (my-codex--modified-region-send-choice
                        beg-marker end-marker))
               (my-codex--region-send-override choice)
               (mode (if (my-codex--region-reference-p
                          beg-marker end-marker)
                         'reference
                       'inline)))
          (cons (my-codex--region-prompt-context beg-marker end-marker)
                (my-codex--region-sent-message
                 beg-marker end-marker mode)))
      (set-marker beg-marker nil)
      (set-marker end-marker nil))))

(defun my-codex--region-review-reference-prompt (beg end)
  "Return a region review prompt that references BEG to END by file range."
  (format (concat "Review this code and report findings. Inspect this "
                  "file range directly:"
                  "\n\n%s")
          (my-codex--region-file-reference beg end)))

(defun my-codex--region-review-text-prompt (beg end)
  "Return a region review prompt that includes text between BEG and END."
  (format "%s\n\nReview this code and report findings:\n\n%s"
          (my-codex--region-context beg end)
          (buffer-substring-no-properties beg end)))

(defun my-codex--region-prompt-context (beg end)
  "Return prompt context for region BEG to END."
  (if (my-codex--region-reference-p beg end)
      (format "Selected region:\n\n%s"
              (my-codex--region-file-reference beg end))
    (format "%s\n\n%s"
            (my-codex--region-context beg end)
            (buffer-substring-no-properties beg end))))

(defun my-codex--region-review-prompt (beg end)
  "Return a review prompt for region BEG to END."
  (if (my-codex--region-reference-p beg end)
      (my-codex--region-review-reference-prompt beg end)
    (my-codex--region-review-text-prompt beg end)))

;;;###autoload
(defun my-codex-plan-refactor-region (beg end)
  "Ask the agent for a safe refactoring plan for the active region."
  (interactive "r")
  (unless (use-region-p)
    (user-error "No active region"))
  (pcase-let ((`(,context . ,sent-message)
               (my-codex--region-context-request beg end)))
    (my-codex--preview-and-send-prompt
     (format "%s\n\n%s" my-codex-refactor-plan-prompt context)
     sent-message)))

;;;###autoload
(defun my-codex-open-project-instructions ()
  "Open an effective project agent instruction file, if present."
  (interactive)
  (let* ((root (my-codex-project-root))
         (files (my-codex-project-instruction-files root))
         (file (pcase files
                 ('nil nil)
                 (`(,only) only)
                 (_ (expand-file-name
                     (completing-read
                      "Project instructions: "
                      (mapcar (lambda (candidate)
                                (file-relative-name candidate root))
                              files)
                      nil t)
                     root)))))
    (if file
        (find-file file)
      (user-error "No project instruction file found"))))

(defun my-codex-visible-window ()
  "Return the visible agent window in the selected frame, or raise an error."
  (my-codex-active-session-window))

(defun my-codex--associated-edit-window (codex-window)
  "Return the edit window associated with CODEX-WINDOW, or nil."
  (let ((codex-buffer (window-buffer codex-window)))
    (seq-find
     (lambda (window)
       (and (window-parameter window 'my-codex-edit-window)
            (eq (window-parameter window 'my-codex-term-buffer)
                codex-buffer)))
     (window-list (window-frame codex-window) 'no-minibuf))))

(defun my-codex-code-window ()
  "Return the most likely coding window associated with the agent."
  (let ((codex-window (my-codex-visible-window)))
    (let ((code-window (or (my-codex--associated-edit-window codex-window)
                           (next-window codex-window nil))))
      (if (and code-window (not (eq code-window codex-window)))
          code-window
        (user-error "No coding window found")))))

(defun my-codex-back-to-code ()
  "Move focus to the most likely coding window."
  (interactive)
  (select-window (my-codex-code-window)))

;;;###autoload
(defun my-codex-toggle-focus ()
  "Toggle focus between the agent vterm and the coding window."
  (interactive)
  (let ((codex-window (my-codex-visible-window)))
    (cond
     ((eq (selected-window) codex-window) (my-codex-back-to-code))
     (t (select-window codex-window)))))

(defun my-codex-selected-text ()
  "Return actively selected text from the visible agent window."
  (let ((codex-window (my-codex-visible-window)))
    (with-selected-window codex-window
      (cond
       ((use-region-p)
        (prog1
            (filter-buffer-substring
             (region-beginning)
             (region-end))
          (setq my-codex--captured-selection nil)
          (deactivate-mark)))
       (my-codex--captured-selection
        (prog1 my-codex--captured-selection
          (setq my-codex--captured-selection nil)))
       (t
        (user-error "No active selection in the agent buffer"))))))

;;;###autoload
(defun my-codex-insert-selection-into-code ()
  "Insert selected agent text into the coding window."
  (interactive)
  (let ((text (my-codex-selected-text))
        (code-window (my-codex-code-window)))
    (select-window code-window)
    (insert text)))

;;;###autoload
(defun my-codex-ask (prompt)
  "Read PROMPT in the minibuffer and submit it to the active agent.
When prompt preview is enabled, open it for review first."
  (interactive
   (list (read-string (format "Ask %s: " (my-codex--ask-prompt-label)))))
  (when (string-blank-p prompt)
    (user-error "Prompt cannot be empty"))
  (my-codex--preview-and-send-prompt prompt))

(defun my-codex--region-context (beg end)
  "Return a context string for the region between BEG and END."
  (let* ((root (my-codex-project-root))
         (file (when buffer-file-name
                 (file-relative-name buffer-file-name root)))
         (line-start (line-number-at-pos beg))
         (line-end (line-number-at-pos (max beg (1- end)))))
    (if file
        (format "In file `%s` (lines %d-%d):" file line-start line-end)
      "From an unnamed buffer:")))

(defun my-codex--read-prompt-preset ()
  "Read and return a prompt preset cons cell."
  (unless my-codex-prompt-presets
    (user-error "No agent prompt presets configured"))
  (let* ((names (mapcar #'car my-codex-prompt-presets))
         (name (completing-read "Agent preset: " names nil t)))
    (assoc-string name my-codex-prompt-presets)))

(defun my-codex--file-reference-completion-at-point (files)
  "Complete project FILES after an at-sign at the start of a minibuffer line."
  (let ((line-start (max (line-beginning-position) (minibuffer-prompt-end)))
        (point (point)))
    (when (and (< line-start point)
               (eq (char-after line-start) ?@)
               (save-excursion
                 (goto-char (1+ line-start))
                 (looking-at "[^[:space:]]*"))
               (<= point (match-end 0)))
      (list (1+ line-start) point files :exclusive 'no))))

(defun my-codex--read-additional-instructions ()
  "Read optional additional instructions with project file completion.
When a minibuffer line starts with @, complete project-relative file names
after the at-sign with `completion-at-point'."
  (require 'my-codex-git)
  (let* ((root (my-codex-project-root))
         (files (my-codex--project-files root)))
    (minibuffer-with-setup-hook
        (lambda ()
          (add-hook 'completion-at-point-functions
                    (lambda ()
                      (my-codex--file-reference-completion-at-point files))
                    nil t)
          (when (memq (local-key-binding (kbd "TAB"))
                      '(nil self-insert-command))
            (let ((map (copy-keymap (current-local-map))))
              (define-key map (kbd "TAB") #'completion-at-point)
              (define-key map (kbd "<tab>") #'completion-at-point)
              (use-local-map map))))
      (read-string "Additional instructions (optional): "))))

(defun my-codex--ask-with-prompt-preset (preset)
  "Send PRESET, optionally including extra instructions and the active region."
  (let* ((extra (my-codex--read-additional-instructions))
         (has-region (use-region-p))
         (region-request
          (when has-region
            (my-codex--region-context-request
             (region-beginning) (region-end))))
         (parts (delq nil
                      (list (cdr preset)
                            (unless (string-blank-p extra)
                              extra)
                            (car region-request)))))
    (my-codex--preview-and-send-prompt
     (string-join parts "\n\n")
     (cdr region-request))))

;;;###autoload
(defun my-codex-ask-with-preset ()
  "Read a prompt preset by name and send it to the agent.
After selecting a preset, read extra instructions from the minibuffer.
When a region is active, include exact file and line context for it."
  (interactive)
  (my-codex--ask-with-prompt-preset (my-codex--read-prompt-preset)))

(defconst my-codex--preset-transient-keys
  '("1" "2" "3" "4" "5" "6" "7" "8" "9" "0"
    "a" "b" "c" "d" "e" "f" "g" "h" "j" "k" "l" "n" "u" "v" "x" "y" "z")
  "Keys used for dynamically generated prompt preset transient suffixes.")

(defvar my-codex--prompt-preset-transient-presets nil
  "Prompt presets currently displayed by `my-codex-ask-preset-transient'.")

(defun my-codex--prompt-preset-transient-command (index)
  "Return the transient preset command symbol for INDEX."
  (intern (format "my-codex--ask-with-transient-preset-%d" index)))

(defun my-codex--ask-with-transient-preset-index (index)
  "Send the prompt preset at INDEX from `my-codex-ask-preset-transient'."
  (let ((preset (nth index my-codex--prompt-preset-transient-presets)))
    (unless preset
      (user-error "No agent prompt preset for this key"))
    (my-codex--ask-with-prompt-preset preset)))

(dotimes (index (length my-codex--preset-transient-keys))
  (let ((index index))
    (defalias (my-codex--prompt-preset-transient-command index)
      (lambda ()
        (interactive)
        (my-codex--ask-with-transient-preset-index index)))))

(defun my-codex--prompt-preset-transient-suffixes (_children)
  "Return transient suffixes for `my-codex-prompt-presets'."
  (let* ((visible-presets (seq-take my-codex-prompt-presets
                                    (length my-codex--preset-transient-keys)))
         (hidden-count (- (length my-codex-prompt-presets)
                          (length visible-presets))))
    (setq my-codex--prompt-preset-transient-presets visible-presets)
    (transient-parse-suffixes
     'my-codex-ask-preset-transient
     `[,@(if visible-presets
             (cl-mapcar
              (lambda (key preset index)
                (list key (car preset)
                      (my-codex--prompt-preset-transient-command index)))
              my-codex--preset-transient-keys
              visible-presets
              (number-sequence 0 (1- (length visible-presets))))
           nil)
       ,@(when (> hidden-count 0)
           (list (format "%d more preset%s available via C"
                         hidden-count
                         (if (= hidden-count 1) "" "s"))))
       ""
       ("C" "Choose by name" my-codex-ask-with-preset)])))

;;;###autoload
(transient-define-prefix my-codex-ask-preset-transient ()
  "Ask the agent using a prompt preset."
  [:description my-codex--transient-target-description]
  [:class transient-column
   :setup-children my-codex--prompt-preset-transient-suffixes
   ""]
  (interactive)
  (transient-setup 'my-codex-ask-preset-transient nil nil
                   :scope (ignore-errors
                            (my-codex-active-session-buffer))))

(provide 'my-codex-prompts)

;;; my-codex-prompts.el ends here
