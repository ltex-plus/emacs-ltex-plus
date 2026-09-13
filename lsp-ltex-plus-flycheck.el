;;; lsp-ltex-plus-flycheck.el --- Showing the server's diagnostics through flycheck -*- lexical-binding: t; -*-

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Keywords: lsp, grammar, spelling, convenience
;; URL: https://github.com/ltex-plus/emacs-ltex-plus

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:
;;
;; A flycheck checker fed by the diagnostics the connection layer stores,
;; for those who run flycheck rather than flymake.  Flycheck is optional:
;; this file loads without it, and the checker is defined when the first
;; buffer is attached to it.  Flymake stays the default front-end; the
;; choice is `lsp-ltex-plus-diagnostics-provider'.
;;
;; Flycheck's model is pull, like flymake's, but it takes one answer per
;; check: the callback a checker is handed is good for exactly one
;; `finished', and anything reported through it afterwards is dropped.
;; So the checker's start function answers at once with what the server
;; last published, and every later publish asks flycheck to check the
;; buffer again (`flycheck-buffer'), which brings it straight back to the
;; start function.  A check is asked for, never a report pushed: that is
;; the invariant of this file.
;;
;; Flycheck runs one checker per buffer, chosen from `flycheck-checkers'
;; or set as `flycheck-checker'.  Attaching sets the buffer's
;; `flycheck-checker' to this one, as lsp-mode does, and puts the old
;; value back on detaching; a second checker for the same buffer is
;; chained with `flycheck-add-next-checker'.

;;; Code:

(require 'lsp-ltex-plus-bootstrap)
(require 'lsp-ltex-plus-settings)
(require 'lsp-ltex-plus-conn)

;; Flycheck is loaded only when a buffer is attached to it; until then
;; these are the names the byte-compiler needs to know.
(defvar flycheck-mode)
(defvar flycheck-checker)
(defvar flycheck-after-syntax-check-hook)
(declare-function flycheck-mode "ext:flycheck")
(declare-function flycheck-buffer "ext:flycheck")
(declare-function flycheck-running-p "ext:flycheck")
(declare-function flycheck-add-mode "ext:flycheck")
(declare-function flycheck-valid-checker-p "ext:flycheck")
(declare-function flycheck-checker-supports-major-mode-p "ext:flycheck")
(declare-function flycheck-define-generic-checker "ext:flycheck")
(declare-function flycheck-error-new-at "ext:flycheck")
(declare-function flycheck-verification-result-new "ext:flycheck")

(defvar-local lsp-ltex-plus--flycheck-attached nil
  "Non-nil while this buffer shows the server's diagnostics through flycheck.
The checker's predicate, so that it is never chosen for a buffer this
package is not checking, whatever `flycheck-checkers' says.")

(defvar-local lsp-ltex-plus--flycheck-previous-checker nil
  "The buffer's `flycheck-checker' before this package set it.
Put back when the buffer is detached, unless the user changed the
selection in between.")

;;;; -- Conversion -------------------------------------------------------------

(defun lsp-ltex-plus--flycheck-level (severity)
  "Return the flycheck level for the protocol's diagnostic SEVERITY.
Errors and warnings map to their own; information and hints, and a
diagnostic that gives no severity, are `info'."
  (pcase severity
    (1 'error)
    (2 'warning)
    (_ 'info)))

(defun lsp-ltex-plus--flycheck-line-column (point)
  "Return (LINE . COLUMN) for POINT in the current buffer, both 1-based.
Counted in the widened buffer, which is where flycheck resolves them."
  (save-restriction
    (widen)
    (save-excursion
      (goto-char point)
      (cons (line-number-at-pos)
            (1+ (- point (line-beginning-position)))))))

(defun lsp-ltex-plus--flycheck-error (diagnostic &optional buffer)
  "Return the flycheck error for the protocol DIAGNOSTIC in BUFFER.
BUFFER defaults to the current buffer.  The range is carried as a start
and an end line and column, which flycheck highlights exactly; the rule
id goes in the error's own id field, where flycheck shows it after the
message."
  (let ((buffer (or buffer (current-buffer))))
    (with-current-buffer buffer
      (pcase-let* ((`(,beg . ,end) (lsp-ltex-plus--diagnostic-region diagnostic buffer))
                   (`(,line . ,column) (lsp-ltex-plus--flycheck-line-column beg))
                   (`(,end-line . ,end-column) (lsp-ltex-plus--flycheck-line-column end))
                   (code (plist-get diagnostic :code)))
        (flycheck-error-new-at line column
                               (lsp-ltex-plus--flycheck-level (plist-get diagnostic :severity))
                               (plist-get diagnostic :message)
                               :end-line end-line
                               :end-column end-column
                               :id (and code (format "%s" code))
                               :checker 'lsp-ltex-plus
                               :buffer buffer
                               :filename (buffer-file-name buffer))))))

;;;; -- The checker ------------------------------------------------------------

(defun lsp-ltex-plus--flycheck-start (_checker callback)
  "Answer CALLBACK at once with the current buffer's stored diagnostics.
The `:start' function of the checker.  There is nothing to wait for:
the server pushes, the connection layer stores, and a check is the
moment flycheck reads what is stored."
  (funcall callback 'finished
           (mapcar #'lsp-ltex-plus--flycheck-error lsp-ltex-plus--diagnostics)))

(defun lsp-ltex-plus--flycheck-verify (_checker)
  "Describe the checker's state in this buffer for `flycheck-verify-setup'."
  (let ((running (lsp-ltex-plus--live-connection)))
    (list (flycheck-verification-result-new
           :label "lsp-ltex-plus-mode"
           :message (if lsp-ltex-plus--flycheck-attached
                        "checking this buffer"
                      "not checking this buffer")
           :face (if lsp-ltex-plus--flycheck-attached 'success '(bold warning)))
          (flycheck-verification-result-new
           :label "ltex-ls-plus"
           :message (if running "running" "not running")
           :face (if running 'success '(bold warning))))))

