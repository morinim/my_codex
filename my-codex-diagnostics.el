;;; my-codex-diagnostics.el --- Diagnostic prompts for my-codex -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Manlio Morini

;; This file is not part of GNU Emacs.

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at https://mozilla.org/MPL/2.0/.

;;; Commentary:

;; Flycheck and Flymake diagnostic collection for agent prompts.

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'warnings)
(require 'my-codex-prompts)

(defvar flycheck-current-errors)
(defvar flycheck-mode)
(defvar flymake-mode)

(defcustom my-codex-diagnostics-provider 'auto
  "Diagnostic provider used by my-codex commands.
When `auto', prefer an active Flycheck session, then Flymake."
  :type '(choice (const :tag "Automatically select" auto)
                 (const flycheck)
                 (const flymake))
  :group 'my-codex)

(define-obsolete-variable-alias
  'my-codex-flycheck-diagnostics-limit
  'my-codex-diagnostics-limit
  "0.101.0")

(defcustom my-codex-diagnostics-limit 100
  "Maximum number of diagnostics to include in one agent prompt."
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
(declare-function flymake-diagnostic-backend "flymake" (diag))
(declare-function flymake-diagnostic-beg "flymake" (diag))
(declare-function flymake-diagnostic-buffer "flymake" (diag))
(declare-function flymake-diagnostic-end "flymake" (diag))
(declare-function flymake-diagnostic-text "flymake" (diag))
(declare-function flymake-diagnostic-type "flymake" (diag))
(declare-function flymake-diagnostics "flymake" (&optional beg end))
(declare-function flymake--diag-overlay "flymake" (diag))
(declare-function flymake--severity "flymake" (type))

(defun my-codex--diagnostic-value (diagnostic property &optional fallback)
  "Return DIAGNOSTIC PROPERTY, or FALLBACK property when absent."
  (if (plist-member diagnostic property)
      (plist-get diagnostic property)
    (and fallback (plist-get diagnostic fallback))))

(defun my-codex--diagnostic-file (diagnostic root)
  "Return DIAGNOSTIC file name relative to ROOT when possible."
  (let ((file (or (plist-get diagnostic :file) buffer-file-name)))
    (cond
     ((and file root (file-in-directory-p file root))
      (file-relative-name file root))
     (file file)
     (t (buffer-name)))))

(defun my-codex--normalise-flycheck-diagnostic (diagnostic)
  "Convert Flycheck DIAGNOSTIC to the internal representation."
  (list :file (or (flycheck-error-filename diagnostic) buffer-file-name)
        :line (flycheck-error-line diagnostic)
        :column (flycheck-error-column diagnostic)
        :severity (flycheck-error-level diagnostic)
        :source (flycheck-error-checker diagnostic)
        :id (flycheck-error-id diagnostic)
        :message (flycheck-error-message diagnostic)))

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
    (mapcar #'my-codex--normalise-flycheck-diagnostic diagnostics)))

(defun my-codex--diagnostic-entry (diagnostic)
  "Return a YAML-ish entry for DIAGNOSTIC."
  (let ((id (plist-get diagnostic :id)))
    (string-join
     (delq nil
           (list
            (format "      - line: %s"
                    (or (plist-get diagnostic :line) "unknown"))
            (format "        column: %s"
                    (or (plist-get diagnostic :column) "unknown"))
            (format "        severity: %s"
                    (my-codex--yaml-string
                     (format "%s" (my-codex--diagnostic-value
                                    diagnostic :severity :level))))
            (format "        checker: %s"
                    (my-codex--yaml-string
                     (format "%s" (my-codex--diagnostic-value
                                    diagnostic :source :checker))))
            (when id
              (format "        id: %s"
                      (my-codex--yaml-string (format "%s" id))))
            (format "        message: %s"
                    (my-codex--yaml-string
                     (or (plist-get diagnostic :message) "")))))
     "\n")))

(defun my-codex--diagnostic-key (diagnostic root)
  "Return a duplicate-detection key for DIAGNOSTIC under ROOT."
  (list
   (my-codex--diagnostic-file diagnostic root)
   (plist-get diagnostic :line)
   (plist-get diagnostic :column)
   (my-codex--diagnostic-value diagnostic :severity :level)
   (my-codex--diagnostic-value diagnostic :source :checker)
   (plist-get diagnostic :id)
   (plist-get diagnostic :message)))

(defun my-codex--diagnostic-unique (diagnostics root)
  "Return DIAGNOSTICS with exact duplicates removed."
  (let ((seen (make-hash-table :test #'equal))
        unique)
    (dolist (diagnostic diagnostics)
      (let ((key (my-codex--diagnostic-key diagnostic root)))
        (unless (gethash key seen)
          (puthash key t seen)
          (push diagnostic unique))))
    (nreverse unique)))

(defun my-codex--diagnostic-group-key (diagnostic root)
  "Return a repeated-message grouping key for DIAGNOSTIC under ROOT."
  (list
   (my-codex--diagnostic-file diagnostic root)
   (my-codex--diagnostic-value diagnostic :severity :level)
   (my-codex--diagnostic-value diagnostic :source :checker)
   (plist-get diagnostic :id)
   (plist-get diagnostic :message)))

(defun my-codex--diagnostic-group (diagnostics root)
  "Return compact repeated-message groups for DIAGNOSTICS under ROOT."
  (let ((table (make-hash-table :test #'equal))
        groups)
    (dolist (diagnostic diagnostics)
      (let* ((key (my-codex--diagnostic-group-key diagnostic root))
             (group (gethash key table)))
        (if group
            (push diagnostic (plist-get group :diagnostics))
          (setq group
                (list :file (my-codex--diagnostic-file diagnostic root)
                      :level (my-codex--diagnostic-value
                              diagnostic :severity :level)
                      :checker (my-codex--diagnostic-value
                                diagnostic :source :checker)
                      :id (plist-get diagnostic :id)
                      :message (plist-get diagnostic :message)
                      :diagnostics (list diagnostic)))
          (puthash key group table)
          (push group groups))))
    (dolist (group groups)
      (setf (plist-get group :diagnostics)
            (nreverse (plist-get group :diagnostics))))
    (nreverse groups)))

(defun my-codex--diagnostic-group-count (group)
  "Return the number of diagnostics represented by GROUP."
  (length (plist-get group :diagnostics)))

(defun my-codex--diagnostic-truncate-group (group count)
  "Return GROUP with at most COUNT diagnostic locations."
  (let ((copy (copy-sequence group)))
    (setf (plist-get copy :diagnostics)
          (seq-take (plist-get group :diagnostics) count))
    copy))

(defun my-codex--diagnostic-group-entry (group)
  "Return a YAML-ish entry for a compact diagnostic GROUP."
  (let ((diagnostics (plist-get group :diagnostics)))
    (if (= (length diagnostics) 1)
        (my-codex--diagnostic-entry (car diagnostics))
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
                          (or (plist-get diagnostic :line) "unknown")
                          (or (plist-get diagnostic :column) "unknown")))
                diagnostics)
               "\n")))
       "\n"))))

(defun my-codex--diagnostic-at-point (diagnostics)
  "Return the most relevant diagnostic at point from DIAGNOSTICS."
  (let* ((line (line-number-at-pos nil t))
         (column (1+ (current-column)))
         (same-file-p
          (lambda (diagnostic)
            (let ((file (my-codex--diagnostic-value
                         diagnostic :file :filename)))
              (or (not file)
                  (and buffer-file-name
                       (string= (expand-file-name file)
                                (expand-file-name buffer-file-name)))))))
         (overlapping
          (seq-filter
           (lambda (diagnostic)
             (let ((start-line (plist-get diagnostic :line))
                   (start-column (or (plist-get diagnostic :column) 1))
                   (end-line (plist-get diagnostic :end-line))
                   (end-column (plist-get diagnostic :end-column)))
               (and end-line
                    (funcall same-file-p diagnostic)
                    (or (> line start-line)
                        (and (= line start-line) (>= column start-column)))
                    (or (< line end-line)
                        (and (= line end-line)
                             (< column (or end-column column)))))))
           diagnostics))
         (line-diagnostics
          (seq-filter
           (lambda (diagnostic)
             (and (equal (plist-get diagnostic :line) line)
                  (funcall same-file-p diagnostic)))
           diagnostics)))
    (unless (or overlapping line-diagnostics)
      (user-error "No diagnostic at point"))
    (or (car overlapping)
        (car
         (sort
          line-diagnostics
          (lambda (left right)
            (let ((left-distance
                   (abs (- (or (plist-get left :column) 1) column)))
                  (right-distance
                   (abs (- (or (plist-get right :column) 1) column))))
              (< left-distance right-distance))))))))

(defun my-codex--flymake-available-p ()
  "Return non-nil when Flymake is active in the current buffer."
  (and (bound-and-true-p flymake-mode)
       (require 'flymake nil t)))

(defun my-codex--flymake-severity (type)
  "Return the generic severity represented by Flymake diagnostic TYPE."
  (let ((severity (flymake--severity type)))
    (cond
     ((>= severity (warning-numeric-level :error)) 'error)
     ((>= severity (warning-numeric-level :warning)) 'warning)
     (t 'note))))

(defun my-codex--flymake-diagnostic-bounds (diagnostic)
  "Return current buffer bounds for Flymake DIAGNOSTIC."
  (let ((overlay (and (fboundp 'flymake--diag-overlay)
                      (flymake--diag-overlay diagnostic))))
    (if (and (overlayp overlay) (overlay-buffer overlay))
        (cons (overlay-start overlay) (overlay-end overlay))
      (let ((beg (flymake-diagnostic-beg diagnostic)))
        (cons beg (or (flymake-diagnostic-end diagnostic) beg))))))

(defun my-codex--normalise-flymake-diagnostic (diagnostic)
  "Convert Flymake DIAGNOSTIC to the internal representation."
  (let* ((locus (flymake-diagnostic-buffer diagnostic))
         (buffer (if (bufferp locus) locus (current-buffer)))
         (bounds (my-codex--flymake-diagnostic-bounds diagnostic))
         (beg (car bounds))
         (end (cdr bounds))
         (file (if (stringp locus) locus
                 (buffer-local-value 'buffer-file-name buffer))))
    (with-current-buffer buffer
      (save-restriction
        (widen)
        (list
         :file file
         :line (line-number-at-pos beg t)
         :column (save-excursion
                   (goto-char beg)
                   (1+ (current-column)))
         :end-line (line-number-at-pos end t)
         :end-column (save-excursion
                       (goto-char end)
                       (1+ (current-column)))
         :severity (my-codex--flymake-severity
                    (flymake-diagnostic-type diagnostic))
         :source
         (let ((backend (flymake-diagnostic-backend diagnostic)))
           (if (and backend (symbolp backend))
               (symbol-name backend)
             "Flymake"))
         :message (flymake-diagnostic-text diagnostic))))))

(defun my-codex--flymake-diagnostics ()
  "Return current Flymake diagnostics sorted by location."
  (unless (my-codex--flymake-available-p)
    (user-error "Flymake is not active in this buffer"))
  (let ((diagnostics
         (mapcar #'my-codex--normalise-flymake-diagnostic
                 (flymake-diagnostics))))
    (unless diagnostics
      (user-error "No Flymake diagnostics in this buffer"))
    (sort diagnostics
          (lambda (left right)
            (or (< (or (plist-get left :line) most-positive-fixnum)
                   (or (plist-get right :line) most-positive-fixnum))
                (and (equal (plist-get left :line) (plist-get right :line))
                     (< (or (plist-get left :column) most-positive-fixnum)
                        (or (plist-get right :column)
                            most-positive-fixnum))))))))

(defun my-codex--active-diagnostics-provider ()
  "Return the diagnostic provider selected for the current buffer."
  (pcase my-codex-diagnostics-provider
    ('flycheck
     (unless (my-codex--flycheck-available-p)
       (user-error "Flycheck is not active in this buffer"))
     'flycheck)
    ('flymake
     (unless (my-codex--flymake-available-p)
       (user-error "Flymake is not active in this buffer"))
     'flymake)
    ('auto
     (cond
      ((my-codex--flycheck-available-p) 'flycheck)
      ((my-codex--flymake-available-p) 'flymake)
      (t (user-error "Neither Flycheck nor Flymake is active in this buffer"))))
    (_ (user-error "Unknown diagnostic provider: %s"
                   my-codex-diagnostics-provider))))

(defun my-codex--current-diagnostics ()
  "Return (PROVIDER . DIAGNOSTICS) for the current buffer."
  (let ((provider (my-codex--active-diagnostics-provider)))
    (cons provider
          (pcase provider
            ('flycheck (my-codex--flycheck-diagnostics))
            ('flymake (my-codex--flymake-diagnostics))))))

(defun my-codex--diagnostic-groups-by-file (groups)
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

(defun my-codex--diagnostic-group-file-entry (group)
  "Return a YAML-ish file entry for compact diagnostics in GROUP."
  (string-join
   (list
    (format "  - file: %s" (my-codex--yaml-string (car group)))
    "    diagnostics:"
    (string-join (mapcar #'my-codex--diagnostic-group-entry (cdr group))
                 "\n"))
   "\n"))

(defun my-codex--diagnostic-groups-context (groups)
  "Return the YAML-ish diagnostics context for compact GROUPS."
  (string-join
   (mapcar #'my-codex--diagnostic-group-file-entry
           (my-codex--diagnostic-groups-by-file groups))
   "\n"))

(defun my-codex--diagnostic-fit-group-to-budget (selected group token-budget)
  "Return GROUP truncated to fit TOKEN-BUDGET after SELECTED, or nil.
When SELECTED is nil, return one diagnostic if even one exceeds the budget."
  (let ((count (my-codex--diagnostic-group-count group))
        fitted)
    (catch 'done
      (dotimes (index count)
        (let* ((candidate
                (my-codex--diagnostic-truncate-group group (1+ index)))
               (context
                (my-codex--diagnostic-groups-context
                 (append selected (list candidate)))))
          (if (> (my-codex--approx-token-count context) token-budget)
              (throw 'done nil)
            (setq fitted candidate)))))
    (or fitted
        (unless selected
          (my-codex--diagnostic-truncate-group group 1)))))

(defun my-codex--diagnostic-select-groups (groups limit token-budget)
  "Return compact GROUPS constrained by LIMIT and TOKEN-BUDGET."
  (let ((selected nil)
        (included 0))
    (catch 'done
      (dolist (group groups)
        (let* ((remaining (if limit (- limit included) most-positive-fixnum))
               (candidate-group
                (cond
                 ((<= remaining 0) (throw 'done nil))
                 ((> (my-codex--diagnostic-group-count group) remaining)
                  (my-codex--diagnostic-truncate-group group remaining))
                 (t group)))
               (candidate-selected (append selected (list candidate-group)))
               (candidate-context
                (my-codex--diagnostic-groups-context candidate-selected)))
          (when (and token-budget
                     (> (my-codex--approx-token-count candidate-context)
                        token-budget))
            (setq candidate-group
                  (my-codex--diagnostic-fit-group-to-budget
                   selected candidate-group token-budget))
            (unless candidate-group
              (throw 'done nil))
            (setq candidate-selected (append selected (list candidate-group))))
          (setq selected candidate-selected
                included (+ included
                            (my-codex--diagnostic-group-count
                             candidate-group))))))
    selected))

(defun my-codex--diagnostic-batch-prompt (diagnostics &optional provider)
  "Return an agent prompt for DIAGNOSTICS from PROVIDER."
  (let* ((root (my-codex-project-root))
         (provider (or provider 'flycheck))
         (provider-label (capitalize (symbol-name provider)))
         (limit my-codex-diagnostics-limit)
         (total (length diagnostics))
         (unique (my-codex--diagnostic-unique diagnostics root))
         (unique-total (length unique))
         (groups (my-codex--diagnostic-group unique root))
         (selected-groups
          (my-codex--diagnostic-select-groups
           groups limit my-codex-diagnostics-token-budget))
         (diagnostics-context
          (my-codex--diagnostic-groups-context selected-groups))
         (included-unique-count
          (apply #'+ (mapcar #'my-codex--diagnostic-group-count
                             selected-groups)))
         (duplicate-count (- total unique-total))
         (omitted-unique-count (- unique-total included-unique-count))
         (truncated (> omitted-unique-count 0)))
    (format
     (concat "Analyse these %s diagnostics as a batch.\n\n"
             "Identify common root causes, cascade errors, missing imports/"
             "includes/types/configuration, and the smallest likely fix that "
             "would remove the largest number of diagnostics. Do not propose "
             "one fix per diagnostic unless they are genuinely unrelated.\n\n"
             "source: %s\n"
             "diagnostic_count: %d\n"
             "unique_diagnostic_count: %d\n"
             "duplicate_count: %d\n"
             "included_unique_count: %d\n"
             "omitted_unique_count: %d\n"
             "context_budget_tokens: %s\n"
             "context_tokens: %d\n"
             "truncated: %s\n"
             "diagnostics:\n%s")
     provider-label
     provider-label
     total
     unique-total
     duplicate-count
     included-unique-count
     omitted-unique-count
     (if my-codex-diagnostics-token-budget
         (number-to-string my-codex-diagnostics-token-budget)
       "unlimited")
     (my-codex--approx-token-count diagnostics-context)
     (if truncated "true" "false")
     diagnostics-context)))

(defun my-codex--diagnostic-at-point-prompt
    (diagnostic &optional provider)
  "Return an agent prompt for DIAGNOSTIC from PROVIDER."
  (let* ((root (my-codex-project-root))
         (provider-label
          (capitalize (symbol-name (or provider 'flycheck))))
         (file (my-codex--diagnostic-file diagnostic root)))
    (format
     (concat "Explain this %s diagnostic and suggest the most likely "
             "fix. Inspect the file directly if needed. Do not edit files.\n\n"
             "source: %s\n"
             "file: %s\n"
             "diagnostic:\n%s")
     provider-label
     provider-label
     (my-codex--yaml-string file)
     (my-codex--diagnostic-entry diagnostic))))

;;;###autoload
(defun my-codex-explain-diagnostic-at-point ()
  "Ask the agent to explain the diagnostic at point."
  (interactive)
  (pcase-let ((`(,provider . ,diagnostics)
               (my-codex--current-diagnostics)))
    (my-codex--preview-and-send-prompt
     (my-codex--diagnostic-at-point-prompt
      (my-codex--diagnostic-at-point diagnostics)
      provider))))

;;;###autoload
(defun my-codex-explain-buffer-diagnostics ()
  "Ask the agent to analyse current buffer diagnostics as a batch."
  (interactive)
  (pcase-let ((`(,provider . ,diagnostics)
               (my-codex--current-diagnostics)))
    (my-codex--preview-and-send-prompt
     (my-codex--diagnostic-batch-prompt diagnostics provider))))

(provide 'my-codex-diagnostics)

;;; my-codex-diagnostics.el ends here
