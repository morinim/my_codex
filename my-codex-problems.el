;;; my-codex-problems.el --- Problem explanation prompts for my-codex -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Manlio Morini

;; This file is not part of GNU Emacs.

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at https://mozilla.org/MPL/2.0/.

;;; Commentary:

;; Smart problem explanation from regions, diagnostics, and compilation output.

;;; Code:

(require 'compile)
(require 'subr-x)
(require 'my-codex-prompts)

(defcustom my-codex-compilation-output-context-lines 2
  "Number of surrounding compilation output lines to include."
  :type 'natnum
  :group 'my-codex-integrations)

(defcustom my-codex-compilation-source-context-lines 3
  "Number of surrounding source lines to include for compilation problems."
  :type 'natnum
  :group 'my-codex-integrations)

(declare-function my-codex--diagnostic-at-point-prompt-or-nil
                  "my-codex-diagnostics" ())
(declare-function compilation-find-file-1
                  "compile" (marker filename directory &optional formats))

(defun my-codex--problem-region-prompt ()
  "Return an explanation prompt for the active region, or nil."
  (when (use-region-p)
    (format
     "Explain this compiler/test error and suggest the most likely fix:\n\n%s"
     (buffer-substring-no-properties
      (region-beginning) (region-end)))))

(defun my-codex--same-project-p (left right)
  "Return non-nil when buffers LEFT and RIGHT belong to the same project."
  (let ((left-root (with-current-buffer left
                     (my-codex-project-root)))
        (right-root (with-current-buffer right
                      (my-codex-project-root))))
    (equal (file-truename left-root)
           (file-truename right-root))))

(defun my-codex--compilation-buffer-for-subject (subject)
  "Return the compilation buffer relevant to SUBJECT, or nil."
  (if (with-current-buffer subject
        (derived-mode-p 'compilation-mode))
      subject
    (let ((buffer next-error-last-buffer))
      (when (and (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (derived-mode-p 'compilation-mode))
                 (my-codex--same-project-p subject buffer))
        buffer))))

(defun my-codex--compilation-message-at-point ()
  "Return (MESSAGE . MARKER) for the compilation message at point, or nil."
  (save-excursion
    (condition-case nil
        (let ((message (compilation-next-error 0)))
          (cons message (point-marker)))
      (user-error nil))))

(defun my-codex--compilation-current-message (buffer direct)
  "Return the current compilation message in BUFFER.
When DIRECT is non-nil, use BUFFER's point.  Otherwise prefer its recorded
current error."
  (with-current-buffer buffer
    (save-excursion
      (when (and (not direct)
                 compilation-current-error)
        (goto-char compilation-current-error))
      (my-codex--compilation-message-at-point))))

(defun my-codex--compilation-severity (message)
  "Return a severity label for compilation MESSAGE."
  (pcase (compilation--message->type message)
    (0 "info")
    (1 "warning")
    (_ "error")))

(defun my-codex--compilation-source-buffer (loc output-marker)
  "Return the source buffer for LOC found from OUTPUT-MARKER, or nil."
  (let* ((file-structure (compilation--loc->file-struct loc))
         (file-spec (car file-structure))
         (file (car file-spec))
         (directory (cadr file-spec)))
    (cond
     ((bufferp file)
      (and (buffer-live-p file) file))
     ((stringp file)
      (condition-case nil
          (car (compilation-find-file-1
                output-marker file directory
                (compilation--file-struct->formats file-structure)))
        (error nil))))))

(defun my-codex--compilation-source-context (loc output-marker root)
  "Return source context for LOC found from OUTPUT-MARKER under ROOT."
  (when-let ((buffer (my-codex--compilation-source-buffer loc output-marker)))
    (with-current-buffer buffer
      (save-excursion
        (save-restriction
          (widen)
          (goto-char (point-min))
          (forward-line (1- (or (compilation--loc->line loc) 1)))
          (let* ((file (or buffer-file-name (buffer-name)))
                 (display-file
                  (if (and buffer-file-name
                           (file-in-directory-p buffer-file-name root))
                      (file-relative-name buffer-file-name root)
                    file)))
            (list
             :file display-file
             :excerpt
             (my-codex--line-context-around-point
              my-codex-compilation-source-context-lines))))))))

(defun my-codex--compilation-file-label (loc)
  "Return the parsed file label for compilation LOC, or nil."
  (let ((file (car (car (compilation--loc->file-struct loc)))))
    (cond
     ((bufferp file)
      (and (buffer-live-p file)
           (or (buffer-file-name file) (buffer-name file))))
     ((stringp file) file))))

(defun my-codex--compilation-output-context (marker)
  "Return compilation output surrounding MARKER."
  (my-codex--line-context-around-marker
   marker my-codex-compilation-output-context-lines))

(defun my-codex--compilation-context (buffer direct)
  "Return current problem context from compilation BUFFER, or nil.
When DIRECT is non-nil, select the message from BUFFER's point."
  (when-let* ((message-and-marker
               (my-codex--compilation-current-message buffer direct))
              (message (car message-and-marker))
              (output-marker (cdr message-and-marker))
              (loc (compilation--message->loc message)))
    (with-current-buffer buffer
      (let* ((root (my-codex-project-root))
             (source
              (my-codex--compilation-source-context loc output-marker root)))
        (list
         :command (car-safe compilation-arguments)
         :directory default-directory
         :output (my-codex--compilation-output-context output-marker)
         :file (or (plist-get source :file)
                   (my-codex--compilation-file-label loc))
         :line (compilation--loc->line loc)
         :column (compilation--loc->col loc)
         :severity (my-codex--compilation-severity message)
         :source-excerpt (plist-get source :excerpt))))))

(defun my-codex--compilation-context-for-subject ()
  "Return compilation problem context relevant to the current subject."
  (let* ((subject (current-buffer))
         (buffer (my-codex--compilation-buffer-for-subject subject)))
    (when buffer
      (my-codex--compilation-context buffer (eq subject buffer)))))

(defun my-codex--compilation-problem-prompt (context)
  "Return an agent prompt for compilation problem CONTEXT."
  (string-join
   (delq
    nil
    (list
     (concat "Explain this compilation problem and suggest the most likely "
             "fix. Inspect the source directly if needed. Do not edit files.")
     (string-join
      (delq
       nil
       (list
        "source: compilation"
        (when-let ((command (plist-get context :command)))
          (format "command: %s" (my-codex--yaml-string command)))
        (format "directory: %s"
                (my-codex--yaml-string (plist-get context :directory)))
        (format "severity: %s"
                (my-codex--yaml-string (plist-get context :severity)))
        (when-let ((file (plist-get context :file)))
          (format "file: %s" (my-codex--yaml-string file)))
        (when-let ((line (plist-get context :line)))
          (format "line: %d" line))
        (when-let ((column (plist-get context :column)))
          (format "column: %d" column))
        (format "output: |\n%s"
                (my-codex--yaml-literal-block
                 (plist-get context :output) 2))
        (when-let ((excerpt (plist-get context :source-excerpt)))
          (format "source_excerpt: |\n%s"
                  (my-codex--yaml-literal-block excerpt 2)))))
      "\n")))
   "\n\n"))

(defun my-codex--diagnostic-problem-prompt ()
  "Return a diagnostic-at-point prompt for the current buffer, or nil."
  (require 'my-codex-diagnostics)
  (my-codex--diagnostic-at-point-prompt-or-nil))

(defun my-codex--subject-problem-prompt ()
  "Return the most relevant problem prompt for the current subject."
  (or (my-codex--problem-region-prompt)
      (my-codex--diagnostic-problem-prompt)
      (when-let ((context (my-codex--compilation-context-for-subject)))
        (my-codex--compilation-problem-prompt context))))

;;;###autoload
(defun my-codex-explain-compilation-error-at-point ()
  "Ask the agent to explain the relevant compilation error at point."
  (interactive)
  (my-codex--with-subject-buffer
   (lambda ()
     (if-let ((context (my-codex--compilation-context-for-subject)))
         (my-codex--preview-and-send-prompt
          (my-codex--compilation-problem-prompt context))
       (user-error "No compilation error context found")))))

;;;###autoload
(defun my-codex-explain-problem ()
  "Explain the selected or point-local problem using the best available context."
  (interactive)
  (if-let ((prompt (my-codex--problem-region-prompt)))
      (my-codex--preview-and-send-prompt prompt)
    (let ((subject (my-codex--subject-buffer-or-current)))
      (unless (buffer-live-p subject)
        (user-error "No subject buffer available"))
      (with-current-buffer subject
        (if-let ((subject-prompt (my-codex--subject-problem-prompt)))
            (my-codex--preview-and-send-prompt subject-prompt)
          (user-error "No problem context found"))))))

(provide 'my-codex-problems)

;;; my-codex-problems.el ends here
