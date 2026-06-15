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

(defvar my-codex--captured-selection)
(defvar my-codex--prompt-preview-origin-window)
(defvar my-codex-enable-prompt-preview)
(defvar my-codex-large-prompt-error-chars)
(defvar my-codex-large-prompt-warning-chars)
(defvar my-codex-project-instruction-files)
(defvar my-codex-prompt-presets)
(defvar my-codex-refactor-plan-prompt)
(defvar my-codex-region-reference-threshold-chars)
(defvar my-codex-symbol-context-lines)
(defvar my-codex-symbol-include-xref-context)
(defvar my-codex-symbol-xref-context-lines)
(defvar my-codex-symbol-xref-definition-limit)
(defvar my-codex-symbol-xref-reference-limit)
(defvar my-codex-test-coverage-prompt)

(declare-function my-codex--project-files "my-codex-git" (root))
(declare-function my-codex--current-backend "my-codex" ())
(declare-function my-codex--safe-root-name "my-codex" (root))
(declare-function my-codex--warn-about-unsaved-project-buffers "my-codex" ())
(declare-function my-codex-backend-send "my-codex" (backend prompt))
(declare-function my-codex-buffer "my-codex" ())
(declare-function my-codex-current-buffer-name "my-codex" ())
(declare-function my-codex-project-root "my-codex" ())

