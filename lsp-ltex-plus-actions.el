;;; lsp-ltex-plus-actions.el --- Code actions: asking, choosing, applying -*- lexical-binding: t; -*-

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Keywords: lsp, grammar, spelling, convenience
;; URL: https://github.com/ltex-plus/emacs-ltex-plus

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:
;;
;; What happens when the user asks what can be done about an underline.
;; The server is asked for the code actions at point, or over the region,
;; with the diagnostics found there as context; the titles are offered in
;; a `completing-read'; and the chosen action is carried out here.
;;
;; `ltex-ls-plus' returns two shapes of action.  A suggestion to replace
;; text carries a `WorkspaceEdit', applied to the buffer.  The other three
;; -- add a word to the dictionary, disable a rule, hide a false positive
;; -- carry a command the server never expects to receive back: they are
;; handled entirely on this side, by writing to one of the four lists and
;; telling the server its configuration changed.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'jsonrpc)
(require 'lsp-ltex-plus-settings)
(require 'lsp-ltex-plus-conn)

;;;; -- Asking the server -------------------------------------------------------

(defun lsp-ltex-plus--diagnostics-in (beg end &optional buffer)
  "Return the stored diagnostics of BUFFER that touch the region BEG..END.
BUFFER defaults to the current buffer.  When BEG and END are the same
position, the diagnostics whose text contains it, the end of the text
included -- point just after a flagged word still counts as being on
it.  These are what the server is given as the context of a code action
request, and what decides which suggestions it makes."
  (with-current-buffer (or buffer (current-buffer))
    (seq-filter (lambda (diagnostic)
                  (pcase-let ((`(,dbeg . ,dend)
                               (lsp-ltex-plus--diagnostic-region diagnostic)))
                    (if (= beg end)
                        (and (<= dbeg beg) (<= beg dend))
                      (and (< dbeg end) (< beg dend)))))
                lsp-ltex-plus--diagnostics)))

(defun lsp-ltex-plus--request-code-actions (beg end)
  "Return the code actions the server offers for BEG..END in the current buffer.
A list of the protocol's code action objects, possibly empty.  Waits
for the reply: the server answers from the check it has already done,
so this is quick.  Signals a `user-error' in a buffer that is not open
on a running server."
  (let ((conn (lsp-ltex-plus--live-connection))
        (uri lsp-ltex-plus--document-uri))
    (unless (and conn uri)
      (user-error "[lsp-ltex-plus] This buffer is not being checked"))
    (append (jsonrpc-request
             conn 'textDocument/codeAction
             (list :textDocument (list :uri uri)
                   :range (list :start (lsp-ltex-plus--point-to-position beg)
                                :end (lsp-ltex-plus--point-to-position end))
                   :context (list :diagnostics
                                  (vconcat (lsp-ltex-plus--diagnostics-in beg end))))
             :timeout 10)
            nil)))

(provide 'lsp-ltex-plus-actions)
;;; lsp-ltex-plus-actions.el ends here
