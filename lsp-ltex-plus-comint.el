;;; lsp-ltex-plus-comint.el --- Checking the input region of a comint buffer -*- lexical-binding: t; -*-

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Keywords: lsp, grammar, spelling, convenience
;; URL: https://github.com/ltex-plus/emacs-ltex-plus

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:
;;
;; A comint buffer -- a shell, a REPL, an AI agent shell -- is mostly
;; read-only output, with one editable input region at the bottom: from
;; the process mark to the end of the buffer.  Only that region is worth
;; checking, never the output and never input already submitted.
;;
;; The connection layer lets a buffer say which part of it is the
;; document, through `lsp-ltex-plus--document-region-function'.  What this
;; file adds is the comint answer to that question, and the three things
;; that make it hold up against a live program:
;;
;;   * The region is read from the process mark on every use, so it
;;     tracks itself as output scrolls it down the buffer.
;;   * While the program is producing output the region is empty.  This
;;     is load-bearing, not polish: shell-maker inserts streaming output
;;     at the end of the buffer and advances the process mark only
;;     afterwards, so during the insertion the output sits inside the
;;     region and would be checked, its diagnostics piling up.
;;   * Submitting input empties the region without an edit inside it,
;;     so nothing would send the change; a re-sync after the submission
;;     pushes the now-empty document and the server clears the
;;     underlines on the text that was sent.
;;
;; The prompt shares its line with the input but is not part of the
;; document.  Nothing needs padding for that any more: positions from the
;; server are converted with the region's start as origin, so a column on
;; the first line lands after the prompt by construction.

;;; Code:

(require 'comint)
(require 'lsp-ltex-plus-settings)
(require 'lsp-ltex-plus-conn)

(defun lsp-ltex-plus--comint-input-start ()
  "Return the position where the active comint input begins.
The process mark, which comint keeps at the boundary between output
above and the input being typed below; failing that the end of the
last prompt, and failing that the end of the buffer."
  (let ((process (get-buffer-process (current-buffer))))
    (cond
     ((and process (marker-position (process-mark process)))
      (marker-position (process-mark process)))
     ((and (boundp 'comint-last-prompt) comint-last-prompt)
      (cdr comint-last-prompt))
     (t (point-max)))))

(defun lsp-ltex-plus--comint-input-ready-p ()
  "Return non-nil when the comint buffer is waiting for the user to type.
While the program is producing output there is no input to check and
the region must read as empty; see the Commentary for why.  Keyed on
`shell-maker--busy'; a plain comint buffer, where that variable is
unbound, is always ready."
  (not (bound-and-true-p shell-maker--busy)))

(defun lsp-ltex-plus--comint-input-region ()
  "Return (BEG . END), the part of the comint buffer that is the document.
The input region while the buffer is ready for input; nil while the
program is busy, so that nothing streaming in is ever sent."
  (when (lsp-ltex-plus--comint-input-ready-p)
    (let ((end (point-max)))
      (cons (min (lsp-ltex-plus--comint-input-start) end) end))))

(defun lsp-ltex-plus--comint-on-submit (_input)
  "Re-send the document after the user submits input.
On `comint-input-filter-functions'.  Deferred to a zero-delay timer so
that comint has moved the process mark and echoed the input before the
now-empty region is read."
  (when lsp-ltex-plus--comint-active
    (let ((buffer (current-buffer)))
      (run-with-timer 0 nil
                      (lambda ()
                        (when (buffer-live-p buffer)
                          (with-current-buffer buffer
                            (when lsp-ltex-plus--comint-active
                              (lsp-ltex-plus--schedule-change)))))))))

(defun lsp-ltex-plus--comint-setup ()
  "Make the current comint buffer's document its input region.
Installs the region function and the submit hook; idempotent."
  (setq lsp-ltex-plus--document-region-function #'lsp-ltex-plus--comint-input-region
        lsp-ltex-plus--comint-active t)
  (add-hook 'comint-input-filter-functions #'lsp-ltex-plus--comint-on-submit nil t))

(defun lsp-ltex-plus--comint-teardown ()
  "Stop treating the current buffer's input region as the document.
Idempotent.  Closing the document itself is the connection layer's job;
this removes only what `lsp-ltex-plus--comint-setup' added."
  (when lsp-ltex-plus--comint-active
    (setq lsp-ltex-plus--comint-active nil
          lsp-ltex-plus--document-region-function nil)
    (remove-hook 'comint-input-filter-functions #'lsp-ltex-plus--comint-on-submit t)))

(defun lsp-ltex-plus--comint-buffer-p ()
  "Return non-nil if the current buffer is a comint buffer with a live process."
  (and (not buffer-file-name)
       (derived-mode-p 'comint-mode)
       (get-buffer-process (current-buffer))
       t))

;; A major-mode change discards the buffer-local hook and region function
;; anyway; clearing the flag first keeps the timer a submit may have
;; started from sending a stale document.
(add-hook 'lsp-ltex-plus--document-closing-functions #'lsp-ltex-plus--comint-teardown)

(provide 'lsp-ltex-plus-comint)
;;; lsp-ltex-plus-comint.el ends here