(defun my-codex--ensure-main-package ()
  "Load `my-codex' when this file was entered through an autoload."
  (unless (featurep 'my-codex)
    (require 'my-codex)))

(defun my-codex--approx-token-count (text)
  "Return a rough token count estimate for TEXT."
  (ceiling (/ (float (length text)) 4)))

(defun my-codex--prompt-size-description (prompt)
  "Return a short human-readable size description for PROMPT."
  (format "%d chars, approx. %d tokens"
          (length prompt)
          (my-codex--approx-token-count prompt)))

(defun my-codex--prompt-preview-header (prompt)
  "Return the prompt preview header line for PROMPT."
  (format (concat "Initial size: %s. Edit if needed; "
                  "C-c C-c sends to Codex, C-c C-k cancels.")
          (my-codex--prompt-size-description prompt)))

(defun my-codex--check-prompt-size (prompt)
  "Raise or ask for confirmation when PROMPT is unusually large."
  (let ((size (length prompt)))
    (when (and my-codex-large-prompt-error-chars
               (> size my-codex-large-prompt-error-chars))
      (user-error "Prompt is too large to send (%s; limit is %d chars)"
                  (my-codex--prompt-size-description prompt)
                  my-codex-large-prompt-error-chars))
    (when (and my-codex-large-prompt-warning-chars
               (> size my-codex-large-prompt-warning-chars)
               (not (y-or-n-p
                     (format "Send large Codex prompt (%s)? "
                             (my-codex--prompt-size-description prompt)))))
      (user-error "Codex prompt canceled"))))

(defun my-codex-send-prompt (prompt)
  "Send PROMPT to the Codex backend buffer and show it."
  (my-codex--warn-about-unsaved-project-buffers)
  (my-codex--check-prompt-size prompt)
  (let ((buffer (my-codex-buffer))
        (backend (my-codex--current-backend)))
    (if-let (window (get-buffer-window buffer t))
        (select-window window)
      (pop-to-buffer buffer))
    (redisplay t)
    (my-codex-backend-send backend prompt)))

(defun my-codex--prompt-preview-buffer-name (root)
  "Return the prompt preview buffer name for ROOT."
  (format "*Codex prompt preview:%s*" (my-codex--safe-root-name root)))

(defun my-codex--display-prompt-preview-buffer (buffer origin-window)
  "Display prompt preview BUFFER, preferring ORIGIN-WINDOW."
  (if-let* ((origin-frame (and (window-live-p origin-window)
                               (window-frame origin-window)))
            (codex-window (get-buffer-window (my-codex-current-buffer-name)
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
  "Send the current prompt preview buffer contents to Codex."
  (interactive)
  (let ((prompt (string-trim-right
                 (buffer-substring-no-properties (point-min) (point-max))))
        (root default-directory)
        (buffer (current-buffer)))
    (when (string-blank-p prompt)
      (user-error "Prompt is empty"))
    (let ((default-directory root))
      (my-codex-send-prompt prompt))
    (when (buffer-live-p buffer)
      (kill-buffer buffer))))

(defun my-codex--cancel-prompt-preview ()
  "Cancel the current Codex prompt preview buffer."
  (interactive)
  (let ((origin-window my-codex--prompt-preview-origin-window))
    (kill-buffer (current-buffer))
    (when (window-live-p origin-window)
      (select-window origin-window)))
  (message "Codex prompt canceled."))

(defun my-codex--preview-and-send-prompt (prompt)
  "Preview PROMPT before sending it to Codex when enabled."
  (if my-codex-enable-prompt-preview
      (let* ((root (my-codex-project-root))
             (origin-window (selected-window))
             (buffer (get-buffer-create
                      (my-codex--prompt-preview-buffer-name root))))
        (my-codex--display-prompt-preview-buffer buffer origin-window)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert prompt)
          (goto-char (point-min)))
        (text-mode)
        (setq default-directory root)
        (setq-local my-codex--prompt-preview-origin-window origin-window)
        (setq-local header-line-format
                    (my-codex--prompt-preview-header prompt))
        (let ((map (define-keymap :parent (current-local-map)
                     "C-c C-c" #'my-codex--finish-prompt-preview
                     "C-c C-k" #'my-codex--cancel-prompt-preview)))
          (use-local-map map))
        (message "Codex prompt preview opened."))
    (my-codex-send-prompt prompt)))

;;;###autoload
(defun my-codex-send-region (beg end)
  "Send the region between BEG and END to Codex with exact file context."
  (interactive "r")
  (my-codex--ensure-main-package)
  (unless (use-region-p)
    (user-error "No active region"))
  (my-codex--preview-and-send-prompt
   (my-codex--region-review-prompt beg end)))

;;;###autoload
(defun my-codex-send-current-file ()
  "Ask Codex to inspect the current file directly."
  (interactive)
  (my-codex--ensure-main-package)
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a file"))
  (let* ((root (my-codex-project-root))
         (file (file-relative-name buffer-file-name root)))
    (my-codex--preview-and-send-prompt
     (format "Inspect `%s` directly and report findings. Do not edit unless asked\n"
             file))))

(defun my-codex--project-relative-file (file root)
  "Return FILE relative to ROOT, or nil when FILE is outside ROOT."
  (let ((truename (file-truename file))
        (root-truename (file-name-as-directory (file-truename root))))
    (when (file-in-directory-p truename root-truename)
      (file-relative-name truename root-truename))))

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

(defun my-codex--test-coverage-prompt (implementation-relative test-relative)
  "Return a cache-friendly coverage prompt.
IMPLEMENTATION-RELATIVE and TEST-RELATIVE are project-relative file names."
  (string-join
   (list my-codex-test-coverage-prompt
         (format "context:\n  implementation: @%s\n  test: @%s"
                 implementation-relative
                 test-relative)
         "request: Analyze test coverage now.")
   "\n\n"))

;;;###autoload
(defun my-codex-analyse-test-coverage ()
  "Ask Codex to analyse coverage of the current file by its test file."
  (interactive)
  (my-codex--ensure-main-package)
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a file"))
  (let* ((root (my-codex-project-root))
         (implementation-file buffer-file-name)
         (test-file (my-codex--read-test-file implementation-file root))
         (implementation-relative
          (my-codex--project-relative-file implementation-file root))
         (test-relative (my-codex--project-relative-file test-file root)))
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
        (buffer-substring-no-properties start end)))))

(defun my-codex--xref-location-marker (xref-item)
  "Return a marker for XREF-ITEM, or nil when its location is unavailable."
  (my-codex--xref-call #'xref-location-marker (xref-item-location xref-item)))

(defun my-codex--xref-call (function &rest args)
  "Call xref FUNCTION with ARGS, returning nil when it fails."
  (condition-case err
      (apply function args)
    (error
     (message "Codex xref lookup failed: %s" (error-message-string err))
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

(defun my-codex--yaml-list (values indent)
  "Return VALUES as a YAML list indented by INDENT spaces."
  (if values
      (mapconcat
       (lambda (value)
         (format "%s- %s"
                 (make-string indent ?\s)
                 (my-codex--yaml-string value)))
       values
       "\n")
    (format "%s[]" (make-string indent ?\s))))

(defun my-codex--yaml-literal-block (text indent)
  "Return TEXT as YAML literal block content indented by INDENT spaces."
  (let ((prefix (make-string indent ?\s)))
    (mapconcat
     (lambda (line)
       (concat prefix line))
     (split-string text "\n")
     "\n")))

(defun my-codex--xref-items-section (title items root limit context-lines)
  "Format an xref context section named TITLE from ITEMS.

ROOT is used for project-relative paths.  LIMIT caps the number of entries,
and CONTEXT-LINES controls the excerpt radius around each xref location."
  (let ((entries
         (seq-keep
          (lambda (item)
            (when-let ((marker (my-codex--xref-location-marker item)))
              (let ((summary (xref-item-summary item)))
                (string-join
                 (delq nil
                       (list
                        (format "  - location: %s"
                                (my-codex--yaml-string
                                 (my-codex--xref-location-label marker root)))
                        (unless (or (null summary)
                                    (string-empty-p summary))
                          (format "    summary: %s"
                                  (my-codex--yaml-string summary)))
                        (format "    excerpt: |\n%s"
                                (my-codex--yaml-literal-block
                                 (my-codex--line-context-around-marker
                                  marker context-lines)
                                 6))))
                 "\n"))))
          (seq-take items limit))))
    (when entries
      (format "%s:\n%s"
              (replace-regexp-in-string
               "[^[:alnum:]]+"
               "_"
               (downcase title))
              (string-join entries "\n")))))

(defun my-codex--symbol-xref-context (symbol root)
  "Return formatted xref context for SYMBOL under ROOT, or nil."
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
                      "Definition context"
                      definitions
                      root
                      my-codex-symbol-xref-definition-limit
                      my-codex-symbol-xref-context-lines)
                     (my-codex--xref-items-section
                      "Reference context"
                      references
                      root
                      my-codex-symbol-xref-reference-limit
                      my-codex-symbol-xref-context-lines)))))
        (when sections
          (string-join sections "\n\n"))))))

;;;###autoload
(defun my-codex-explain-symbol-at-point ()
  "Ask Codex to explain the symbol at point with nearby file context."
  (interactive)
  (my-codex--ensure-main-package)
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a file"))
  (let* ((root (my-codex-project-root))
         (file (file-relative-name buffer-file-name root))
         (line (line-number-at-pos))
         (symbol (my-codex--symbol-at-point))
         (context (my-codex--line-context-around-point
                   my-codex-symbol-context-lines))
         (xref-context (my-codex--symbol-xref-context symbol root)))
    (my-codex--preview-and-send-prompt
     (string-join
      (delq nil
            (list
             (format (concat "Explain the role of this symbol using the YAML "
                             "context below.\n\n"
                             "symbol_context:\n"
                             "  file: %s\n"
                             "  symbol: %s\n"
                             "  line: %d\n"
                             "  excerpt: |\n%s")
                     (my-codex--yaml-string file)
                     (my-codex--yaml-string symbol)
                     line
                     (my-codex--yaml-literal-block context 4))
             xref-context
             "Inspect the file directly if needed. Do not edit files."))
      "\n\n"))))

(defun my-codex-explain-region-as-error ()
  "Ask Codex to explain the selected compiler or test error."
  (interactive)
  (unless (use-region-p)
    (user-error "No active region"))
  (my-codex--preview-and-send-prompt
   (format "Explain this compiler/test error and suggest the most likely fix:\n\n%s"
           (buffer-substring-no-properties (region-beginning) (region-end)))))

(defun my-codex--region-file-reference (beg end)
  "Return a Codex file reference for the region between BEG and END."
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a file"))
  (when (buffer-modified-p)
    (user-error "Save the buffer before sending a file reference"))
  (unless (verify-visited-file-modtime (current-buffer))
    (user-error "File changed on disk; revert or save before sending a file reference"))
  (let* ((root (my-codex-project-root))
         (file (my-codex--project-relative-file buffer-file-name root))
         (line-start (line-number-at-pos beg t))
         (line-end (line-number-at-pos (max beg (1- end)) t)))
    (unless file
      (user-error "Current file is outside the current project"))
    (format "@%s lines %d-%d" file line-start line-end)))

(defun my-codex--region-reference-p (beg end)
  "Return non-nil when region BEG to END should be sent by reference."
  (and buffer-file-name
       (not (buffer-modified-p))
       (verify-visited-file-modtime (current-buffer))
       (my-codex--project-relative-file buffer-file-name
                                        (my-codex-project-root))
       my-codex-region-reference-threshold-chars
       (> (- end beg) my-codex-region-reference-threshold-chars)))

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
  "Ask Codex for a safe refactoring plan for the active region.
Send only a file and line-range reference, not the selected text."
  (interactive "r")
  (my-codex--ensure-main-package)
  (unless (use-region-p)
    (user-error "No active region"))
  (my-codex--preview-and-send-prompt
   (format "%s\n\n%s"
           my-codex-refactor-plan-prompt
           (my-codex--region-file-reference beg end))))

;;;###autoload
(defun my-codex-open-project-instructions ()
  "Open the project Codex/agent instruction file, if present."
  (interactive)
  (my-codex--ensure-main-package)
  (let* ((root (my-codex-project-root))
         (file (seq-find (lambda (name)
                           (file-exists-p (expand-file-name name root)))
                         my-codex-project-instruction-files)))
    (if file
        (find-file (expand-file-name file root))
      (user-error "No project instruction file found"))))

(defun my-codex-visible-window ()
  "Return the visible Codex window in the selected frame, or raise an error."
  (or (get-buffer-window (my-codex-current-buffer-name))
      (user-error "No visible Codex window in selected frame")))

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
  "Return the most likely coding window associated with Codex."
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
  "Toggle focus between the Codex vterm and the coding window."
  (interactive)
  (my-codex--ensure-main-package)
  (let ((codex-window (my-codex-visible-window)))
    (cond
     ((eq (selected-window) codex-window) (my-codex-back-to-code))
     (t (select-window codex-window)))))

(defun my-codex-selected-text ()
  "Return actively selected text from the visible Codex window."
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
        (user-error "No active selection in the Codex buffer"))))))

