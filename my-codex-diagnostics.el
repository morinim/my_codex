;;; my-codex-diagnostics.el --- Flycheck diagnostic prompts for my-codex -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Manlio Morini

;; This file is not part of GNU Emacs.

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at https://mozilla.org/MPL/2.0/.

;;; Commentary:

;; Flycheck diagnostic collection for Codex prompts.

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'my-codex-prompts)

(defvar flycheck-current-errors)
(defvar flycheck-mode)

(defcustom my-codex-flycheck-diagnostics-limit 100
  "Maximum number of Flycheck diagnostics to include in one agent prompt."
  :type 'natnum
  :group 'my-codex)

(defcustom my-codex-diagnostics-token-budget 2000
  "Approximate token budget for generated diagnostics context.
When nil, diagnostics context is not capped by token budget."
  :type '(choice (const :tag "No diagnostics token budget" nil)
                 natnum)
  :group 'my-codex)

(declare-function flycheck-error-< "flycheck" (err1 err2))
(declare-function flycheck-error-checker "flycheck" (err))
(declare-function flycheck-error-column "flycheck" (err))
(declare-function flycheck-error-filename "flycheck" (err))
(declare-function flycheck-error-id "flycheck" (err))
(declare-function flycheck-error-level "flycheck" (err))
(declare-function flycheck-error-line "flycheck" (err))
(declare-function flycheck-error-message "flycheck" (err))

(defun my-codex--flycheck-available-p ()
  "Return non-nil when Flycheck diagnostics are available in this buffer."
  (and (bound-and-true-p flycheck-mode)
       (boundp 'flycheck-current-errors)
       (fboundp 'flycheck-error-<)
       (fboundp 'flycheck-error-line)
       (fboundp 'flycheck-error-message)))

(defun my-codex--flycheck-diagnostics ()
  "Return current Flycheck diagnostics sorted by location."
  (unless (my-codex--flycheck-available-p)
    (user-error "Flycheck is not active in this buffer"))
  (let ((diagnostics (sort (copy-sequence flycheck-current-errors)
                           #'flycheck-error-<)))
    (unless diagnostics
      (user-error "No Flycheck diagnostics in this buffer"))
    diagnostics))

(defun my-codex--flycheck-diagnostic-file (diagnostic root)
  "Return DIAGNOSTIC file name relative to ROOT when possible."
  (let ((file (or (flycheck-error-filename diagnostic)
                  buffer-file-name)))
    (cond
     ((and file root (file-in-directory-p file root))
      (file-relative-name file root))
     (file file)
     (t (buffer-name)))))

(defun my-codex--flycheck-diagnostic-entry (diagnostic)
  "Return a YAML-ish entry for Flycheck DIAGNOSTIC."
  (let ((id (flycheck-error-id diagnostic)))
    (string-join
     (delq nil
           (list
            (format "      - line: %s"
                    (or (flycheck-error-line diagnostic) "unknown"))
            (format "        column: %s"
                    (or (flycheck-error-column diagnostic) "unknown"))
            (format "        severity: %s"
                    (my-codex--yaml-string
                     (format "%s" (flycheck-error-level diagnostic))))
            (format "        checker: %s"
                    (my-codex--yaml-string
                     (format "%s" (flycheck-error-checker diagnostic))))
            (when id
              (format "        id: %s"
                      (my-codex--yaml-string (format "%s" id))))
            (format "        message: %s"
                    (my-codex--yaml-string
                     (or (flycheck-error-message diagnostic) "")))))
     "\n")))

(defun my-codex--flycheck-diagnostic-key (diagnostic root)
  "Return a duplicate-detection key for DIAGNOSTIC under ROOT."
  (list
   (my-codex--flycheck-diagnostic-file diagnostic root)
   (flycheck-error-line diagnostic)
   (flycheck-error-column diagnostic)
   (flycheck-error-level diagnostic)
   (flycheck-error-checker diagnostic)
   (flycheck-error-id diagnostic)
   (flycheck-error-message diagnostic)))

(defun my-codex--flycheck-unique-diagnostics (diagnostics root)
  "Return DIAGNOSTICS with exact duplicates removed."
  (let ((seen (make-hash-table :test #'equal))
        unique)
    (dolist (diagnostic diagnostics)
      (let ((key (my-codex--flycheck-diagnostic-key diagnostic root)))
        (unless (gethash key seen)
          (puthash key t seen)
          (push diagnostic unique))))
    (nreverse unique)))

(defun my-codex--flycheck-group-key (diagnostic root)
  "Return a repeated-message grouping key for DIAGNOSTIC under ROOT."
  (list
   (my-codex--flycheck-diagnostic-file diagnostic root)
   (flycheck-error-level diagnostic)
   (flycheck-error-checker diagnostic)
   (flycheck-error-id diagnostic)
   (flycheck-error-message diagnostic)))

(defun my-codex--flycheck-group-diagnostics (diagnostics root)
  "Return compact repeated-message groups for DIAGNOSTICS under ROOT."
  (let ((table (make-hash-table :test #'equal))
        groups)
    (dolist (diagnostic diagnostics)
      (let* ((key (my-codex--flycheck-group-key diagnostic root))
             (group (gethash key table)))
        (if group
            (push diagnostic (plist-get group :diagnostics))
          (setq group
                (list :file (my-codex--flycheck-diagnostic-file diagnostic root)
                      :level (flycheck-error-level diagnostic)
                      :checker (flycheck-error-checker diagnostic)
                      :id (flycheck-error-id diagnostic)
                      :message (flycheck-error-message diagnostic)
                      :diagnostics (list diagnostic)))
          (puthash key group table)
          (push group groups))))
    (dolist (group groups)
      (setf (plist-get group :diagnostics)
            (nreverse (plist-get group :diagnostics))))
    (nreverse groups)))

(defun my-codex--flycheck-group-count (group)
  "Return the number of diagnostics represented by GROUP."
  (length (plist-get group :diagnostics)))

(defun my-codex--flycheck-truncate-group (group count)
  "Return GROUP with at most COUNT diagnostic locations."
  (let ((copy (copy-sequence group)))
    (setf (plist-get copy :diagnostics)
          (seq-take (plist-get group :diagnostics) count))
    copy))

(defun my-codex--flycheck-group-entry (group)
  "Return a YAML-ish entry for a compact Flycheck GROUP."
  (let ((diagnostics (plist-get group :diagnostics)))
    (if (= (length diagnostics) 1)
        (my-codex--flycheck-diagnostic-entry (car diagnostics))
      (string-join
       (delq nil
             (list
              (format "      - severity: %s"
                      (my-codex--yaml-string
                       (format "%s" (plist-get group :level))))
              (format "        checker: %s"
                      (my-codex--yaml-string
                       (format "%s" (plist-get group :checker))))
              (when (plist-get group :id)
                (format "        id: %s"
                        (my-codex--yaml-string
                         (format "%s" (plist-get group :id)))))
              (format "        message: %s"
                      (my-codex--yaml-string
                       (or (plist-get group :message) "")))
              (format "        occurrence_count: %d" (length diagnostics))
              "        locations:"
              (string-join
               (mapcar
                (lambda (diagnostic)
                  (format "          - line: %s\n            column: %s"
                          (or (flycheck-error-line diagnostic) "unknown")
                          (or (flycheck-error-column diagnostic) "unknown")))
                diagnostics)
               "\n")))
       "\n"))))

(defun my-codex--flycheck-diagnostic-at-point (diagnostics)
  "Return the most relevant Flycheck diagnostic at point from DIAGNOSTICS."
  (let* ((line (line-number-at-pos nil t))
         (column (current-column))
         (line-diagnostics
          (seq-filter
           (lambda (diagnostic)
             (and (equal (flycheck-error-line diagnostic) line)
                  (let ((file (flycheck-error-filename diagnostic)))
                    (or (not file)
                        (and buffer-file-name
                             (string= (expand-file-name file)
                                      (expand-file-name buffer-file-name)))))))
           diagnostics)))
    (unless line-diagnostics
      (user-error "No Flycheck diagnostic at point"))
    (car
     (sort
      line-diagnostics
      (lambda (left right)
        (let ((left-distance
               (abs (- (or (flycheck-error-column left) 1) (1+ column))))
              (right-distance
               (abs (- (or (flycheck-error-column right) 1) (1+ column)))))
          (< left-distance right-distance)))))))

(defun my-codex--flycheck-groups-by-file (groups)
  "Return compact diagnostic GROUPS grouped by file."
  (let ((file-groups nil))
    (dolist (group groups)
      (let* ((file (plist-get group :file))
             (file-group (assoc file file-groups)))
        (if file-group
            (setcdr file-group (append (cdr file-group) (list group)))
          (setq file-groups
                (append file-groups (list (list file group)))))))
    file-groups))

(defun my-codex--flycheck-group-file-entry (group)
  "Return a YAML-ish file entry for compact diagnostics in GROUP."
  (string-join
   (list
    (format "  - file: %s" (my-codex--yaml-string (car group)))
    "    diagnostics:"
    (string-join (mapcar #'my-codex--flycheck-group-entry (cdr group))
                 "\n"))
   "\n"))

(defun my-codex--flycheck-groups-context (groups)
  "Return the YAML-ish diagnostics context for compact GROUPS."
  (string-join
   (mapcar #'my-codex--flycheck-group-file-entry
           (my-codex--flycheck-groups-by-file groups))
   "\n"))

(defun my-codex--flycheck-fit-group-to-budget (selected group token-budget)
  "Return GROUP truncated to fit TOKEN-BUDGET after SELECTED, or nil.
When SELECTED is nil, return one diagnostic if even one exceeds the budget."
  (let ((count (my-codex--flycheck-group-count group))
        fitted)
    (catch 'done
      (dotimes (index count)
        (let* ((candidate
                (my-codex--flycheck-truncate-group group (1+ index)))
               (context
                (my-codex--flycheck-groups-context
                 (append selected (list candidate)))))
          (if (> (my-codex--approx-token-count context) token-budget)
              (throw 'done nil)
            (setq fitted candidate)))))
    (or fitted
        (unless selected
          (my-codex--flycheck-truncate-group group 1)))))

(defun my-codex--flycheck-select-groups (groups limit token-budget)
  "Return compact GROUPS constrained by LIMIT and TOKEN-BUDGET."
  (let ((selected nil)
        (included 0))
    (catch 'done
      (dolist (group groups)
        (let* ((remaining (if limit (- limit included) most-positive-fixnum))
               (candidate-group
                (cond
                 ((<= remaining 0) (throw 'done nil))
                 ((> (my-codex--flycheck-group-count group) remaining)
                  (my-codex--flycheck-truncate-group group remaining))
                 (t group)))
               (candidate-selected (append selected (list candidate-group)))
               (candidate-context
                (my-codex--flycheck-groups-context candidate-selected)))
          (when (and token-budget
                     (> (my-codex--approx-token-count candidate-context)
                        token-budget))
            (setq candidate-group
                  (my-codex--flycheck-fit-group-to-budget
                   selected candidate-group token-budget))
            (unless candidate-group
              (throw 'done nil))
            (setq candidate-selected (append selected (list candidate-group))))
          (setq selected candidate-selected
                included (+ included
                            (my-codex--flycheck-group-count
                             candidate-group))))))
    selected))

(defun my-codex--flycheck-diagnostics-prompt (diagnostics)
  "Return an agent prompt for Flycheck DIAGNOSTICS."
  (let* ((root (my-codex-project-root))
         (limit my-codex-flycheck-diagnostics-limit)
         (total (length diagnostics))
         (unique (my-codex--flycheck-unique-diagnostics diagnostics root))
         (unique-total (length unique))
         (groups (my-codex--flycheck-group-diagnostics unique root))
         (selected-groups
          (my-codex--flycheck-select-groups
           groups limit my-codex-diagnostics-token-budget))
         (diagnostics-context
          (my-codex--flycheck-groups-context selected-groups))
         (included
          (apply #'+ (mapcar #'my-codex--flycheck-group-count
                             selected-groups)))
         (omitted (- total included))
         (truncated (> omitted 0)))
    (format
     (concat "Analyse these Flycheck diagnostics as a batch.\n\n"
             "Identify common root causes, cascade errors, missing imports/"
             "includes/types/configuration, and the smallest likely fix that "
             "would remove the largest number of diagnostics. Do not propose "
             "one fix per diagnostic unless they are genuinely unrelated.\n\n"
             "source: Flycheck\n"
             "diagnostic_count: %d\n"
             "unique_diagnostic_count: %d\n"
             "included_count: %d\n"
             "omitted_count: %d\n"
             "context_budget_tokens: %s\n"
             "context_tokens: %d\n"
             "truncated: %s\n"
             "diagnostics:\n%s")
     total
     unique-total
     included
     omitted
     (if my-codex-diagnostics-token-budget
         (number-to-string my-codex-diagnostics-token-budget)
       "unlimited")
     (my-codex--approx-token-count diagnostics-context)
     (if truncated "true" "false")
     diagnostics-context)))

(defun my-codex--flycheck-diagnostic-at-point-prompt (diagnostic)
  "Return an agent prompt for a single Flycheck DIAGNOSTIC."
  (let* ((root (my-codex-project-root))
         (file (my-codex--flycheck-diagnostic-file diagnostic root)))
    (format
     (concat "Explain this Flycheck diagnostic and suggest the most likely "
             "fix. Inspect the file directly if needed. Do not edit files.\n\n"
             "source: Flycheck\n"
             "file: %s\n"
             "diagnostic:\n%s")
     (my-codex--yaml-string file)
     (my-codex--flycheck-diagnostic-entry diagnostic))))

;;;###autoload
(defun my-codex-explain-diagnostic-at-point ()
  "Ask the agent to explain the Flycheck diagnostic at point."
  (interactive)
  (my-codex--preview-and-send-prompt
   (my-codex--flycheck-diagnostic-at-point-prompt
    (my-codex--flycheck-diagnostic-at-point
     (my-codex--flycheck-diagnostics)))))

;;;###autoload
(defun my-codex-explain-buffer-diagnostics ()
  "Ask the agent to analyse current buffer Flycheck diagnostics as a batch."
  (interactive)
  (my-codex--preview-and-send-prompt
   (my-codex--flycheck-diagnostics-prompt
    (my-codex--flycheck-diagnostics))))

(provide 'my-codex-diagnostics)

;;; my-codex-diagnostics.el ends here
