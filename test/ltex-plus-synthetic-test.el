;;; ltex-plus-synthetic-test.el --- Buffers that visit no file -*- lexical-binding: t; -*-

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:

;; A buffer with no file -- `*scratch*', a capture buffer, a draft -- is
;; checked under an identity the package invents.  The server treats the
;; URI as an opaque name, so there is no synthetic file, no path under
;; the temporary directory and nothing on disk: just a URI in the table
;; that maps documents to buffers.  What has to hold is that the identity
;; is unique, that it is reused while the buffer lives, that everything
;; addressed to it -- diagnostics, edits, configuration pulls -- reaches
;; the buffer, and that saving the buffer to a file hands the document
;; over to the file's own name without leaving the old one open.

;;; Code:

(require 'ltex-plus-test-helper)
(require 'ltex-plus-fake-server)

;;;; -- The identity ------------------------------------------------------------

(ert-deftest ltex-plus-synthetic-test-uris-are-unique-and-not-files ()
  "Each invented URI is new, carries the package's own scheme, and names no file."
  (let ((first (lsp-ltex-plus--make-fileless-uri))
        (second (lsp-ltex-plus--make-fileless-uri)))
    (should-not (equal first second))
    (dolist (uri (list first second))
      (should (string-prefix-p "ltex-plus://buffer/" uri))
      (should (string-match-p (format "/%d-[0-9]+\\'" (emacs-pid)) uri)))))

(defmacro ltex-plus-synthetic-test--with-scratch (var contents &rest body)
  "Run BODY with VAR bound to a file-less buffer of CONTENTS, checked by the fake.
The buffer is in `text-mode' with the mode on; BODY starts once the
document is open on the fake."
  (declare (indent 2) (debug (symbolp form body)))
  `(ltex-plus-fake-with-connection
     (let ((,var (generate-new-buffer "*ltex-plus-synthetic-test*"))
           (inhibit-message t)
           (lsp-ltex-plus-change-delay 0.1))
       (unwind-protect
           (progn
             (with-current-buffer ,var
               (text-mode)
               (insert ,contents)
               (lsp-ltex-plus-mode 1))
             (ltex-plus-fake-wait-for
              (lambda () (ltex-plus-fake-received 'textDocument/didOpen)))
             ,@body)
         (when (buffer-live-p ,var)
           (with-current-buffer ,var (set-buffer-modified-p nil))
           (kill-buffer ,var))))))

(ert-deftest ltex-plus-synthetic-test-a-scratch-buffer-is-checked ()
  "A buffer with no file opens under an invented URI and gets its diagnostics."
  (ltex-plus-synthetic-test--with-scratch buffer "Hello teh world.\n"
    (let ((uri (buffer-local-value 'lsp-ltex-plus--document-uri buffer)))
      (should (string-prefix-p "ltex-plus://buffer/" uri))
      (should (equal (plist-get (plist-get (car (ltex-plus-fake-received 'textDocument/didOpen))
                                           :textDocument)
                                :uri)
                     uri))
      (should (eq (lsp-ltex-plus--buffer-for-uri uri) buffer))
      (ltex-plus-fake-wait-for
       (lambda () (buffer-local-value 'lsp-ltex-plus--diagnostics buffer)))
      (should (= 1 (length (buffer-local-value 'lsp-ltex-plus--diagnostics buffer)))))))

(ert-deftest ltex-plus-synthetic-test-the-identity-is-kept-while-the-buffer-lives ()
  "Turning the mode off and on again reopens under the same URI."
  (ltex-plus-synthetic-test--with-scratch buffer "Text.\n"
    (let ((uri (buffer-local-value 'lsp-ltex-plus--document-uri buffer)))
      (with-current-buffer buffer
        (lsp-ltex-plus-mode -1)
        (should-not lsp-ltex-plus--document-uri)
        (should (equal lsp-ltex-plus--fileless-uri uri))
        (lsp-ltex-plus-mode 1))
      (ltex-plus-fake-wait-for
       (lambda () (= 2 (length (ltex-plus-fake-received 'textDocument/didOpen)))))
      (should (equal (buffer-local-value 'lsp-ltex-plus--document-uri buffer) uri)))))

(ert-deftest ltex-plus-synthetic-test-the-configuration-pull-reaches-the-buffer ()
  "The server's pull for the synthetic URI is answered from the buffer.
A file-less buffer has no directory-local variables, so it gets the
global settings; what matters is that it is found at all."
  (ltex-plus-synthetic-test--with-scratch buffer "Text.\n"
    (with-current-buffer buffer (setq-local lsp-ltex-plus-language "fr"))
    (let* ((uri (buffer-local-value 'lsp-ltex-plus--document-uri buffer))
           (reply (lsp-ltex-plus--answer-configuration
                   (list :items (vector (list :scopeUri uri :section "ltex"))))))
      (should (equal (plist-get (aref reply 0) :language) "fr")))))

(ert-deftest ltex-plus-synthetic-test-an-edit-reaches-the-buffer ()
  "A replacement addressed to the synthetic URI lands in the buffer.
This is what used to need global advice: the URI names no file, so a
lookup by file name would have opened a phantom buffer instead."
  (ltex-plus-synthetic-test--with-scratch buffer "Hello teh world.\n"
    (let ((uri (buffer-local-value 'lsp-ltex-plus--document-uri buffer)))
      (lsp-ltex-plus--apply-workspace-edit
       (list :documentChanges
             (vector (list :textDocument (list :version 1 :uri uri)
                           :edits (vector (list :range '(:start (:line 0 :character 6)
                                                         :end (:line 0 :character 9))
                                                :newText "the"))))))
      (should (equal (with-current-buffer buffer (buffer-string)) "Hello the world.\n")))))

;;;; -- Saving to a file --------------------------------------------------------

(ert-deftest ltex-plus-synthetic-test-saving-hands-the-document-over ()
  "Saved to a file of the same mode, the buffer is closed and reopened by name.
`text-mode' to a `.txt' file keeps the major mode, so nothing resets the
buffer's variables; the visited-file-name hook alone does the handover."
  (ltex-plus-synthetic-test--with-scratch buffer "Hello teh world.\n"
    (let* ((synthetic (buffer-local-value 'lsp-ltex-plus--document-uri buffer))
           (dir (file-name-as-directory (make-temp-file "ltex-plus-synthetic-" t)))
           (path (expand-file-name "saved.txt" dir)))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (let ((inhibit-message t)) (write-file path))
              (should (equal buffer-file-name path))
              (should lsp-ltex-plus-mode))
            (ltex-plus-fake-wait-for
             (lambda () (= 2 (length (ltex-plus-fake-received 'textDocument/didOpen)))))
            (should (equal (plist-get (plist-get (car (ltex-plus-fake-received
                                                       'textDocument/didClose))
                                                 :textDocument)
                                      :uri)
                           synthetic))
            (should (equal (buffer-local-value 'lsp-ltex-plus--document-uri buffer)
                           (lsp-ltex-plus--path-to-uri path)))
            (should-not (buffer-local-value 'lsp-ltex-plus--fileless-uri buffer))
            (should-not (lsp-ltex-plus--buffer-for-uri synthetic))
            (should (eq (lsp-ltex-plus--buffer-for-uri (lsp-ltex-plus--path-to-uri path))
                        buffer)))
        (delete-directory dir t)))))

(ert-deftest ltex-plus-synthetic-test-a-mode-change-closes-the-document-first ()
  "Saved under a name that changes the major mode, the old document is closed.
The mode change discards the buffer's local variables; the document is
closed before that happens, so the server is not left holding it.  With
the dispatcher installed, the buffer is then reopened under its file
name in the new mode, as in a real session."
  (ltex-plus-synthetic-test--with-scratch buffer "Hello teh world.\n"
    (let* ((synthetic (buffer-local-value 'lsp-ltex-plus--document-uri buffer))
           (dir (file-name-as-directory (make-temp-file "ltex-plus-synthetic-" t)))
           (path (expand-file-name "saved.rst" dir))
           (after-change-major-mode-hook after-change-major-mode-hook)
           (lsp-ltex-plus--enabled-modes lsp-ltex-plus--enabled-modes))
      (lsp-ltex-plus-enable-for-modes :restrict-to '(rst-mode))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (let ((inhibit-message t)) (write-file path))
              (should (eq major-mode 'rst-mode))
              (should lsp-ltex-plus-mode))
            (ltex-plus-fake-wait-for
             (lambda () (= 2 (length (ltex-plus-fake-received 'textDocument/didOpen)))))
            (should (equal (plist-get (plist-get (car (ltex-plus-fake-received
                                                       'textDocument/didClose))
                                                 :textDocument)
                                      :uri)
                           synthetic))
            (should (equal (buffer-local-value 'lsp-ltex-plus--document-uri buffer)
                           (lsp-ltex-plus--path-to-uri path)))
            (should-not (lsp-ltex-plus--buffer-for-uri synthetic)))
        (delete-directory dir t)))))

(ert-deftest ltex-plus-synthetic-test-a-mode-change-without-the-dispatcher-just-closes ()
  "Changing the major mode by hand closes the document and clears the underlines.
Without the dispatcher nothing turns the mode back on, and nothing is
left open on the server or shown in the buffer."
  (ltex-plus-synthetic-test--with-scratch buffer "Hello teh world.\n"
    (with-current-buffer buffer
      (flymake-start)
      (ltex-plus-fake-wait-for (lambda () (flymake-diagnostics)))
      (let ((after-change-major-mode-hook nil))
        (fundamental-mode))
      (should-not lsp-ltex-plus--document-uri)
      (should-not (flymake-diagnostics)))
    (ltex-plus-fake-wait-for (lambda () (ltex-plus-fake-received 'textDocument/didClose)))
    (should (zerop (hash-table-count lsp-ltex-plus--documents)))))

(provide 'ltex-plus-synthetic-test)
;;; ltex-plus-synthetic-test.el ends here