;;;###autoload
(defun my-codex-insert-selection-into-code ()
  "Insert selected Codex text into the coding window."
  (interactive)
  (my-codex--ensure-main-package)
  (let ((text (my-codex-selected-text))
        (code-window (my-codex-code-window)))
    (select-window code-window)
    (insert text)))

;;;###autoload
(defun my-codex-ask (prompt)
  "Read PROMPT in the minibuffer and send it straight to Codex."
  (interactive "sAsk Codex: ")
  (my-codex--ensure-main-package)
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
    (user-error "No Codex prompt presets configured"))
  (let* ((names (mapcar #'car my-codex-prompt-presets))
         (name (completing-read "Codex preset: " names nil t)))
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
  (let* ((root (my-codex-project-root))
         (files (my-codex--project-files root)))
    (minibuffer-with-setup-hook
        (lambda ()
          (add-hook 'completion-at-point-functions
                    (lambda ()
                      (my-codex--file-reference-completion-at-point files))
                    nil t)
          (let ((map (copy-keymap (current-local-map))))
            (define-key map (kbd "TAB") #'completion-at-point)
            (define-key map (kbd "<tab>") #'completion-at-point)
            (use-local-map map)))
      (read-string "Additional instructions (optional): "))))

(defun my-codex--ask-with-prompt-preset (preset)
  "Send PRESET, optionally including extra instructions and the active region."
  (let* ((extra (my-codex--read-additional-instructions))
         (has-region (use-region-p))
         (parts (delq nil
                      (list (cdr preset)
                            (unless (string-blank-p extra)
                              extra)
                            (when has-region
                              (let ((beg (region-beginning))
                                    (end (region-end)))
                                (my-codex--region-prompt-context beg end)))))))
    (my-codex--preview-and-send-prompt (string-join parts "\n\n"))))

;;;###autoload
(defun my-codex-ask-with-preset ()
  "Read a prompt preset by name and send it to Codex.
After selecting a preset, read extra instructions from the minibuffer.
When a region is active, include exact file and line context for it."
  (interactive)
  (my-codex--ensure-main-package)
  (my-codex--ask-with-prompt-preset (my-codex--read-prompt-preset)))

(defconst my-codex--preset-transient-keys
  '("1" "2" "3" "4" "5" "6" "7" "8" "9" "0"
    "a" "b" "c" "d" "e" "f" "g" "h" "j" "k" "l" "n" "u" "v" "x" "y" "z")
  "Keys used for dynamically generated prompt preset transient suffixes.")

(defun my-codex--prompt-preset-transient-suffixes (_children)
  "Return transient suffixes for `my-codex-prompt-presets'."
  (let* ((visible-presets (seq-take my-codex-prompt-presets
                                    (length my-codex--preset-transient-keys)))
         (hidden-count (- (length my-codex-prompt-presets)
                          (length visible-presets))))
    (transient-parse-suffixes
     'my-codex-ask-preset-transient
     `[,@(if visible-presets
             (cl-mapcar
              (lambda (key preset)
                (let ((preset preset))
                  (list key (car preset)
                        (lambda ()
                          (interactive)
                          (my-codex--ask-with-prompt-preset preset)))))
              my-codex--preset-transient-keys
              visible-presets)
           nil)
       ,@(when (> hidden-count 0)
           (list (format "%d more preset%s available via C"
                         hidden-count
                         (if (= hidden-count 1) "" "s"))))
       ""
       ("C" "Choose by name" my-codex-ask-with-preset)])))

;;;###autoload
(transient-define-prefix my-codex-ask-preset-transient ()
  "Ask Codex using a prompt preset."
  (interactive)
  (my-codex--ensure-main-package)
  [:class transient-column
   :setup-children my-codex--prompt-preset-transient-suffixes])

(provide 'my-codex-prompts)

;;; my-codex-prompts.el ends here
