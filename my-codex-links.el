;;; my-codex-links.el --- Session link helpers for my-codex -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Manlio Morini

;; This file is not part of GNU Emacs.

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at https://mozilla.org/MPL/2.0/.

;;; Code:

(require 'browse-url)
(require 'subr-x)
(require 'my-codex)

(declare-function my-codex-project-root "my-codex" ())

(defvar my-codex-session-link-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'my-codex-open-session-link-at-event)
    (define-key map (kbd "RET") #'my-codex-open-session-link-at-point)
    map)
  "Keymap used for clickable agent session links.")

(defvar my-codex-session-links-mode)

(defconst my-codex--url-regexp
  "\\_<https?://[^[:space:]<>()\"'.,;:!?]+\\(?:[.,;:!?]*[^[:space:]<>()\"'.,;:!?]\\)*"
  "Regexp matching HTTP and HTTPS URLs.")

(defconst my-codex--file-reference-regexp
  (concat
   "\\(?1:/?\\(?:[[:alnum:]_.@+-]+/\\)*"
   "\\(?:[[:alnum:]_.@+-]+\\.[[:alnum:]_.@+-]+"
   "\\|Makefile\\|Dockerfile\\|README\\|LICENSE\\)\\)"
   "\\(?:"
   ":\\(?2:[0-9]+\\)\\(?:\\(?::\\(?3:[0-9]+\\)\\)\\|-\\(?5:[0-9]+\\)\\)?"
   "\\|"
   ":L\\(?4:[0-9]+\\)\\(?:-L?\\(?5:[0-9]+\\)\\)?"
   "\\|"
   "#L\\(?6:[0-9]+\\)\\(?:-L?\\(?7:[0-9]+\\)\\)?"
   "\\)")
  "Regexp matching in-repository file references.

Supported forms include:

  src/foo.el:42
  src/foo.el:42-60
  src/foo.el:42:7
  src/foo.el:L42-L60
  src/foo.el#L42-L60
  Makefile:10")

(defconst my-codex--wrapped-file-reference-regexp
  (let ((part "[[:alnum:]_.@+-]+\\(?:\n[ \t]+[[:alnum:]_.@+-]+\\)*")
        (wrap "\\(?:\n[ \t]+\\)?"))
    (concat
     "\\(?1:/?\\(?:"
     part
     "/"
     wrap
     "\\)*"
     "\\(?:"
     part
     "\\.[[:alnum:]_.@+-]+\\|Makefile\\|Dockerfile\\|README\\|LICENSE\\)\\)"
     "\\(?:"
     ":\\(?2:[0-9]+\\)\\(?:\\(?::\\(?3:[0-9]+\\)\\)\\|-\\(?5:[0-9]+\\)\\)?"
     "\\|"
     ":L\\(?4:[0-9]+\\)\\(?:-L?\\(?5:[0-9]+\\)\\)?"
     "\\|"
     "#L\\(?6:[0-9]+\\)\\(?:-L?\\(?7:[0-9]+\\)\\)?"
     "\\)"))
  "Regexp matching file references hard-wrapped inside the path.")

(defconst my-codex--file-reference-context-lines 3
  "Number of preceding lines used to resolve split file references.")

(defun my-codex--add-session-link (beg end type target)
  "Add a clickable agent session link from BEG to END.
TYPE is one of `url' or `file'.  TARGET is link-specific data."
  (add-text-properties
   beg end
   `(mouse-face highlight
     help-echo "mouse-1 or RET: open link"
     keymap ,my-codex-session-link-map
     my-codex-session-link t
     my-codex-session-link-type ,type
     my-codex-session-link-target ,target
     font-lock-face link)))

(defun my-codex-open-session-link-at-event (event)
  "Open the agent session link clicked by EVENT."
  (interactive "e")
  (let* ((end (event-end event))
         (window (posn-window end))
         (pos (posn-point end)))
    (with-current-buffer (window-buffer window)
      (my-codex-open-session-link-at-position pos))))

(defun my-codex-open-session-link-at-point ()
  "Open the agent session link at point."
  (interactive)
  (my-codex-open-session-link-at-position (point)))

(defun my-codex-open-session-link-at-position (pos)
  "Open the agent session link at POS."
  (let ((type (get-text-property pos 'my-codex-session-link-type))
        (target (get-text-property pos 'my-codex-session-link-target)))
    (pcase type
      ('url
       (browse-url target))
      ('file
       (my-codex-open-file-reference target))
      (_
       (user-error "No agent session link at point")))))

(defun my-codex-open-file-reference (target)
  "Open file reference TARGET.
TARGET is a plist containing :file, :line, :column, and :end-line."
  (let* ((root (my-codex-project-root))
         (file (plist-get target :file))
         (line (plist-get target :line))
         (column (plist-get target :column))
         (end-line (plist-get target :end-line)))
    (unless (my-codex--valid-file-reference-target-p target)
      (user-error "File does not exist: %s" file))
    (find-file-other-window (expand-file-name file root))
    (when line
      (goto-char (point-min))
      (forward-line (1- line))
      (if (and end-line
               (>= end-line line))
          (push-mark
           (save-excursion
             (forward-line (- end-line line))
             (line-end-position))
           nil t)
        (deactivate-mark)))
    (when column
      (move-to-column (1- column)))))

(defun my-codex--file-reference-target-at-match ()
  "Return a plist describing the current file-reference regexp match."
  (let ((file (replace-regexp-in-string
               "\n[ \t]+" ""
               (match-string-no-properties 1)
               nil t))
        (line-str (or (match-string-no-properties 2)
                      (match-string-no-properties 4)
                      (match-string-no-properties 6)))
        (column-str (match-string-no-properties 3))
        (end-line-str (or (match-string-no-properties 5)
                          (match-string-no-properties 7))))
    (list :file file
          :line (when line-str
                  (string-to-number line-str))
          :column (when column-str
                    (string-to-number column-str))
          :end-line (when end-line-str
                      (string-to-number end-line-str)))))

(defun my-codex--file-reference-context-directory (pos)
  "Return a nearby preceding directory prefix for a file reference at POS."
  (save-excursion
    (goto-char pos)
    (let ((limit (save-excursion
                   (forward-line (- my-codex--file-reference-context-lines))
                   (point)))
          directory)
      (while (and (not directory)
                  (> (line-beginning-position) limit))
        (forward-line -1)
        (let ((line (string-trim-right
                     (buffer-substring-no-properties
                      (line-beginning-position)
                      (line-end-position)))))
          (when (string-match
                 "\\(?:^\\|[^[:alnum:]_.@+-]\\)\\(\\(?:[[:alnum:]_.@+-]+/\\)+\\)\\'"
                 line)
            (setq directory (match-string 1 line)))))
      directory)))

(defun my-codex--resolve-file-reference-target (target pos)
  "Return a valid file reference TARGET, resolving context at POS when needed."
  (if (my-codex--valid-file-reference-target-p target)
      target
    (let ((file (plist-get target :file)))
      (when (and file
                 (not (file-name-directory file))
                 (not (file-name-absolute-p file)))
        (when-let ((directory (my-codex--file-reference-context-directory pos)))
          (let ((resolved (plist-put (copy-sequence target)
                                     :file
                                     (concat directory file))))
            (when (my-codex--valid-file-reference-target-p resolved)
              resolved)))))))

(defun my-codex--normalise-file-reference-target (target root)
  "Return TARGET with an absolute in-project file made relative to ROOT."
  (let ((file (plist-get target :file)))
    (if (and file
             (file-name-absolute-p file)
             (file-readable-p file)
             (file-in-directory-p (file-truename file) root))
        (plist-put (copy-sequence target)
                   :file
                   (file-relative-name (file-truename file) root))
      target)))

(defun my-codex--valid-file-reference-target-p (target)
  "Return non-nil if TARGET refers to a readable in-project file."
  (let* ((root (file-truename (my-codex-project-root)))
         (target (my-codex--normalise-file-reference-target target root))
         (file (plist-get target :file)))
    (and file
         (not (file-name-absolute-p file))
         (let ((path (expand-file-name file root)))
           (and (file-readable-p path)
                (file-in-directory-p (file-truename path) root))))))

(defun my-codex--line-bounds (beg end)
  "Return a cons of linkification bounds around BEG and END."
  (save-excursion
    (cons
     (progn
       (goto-char beg)
       (forward-line (- my-codex--file-reference-context-lines))
       (line-beginning-position))
     (progn
       (goto-char end)
       (forward-line my-codex--file-reference-context-lines)
       (line-end-position)))))

(defun my-codex--clear-session-links (beg end)
  "Remove agent session link properties between BEG and END."
  (let ((pos beg)
        next)
    (while (< pos end)
      (setq next (next-single-property-change
                  pos 'my-codex-session-link nil end))
      (when (get-text-property pos 'my-codex-session-link)
        (remove-text-properties
         pos next
         '(mouse-face nil
           help-echo nil
           keymap nil
           my-codex-session-link nil
           my-codex-session-link-type nil
           my-codex-session-link-target nil
           font-lock-face nil)))
      (setq pos next))))

(defun my-codex--linkify-session-region (beg end &optional _len)
  "Add agent session links in the region from BEG to END."
  (when my-codex-session-links-mode
    (pcase-let ((`(,rbeg . ,rend) (my-codex--line-bounds beg end)))
      (let ((inhibit-read-only t)
            (inhibit-modification-hooks t))
        (my-codex--clear-session-links rbeg rend)

        ;; URLs first, so file-like text inside URLs is not also linkified.
        (save-excursion
          (goto-char rbeg)
          (while (re-search-forward my-codex--url-regexp rend t)
            (my-codex--add-session-link
             (match-beginning 0)
             (match-end 0)
             'url
             (match-string-no-properties 0))))

        ;; File references.
        (dolist (regexp (list my-codex--file-reference-regexp
                              my-codex--wrapped-file-reference-regexp))
          (save-excursion
            (goto-char rbeg)
            (while (re-search-forward regexp rend t)
              (unless (get-text-property (match-beginning 0)
                                         'my-codex-session-link-type)
                (let ((target (my-codex--file-reference-target-at-match))
                      (match-beg (match-beginning 0))
                      (match-end (match-end 0)))
                  (setq target
                        (my-codex--normalise-file-reference-target
                         target
                         (file-truename (my-codex-project-root))))
                  (when-let ((resolved-target
                              (save-match-data
                                (my-codex--resolve-file-reference-target
                                 target match-beg))))
                    (my-codex--add-session-link
                     match-beg
                     match-end
                     'file
                     resolved-target)))))))))))

(define-minor-mode my-codex-session-links-mode
  "Make URLs and in-repository file references clickable in agent buffers."
  :lighter " Links"
  (if my-codex-session-links-mode
      (progn
        (add-hook 'after-change-functions
                  #'my-codex--linkify-session-region
                  nil t)
        (my-codex--linkify-session-region (point-min) (point-max)))
    (remove-hook 'after-change-functions
                 #'my-codex--linkify-session-region
                 t)
    (let ((inhibit-read-only t)
          (inhibit-modification-hooks t))
      (my-codex--clear-session-links (point-min) (point-max)))))

(provide 'my-codex-links)

;;; my-codex-links.el ends here
