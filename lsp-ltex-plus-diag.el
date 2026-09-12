;;; lsp-ltex-plus-diag.el --- Showing the server's diagnostics through flymake -*- lexical-binding: t; -*-

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Keywords: lsp, grammar, spelling, convenience
;; URL: https://github.com/ltex-plus/emacs-ltex-plus

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:
;;
;; A flymake backend fed by the diagnostics the connection layer stores.
;; Flymake is the front-end because its list of backends is buffer-local
;; and takes many: this one sits beside whatever another language server
;; installed, with no priority to negotiate and nothing to configure.
;;
;; Flymake's model is pull, the server's is push, and the two meet the way
;; `eglot' meets them.  When flymake asks the backend for a check it hands
;; over a report function; the backend keeps the latest one, answers at
;; once with whatever the server last published, and answers again,
;; through the same function, each time a new publish arrives.  Flymake
;; accepts any number of reports through the report function it handed
;; out last, so the underlines follow the server without flymake having
;; to be asked to check again.

;;; Code:

(require 'flymake)
(require 'lsp-ltex-plus-settings)
(require 'lsp-ltex-plus-conn)

(defvar-local lsp-ltex-plus--flymake-report-fn nil
  "The report function flymake handed this buffer's backend last, or nil.")

(defun lsp-ltex-plus--flymake-type (severity)
  "Return the flymake type for the protocol's diagnostic SEVERITY.
Errors and warnings map to their own; information and hints, and a
diagnostic that gives no severity, are notes.  The severity itself is
whatever `lsp-ltex-plus-diagnostic-severity' made the server use."
  (pcase severity
    (1 :error)
    (2 :warning)
    (_ :note)))

(defun lsp-ltex-plus--flymake-text (diagnostic)
  "Return the text flymake shows for DIAGNOSTIC.
The server's message, with the rule id in brackets after it: the id is
what a user needs when deciding to disable the rule."
  (let ((message (plist-get diagnostic :message))
        (code (plist-get diagnostic :code)))
    (if code
        (format "%s [%s]" message code)
      message)))

(defun lsp-ltex-plus--flymake-diagnostic (diagnostic &optional buffer)
  "Return the flymake diagnostic for the protocol DIAGNOSTIC in BUFFER.
BUFFER defaults to the current buffer.  The protocol object rides along
as the diagnostic's data, so a code action at point can find the
diagnostics it applies to."
  (let ((buffer (or buffer (current-buffer))))
    (pcase-let ((`(,beg . ,end) (lsp-ltex-plus--diagnostic-region diagnostic buffer)))
      (flymake-make-diagnostic buffer beg end
                               (lsp-ltex-plus--flymake-type (plist-get diagnostic :severity))
                               (lsp-ltex-plus--flymake-text diagnostic)
                               diagnostic))))

(defun lsp-ltex-plus--whole-buffer ()
  "Return (BEG . END) spanning the whole of the current buffer, widened."
  (save-restriction
    (widen)
    (cons (point-min) (point-max))))

(defun lsp-ltex-plus--flymake-send (report-fn diagnostics)
  "Hand DIAGNOSTICS to flymake through REPORT-FN, replacing the last report.
Flymake treats a backend's second and later reports as additions unless
they name a region, so every report here names the whole buffer: what
the server last published is the whole truth about the buffer, and an
empty list means there is nothing left to show.  A report flymake no
longer expects -- it asked the backend again in the meantime, or was
switched off between the check and the publish -- is logged and let
go; the next report through the newer function will carry the same
diagnostics."
  (condition-case err
      (funcall report-fn diagnostics :region (lsp-ltex-plus--whole-buffer))
    (error
     (lsp-ltex-plus--log "flymake declined a report for %s: %s"
                         (buffer-name) (error-message-string err)))))

(defun lsp-ltex-plus--flymake-report (buffer)
  "Report BUFFER's stored diagnostics to flymake, if it is listening.
On `lsp-ltex-plus--diagnostics-functions'.  Nothing happens for a buffer
whose backend flymake has not called yet, or where flymake is off."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and lsp-ltex-plus--flymake-report-fn flymake-mode)
        (lsp-ltex-plus--flymake-send
         lsp-ltex-plus--flymake-report-fn
         (mapcar (lambda (diagnostic)
                   (lsp-ltex-plus--flymake-diagnostic diagnostic buffer))
                 lsp-ltex-plus--diagnostics))))))

(defun lsp-ltex-plus-flymake-backend (report-fn &rest _)
  "Report the server's diagnostics for the current buffer to flymake.
For `flymake-diagnostic-functions'.  REPORT-FN is kept and answered at
once with what the server last published, and again on every publish
after that, until flymake hands over a newer one."
  (setq lsp-ltex-plus--flymake-report-fn report-fn)
  (lsp-ltex-plus--flymake-report (current-buffer)))

;; Flymake 1.4.7 (Emacs 32) runs a backend in a buffer whose content is
;; not trusted only if the backend says it is safe there.  This one is: it
;; executes nothing from the buffer, it sends the text to the server the
;; user configured and shows what comes back, which is no more than a
;; spell checker does.  Without the declaration every file outside
;; `trusted-content' -- most of a user's files -- would silently get no
;; diagnostics.  Older flymakes ignore the property.
(function-put #'lsp-ltex-plus-flymake-backend 'flymake-always-safe t)

(defun lsp-ltex-plus--flymake-attach ()
  "Make the current buffer show the server's diagnostics through flymake.
Adds the backend and turns `flymake-mode' on if it is not already."
  (add-hook 'flymake-diagnostic-functions #'lsp-ltex-plus-flymake-backend nil t)
  (unless flymake-mode
    (flymake-mode 1)))

(defun lsp-ltex-plus--flymake-detach ()
  "Stop showing the server's diagnostics in the current buffer.
Clears what the backend reported, then removes it.  `flymake-mode' is
left as it is: another backend may be using it, and switching it off
behind the user's back would be a surprise either way."
  (when (and lsp-ltex-plus--flymake-report-fn flymake-mode)
    (lsp-ltex-plus--flymake-send lsp-ltex-plus--flymake-report-fn nil))
  (setq lsp-ltex-plus--flymake-report-fn nil)
  (remove-hook 'flymake-diagnostic-functions #'lsp-ltex-plus-flymake-backend t))

(add-hook 'lsp-ltex-plus--diagnostics-functions #'lsp-ltex-plus--flymake-report)

(provide 'lsp-ltex-plus-diag)
;;; lsp-ltex-plus-diag.el ends here