(defun lsp-ltex-plus--flycheck-define ()
  "Define the `lsp-ltex-plus' checker.  Flycheck must be loaded.
Called when the first buffer is attached rather than when flycheck
loads: a package that acts on another's loading is configuration, and
until a buffer is attached there is nothing for the checker to do."
  (flycheck-define-generic-checker 'lsp-ltex-plus
    "Grammar and spell checking by LTeX+ (ltex-ls-plus).

Reports the diagnostics the running `lsp-ltex-plus-mode' holds for the
buffer; the server is asked nothing.  Chosen automatically in every
buffer the mode is turned on in while
`lsp-ltex-plus-diagnostics-provider' is `flycheck'."
    :start #'lsp-ltex-plus--flycheck-start
    :verify #'lsp-ltex-plus--flycheck-verify
    :predicate (lambda () lsp-ltex-plus--flycheck-attached)
    :modes (mapcar #'car lsp-ltex-plus-major-modes)))

;;;; -- Asking for a check -----------------------------------------------------

(defun lsp-ltex-plus--flycheck-recheck ()
  "Check the buffer once the running check has finished, then step aside.
One-shot, on `flycheck-after-syntax-check-hook'."
  (remove-hook 'flycheck-after-syntax-check-hook #'lsp-ltex-plus--flycheck-recheck t)
  (lsp-ltex-plus--flycheck-refresh))

(defun lsp-ltex-plus--flycheck-check-now ()
  "Run `flycheck-buffer' in the current buffer, reporting what it cannot finish.
One thing can come out of `flycheck-buffer' here as a signal: a checker
chained after this one that cannot be started, typically because its
executable has gone.  Flycheck raises that as a plain `error' -- it
defines no condition of its own -- after recording the failed check
itself, and by then this checker's errors are already on show.
Flycheck's own automatic checks turn that error into a message; so
does this, naming the buffer."
  (condition-case err
      (flycheck-buffer)
    (error
     (lsp-ltex-plus--log "flycheck-buffer failed in %s: %s"
                         (buffer-name) (error-message-string err))
     (message "[lsp-ltex-plus] flycheck could not finish checking %s: %s"
              (buffer-name) (error-message-string err)))))

(defun lsp-ltex-plus--flycheck-refresh ()
  "Ask flycheck to check the current buffer again, now or when it is free.
`flycheck-buffer' does nothing while a check is running -- another
checker chained after this one may be -- so then the request waits on
`flycheck-after-syntax-check-hook' and is made once, when that check
finishes."
  (when (bound-and-true-p flycheck-mode)
    (if (flycheck-running-p)
        (add-hook 'flycheck-after-syntax-check-hook #'lsp-ltex-plus--flycheck-recheck nil t)
      (lsp-ltex-plus--flycheck-check-now))))

(defun lsp-ltex-plus--flycheck-report (buffer)
  "Have flycheck read BUFFER's stored diagnostics, if it shows them.
On `lsp-ltex-plus--diagnostics-functions'.  Nothing happens for a buffer
that is not attached to flycheck, or where flycheck is off."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when lsp-ltex-plus--flycheck-attached
        (lsp-ltex-plus--flycheck-refresh)))))

;;;; -- Attaching and detaching ------------------------------------------------

(defun lsp-ltex-plus--flycheck-available-p ()
  "Return non-nil if flycheck is installed, loading it if need be."
  (require 'flycheck nil t))

(defun lsp-ltex-plus--flycheck-attach ()
  "Make the current buffer show the server's diagnostics through flycheck.
Defines the checker if this is the first buffer, selects it for the
buffer, remembering what was selected before, teaches it the major mode
if it has not met it, and turns `flycheck-mode' on if it is not
already.  Flycheck must be installed; see
`lsp-ltex-plus--flycheck-available-p'."
  (require 'flycheck)
  (unless (flycheck-valid-checker-p 'lsp-ltex-plus)
    (lsp-ltex-plus--flycheck-define))
  (unless (flycheck-checker-supports-major-mode-p 'lsp-ltex-plus)
    (flycheck-add-mode 'lsp-ltex-plus major-mode))
  (setq lsp-ltex-plus--flycheck-attached t)
  (unless (eq flycheck-checker 'lsp-ltex-plus)
    (setq lsp-ltex-plus--flycheck-previous-checker flycheck-checker)
    (setq flycheck-checker 'lsp-ltex-plus))
  (if flycheck-mode
      ;; Whatever the previous checker showed goes; this one has nothing
      ;; to show yet, and will ask again when the server publishes.
      (lsp-ltex-plus--flycheck-refresh)
    (flycheck-mode 1)))

(defun lsp-ltex-plus--flycheck-detach ()
  "Stop showing the server's diagnostics in the current buffer.
Puts the previous checker back and has flycheck check with it, which
takes this checker's errors away and shows the other's.  `flycheck-mode'
is left as it is, for the same reason flymake is."
  (when lsp-ltex-plus--flycheck-attached
    (setq lsp-ltex-plus--flycheck-attached nil)
    (when (eq flycheck-checker 'lsp-ltex-plus)
      (setq flycheck-checker lsp-ltex-plus--flycheck-previous-checker))
    (setq lsp-ltex-plus--flycheck-previous-checker nil)
    (lsp-ltex-plus--flycheck-refresh)))

(add-hook 'lsp-ltex-plus--diagnostics-functions #'lsp-ltex-plus--flycheck-report)

(provide 'lsp-ltex-plus-flycheck)
;;; lsp-ltex-plus-flycheck.el ends here
