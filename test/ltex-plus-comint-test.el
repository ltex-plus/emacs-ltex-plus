;;; ltex-plus-comint-test.el --- The input region of a comint buffer -*- lexical-binding: t; -*-

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:

;; In a comint buffer the document is the input region, from the process
;; mark to the end of the buffer.  What is asserted here: that only that
;; text goes to the server, that the server's positions come back on the
;; right characters past the prompt, that output arriving above the
;; region sends nothing, that a busy program empties the region, and
;; that submitting clears the underlines on what was sent.
;;
;; The process is a pipe of Emacs' own, which is all comint needs for a
;; process mark; the input sender is stubbed so a submission writes
;; nowhere.

;;; Code:

(require 'ltex-plus-test-helper)
(require 'ltex-plus-fake-server)

(defmacro ltex-plus-comint-test--with-shell (var output prompt input &rest body)
  "Run BODY with VAR a comint buffer of OUTPUT, PROMPT and INPUT, open on the fake.
The process mark sits after PROMPT, so INPUT is the document.  The mode
is on and BODY starts once the document is open."
  (declare (indent 4) (debug (symbolp form form form body)))
  `(ltex-plus-fake-with-connection
     (let* ((,var (generate-new-buffer "*ltex-plus-comint-test*"))
            (process (make-pipe-process :name "ltex-plus-comint-test" :buffer ,var
                                        :noquery t))
            (inhibit-message t)
            (lsp-ltex-plus-change-delay 0.1))
       (unwind-protect
           (progn
             (with-current-buffer ,var
               (comint-mode)
               (setq-local comint-input-sender #'ignore)
               (insert ,output ,prompt)
               (set-marker (process-mark process) (point))
               (insert ,input)
               (lsp-ltex-plus-mode 1))
             (ltex-plus-fake-wait-for
              (lambda () (ltex-plus-fake-received 'textDocument/didOpen)))
             ,@body)
         (ignore-errors (delete-process process))
         (when (buffer-live-p ,var)
           (with-current-buffer ,var (set-buffer-modified-p nil))
           (kill-buffer ,var))))))

(defun ltex-plus-comint-test--last-text (method)
  "Return the document text the fake last received through METHOD."
  (when-let* ((params (car (last (ltex-plus-fake-received method)))))
    (pcase method
      ('textDocument/didOpen (plist-get (plist-get params :textDocument) :text))
      ('textDocument/didChange
       (plist-get (aref (plist-get params :contentChanges) 0) :text)))))

;;;; -- What is sent -------------------------------------------------------------

(ert-deftest ltex-plus-comint-test-only-the-input-is-the-document ()
  "The text sent is the input after the prompt, not the output or the prompt."
  (ltex-plus-comint-test--with-shell buffer "previous output\n" "shell> " "He go to school."
    (should (equal (ltex-plus-comint-test--last-text 'textDocument/didOpen)
                   "He go to school."))
    (should (buffer-local-value 'lsp-ltex-plus--comint-active buffer))))

(ert-deftest ltex-plus-comint-test-diagnostics-land-past-the-prompt ()
  "A diagnostic at column 0 of the document underlines the first input character.
The prompt shares the line; the region's start is the origin, so no
padding is needed and the prompt is never underlined."
  (ltex-plus-comint-test--with-shell buffer "out\n" "$ " "teh end"
    (ltex-plus-fake-wait-for
     (lambda () (buffer-local-value 'lsp-ltex-plus--diagnostics buffer)))
    (with-current-buffer buffer
      (let ((start (lsp-ltex-plus--comint-input-start)))
        (should (equal (lsp-ltex-plus--diagnostic-region (car lsp-ltex-plus--diagnostics))
                       (cons start (+ start 3))))
        (should (equal (buffer-substring start (+ start 3)) "teh"))))))

(ert-deftest ltex-plus-comint-test-an-edit-in-the-input-is-sent ()
  "Typing in the input region sends the region as the whole document."
  (ltex-plus-comint-test--with-shell buffer "out\n" "$ " "He go"
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert " to school."))
    (ltex-plus-fake-wait-for (lambda () (ltex-plus-fake-received 'textDocument/didChange)))
    (should (equal (ltex-plus-comint-test--last-text 'textDocument/didChange)
                   "He go to school."))))

(ert-deftest ltex-plus-comint-test-output-above-the-input-sends-nothing ()
  "Output inserted above the process mark is outside the document and sends nothing."
  (ltex-plus-comint-test--with-shell buffer "out\n" "$ " "typing"
    (with-current-buffer buffer
      (save-excursion
        (goto-char (point-min))
        (insert "more output\n")))
    (accept-process-output nil 0.3)
    (should-not (ltex-plus-fake-received 'textDocument/didChange))
    ;; And the region followed the mark: the document is still the input.
    (with-current-buffer buffer
      (should (equal (lsp-ltex-plus--document-text) "typing")))))

;;;; -- The busy gate ------------------------------------------------------------

(ert-deftest ltex-plus-comint-test-a-busy-program-empties-the-document ()
  "While the program streams output the document is empty and edits send nothing.
shell-maker inserts output at the end of the buffer before moving the
mark, so without this the reply would be checked as if typed."
  (ltex-plus-comint-test--with-shell buffer "out\n" "$ " "typed"
    (with-current-buffer buffer
      (defvar shell-maker--busy)
      (setq-local shell-maker--busy t)
      (should (equal (lsp-ltex-plus--document-text) ""))
      (goto-char (point-max))
      (insert " streamed reply text"))
    (accept-process-output nil 0.3)
    (should-not (ltex-plus-fake-received 'textDocument/didChange))
    (with-current-buffer buffer
      (setq-local shell-maker--busy nil)
      (should (equal (lsp-ltex-plus--document-text) "typed streamed reply text")))))

;;;; -- Submitting ---------------------------------------------------------------

(ert-deftest ltex-plus-comint-test-submitting-clears-the-underlines ()
  "After the input is sent, the empty document goes out and the diagnostics clear."
  (ltex-plus-comint-test--with-shell buffer "out\n" "$ " "teh end"
    (ltex-plus-fake-wait-for
     (lambda () (buffer-local-value 'lsp-ltex-plus--diagnostics buffer)))
    (with-current-buffer buffer
      (goto-char (point-max))
      (comint-send-input))
    (ltex-plus-fake-wait-for
     (lambda () (equal (ltex-plus-comint-test--last-text 'textDocument/didChange) "")))
    (ltex-plus-fake-wait-for
     (lambda () (null (buffer-local-value 'lsp-ltex-plus--diagnostics buffer))))))

;;;; -- Turning it off -----------------------------------------------------------

(ert-deftest ltex-plus-comint-test-disabling-detaches-the-region ()
  "Switching the mode off removes the region function and the submit hook."
  (ltex-plus-comint-test--with-shell buffer "out\n" "$ " "typed"
    (with-current-buffer buffer
      (lsp-ltex-plus-mode -1)
      (should-not lsp-ltex-plus--comint-active)
      (should-not lsp-ltex-plus--document-region-function)
      (should-not (memq #'lsp-ltex-plus--comint-on-submit comint-input-filter-functions)))
    (ltex-plus-fake-wait-for (lambda () (ltex-plus-fake-received 'textDocument/didClose)))))

(ert-deftest ltex-plus-comint-test-opting-out-leaves-comint-alone ()
  "With `lsp-ltex-plus-check-comint-input' off the mode declines a comint buffer."
  (ltex-plus-fake-with-connection
    (let* ((buffer (generate-new-buffer "*ltex-plus-comint-test-off*"))
           (process (make-pipe-process :name "ltex-plus-comint-test" :buffer buffer
                                       :noquery t))
           (inhibit-message t))
      (unwind-protect
          (with-current-buffer buffer
            (comint-mode)
            (let ((lsp-ltex-plus-check-comint-input nil))
              (lsp-ltex-plus-mode 1))
            (should-not lsp-ltex-plus-mode)
            (should-not lsp-ltex-plus--comint-active))
        (ignore-errors (delete-process process))
        (kill-buffer buffer)))))

(provide 'ltex-plus-comint-test)
;;; ltex-plus-comint-test.el ends here
