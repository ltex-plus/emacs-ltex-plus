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

;;;; -- Applying an edit ---------------------------------------------------------

;; A replacement suggestion is a `WorkspaceEdit'.  The positions in it are
;; relative to the text the server checked, so every edit is resolved to
;; points before any is applied, and they are applied from the end of the
;; buffer backwards so that no edit moves the text of one still to come.
;; The version the server names must be the version the buffer is at,
;; and nothing may be waiting to be sent: either would mean the positions
;; describe a text the buffer no longer holds.

(defun lsp-ltex-plus--edit-buffer (uri)
  "Return the buffer an edit for URI applies to.
The buffer open under URI, or failing that one visiting the file it
names; signals a `user-error' when there is neither."
  (or (lsp-ltex-plus--buffer-for-uri uri)
      (get-file-buffer (lsp-ltex-plus--uri-to-path uri))
      (user-error "[lsp-ltex-plus] The edit is for %s, which no buffer holds" uri)))

(defun lsp-ltex-plus--text-edits-by-document (edit)
  "Return the text edits in the `WorkspaceEdit' EDIT, grouped by document.
A list of (URI VERSION . EDITS), one per document, in the order given.
VERSION is the document version the server based the edits on, or nil
where it named none.  Only text edits are accepted: an operation on a
file itself -- create, rename, delete -- is refused with a `user-error',
since a grammar checker has no business sending one."
  (let ((result nil))
    (seq-doseq (change (plist-get edit :documentChanges))
      (if-let* ((document (plist-get change :textDocument)))
          (push (cons (plist-get document :uri)
                      (cons (plist-get document :version)
                            (append (plist-get change :edits) nil)))
                result)
        (user-error "[lsp-ltex-plus] The edit wants to %s a file, which this client does not do"
                    (plist-get change :kind))))
    ;; `changes' is an object keyed by URI, which jsonrpc hands over as a
    ;; plist whose keys are the URIs read as keywords.
    (let ((changes (plist-get edit :changes)))
      (while (and (consp changes) (keywordp (car changes)))
        (push (cons (substring (symbol-name (pop changes)) 1)
                    (cons nil (append (pop changes) nil)))
              result)))
    (nreverse result)))

(defun lsp-ltex-plus--apply-text-edits (buffer edits)
  "Apply the protocol text EDITS to BUFFER as one change.
All positions are resolved first, against the text as it is; the edits
are then applied from the end backwards, and two edits at the same
position keep the order the server gave them, as the protocol requires."
  (with-current-buffer buffer
    (let* ((index -1)
           (resolved
            (mapcar (lambda (edit)
                      (let ((range (plist-get edit :range)))
                        (list (lsp-ltex-plus--position-to-point (plist-get range :start))
                              (lsp-ltex-plus--position-to-point (plist-get range :end))
                              (plist-get edit :newText)
                              (cl-incf index))))
                    edits))
           (ordered (sort resolved
                          (lambda (a b)
                            (or (> (car a) (car b))
                                (and (= (car a) (car b))
                                     (> (nth 3 a) (nth 3 b))))))))
      (atomic-change-group
        (save-excursion
          (pcase-dolist (`(,beg ,end ,text ,_) ordered)
            (goto-char beg)
            (delete-region beg end)
            (insert text)))))))

(defun lsp-ltex-plus--apply-workspace-edit (edit)
  "Apply the `WorkspaceEdit' EDIT to the buffers it names.
Every document is checked before any is touched: each must have a
buffer, be at the version the server named, and have no edit waiting to
be sent.  Returns the number of documents edited."
  (let ((documents (lsp-ltex-plus--text-edits-by-document edit)))
    (pcase-dolist (`(,uri ,version . ,_) documents)
      (let ((buffer (lsp-ltex-plus--edit-buffer uri)))
        (when (or (buffer-local-value 'lsp-ltex-plus--change-timer buffer)
                  (and version
                       (/= version (buffer-local-value 'lsp-ltex-plus--document-version
                                                       buffer))))
          (user-error "[lsp-ltex-plus] %s has changed since the server looked at it; wait for the next check"
                      (buffer-name buffer)))))
    (pcase-dolist (`(,uri ,_ . ,edits) documents)
      (lsp-ltex-plus--apply-text-edits (lsp-ltex-plus--edit-buffer uri) edits))
    (length documents)))

(provide 'lsp-ltex-plus-actions)
;;; lsp-ltex-plus-actions.el ends here
