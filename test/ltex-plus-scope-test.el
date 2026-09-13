;;; ltex-plus-scope-test.el --- Per-document configuration replies -*- lexical-binding: t; -*-

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:

;; The server tags every configuration pull with the `scopeUri' of the
;; document it is about to check, and this client answers each item from
;; that document's buffer.  What the tests assert is the part that would
;; silently regress: that two documents in one session get two different
;; answers, and that a document nobody holds any more is answered with
;; the global settings rather than with somebody else's.
;;
;; The URI-to-buffer table is filled by opening documents, so most of
;; this runs against the fake server.

;;; Code:

(require 'ltex-plus-test-helper)
(require 'ltex-plus-fake-server)

(defconst ltex-plus-scope-test--project-spec
  '((".dir-locals.el"
     . "((nil . ((lsp-ltex-plus-language . \"de-DE\"))))")
    ("german/doc.rst" . "text\n"))
  "A document governed by a `.dir-locals.el' that sets the language.")

(defmacro ltex-plus-scope-test--with-documents (&rest body)
  "Run BODY with `german' and `plain' bound to two buffers open on the fake.
Only `german' is under a `.dir-locals.el'; it sets the checking language
to de-DE, which is the difference every test here looks for.  `plain'
lives in a root of its own so that nothing governs it."
  (declare (indent 0) (debug t))
  `(ltex-plus-fake-with-connection
     (ltex-plus-test-with-project ltex-plus-scope-test--project-spec
       (let* ((other-root (file-name-as-directory
                           (make-temp-file "ltex-plus-test-plain-" t)))
              (plain-file (expand-file-name "doc.rst" other-root)))
         (unwind-protect
             (progn
               (ltex-plus-test-write-file plain-file "text\n")
               (let ((german (ltex-plus-test-visit
                              (expand-file-name "german/doc.rst" ltex-plus-test-root)))
                     (plain (ltex-plus-test-visit plain-file)))
                 (ignore german plain)
                 (dolist (buffer (list german plain))
                   (with-current-buffer buffer (rst-mode))
                   (lsp-ltex-plus--open-document buffer))
                 (ltex-plus-fake-wait-for
                  (lambda () (= 2 (length (ltex-plus-fake-received 'textDocument/didOpen)))))
                 ,@body))
           (delete-directory other-root t))))))

(defun ltex-plus-scope-test--answer (&rest items)
  "Return the reply to a `workspace/configuration' request for ITEMS.
Each item is (URI . SECTION)."
  (lsp-ltex-plus--answer-configuration
   (list :items (vconcat (mapcar (lambda (item)
                                   (list :scopeUri (car item) :section (cdr item)))
                                 items)))))

;;;; -- Directory-local values reach the buffer --------------------------------

(ert-deftest ltex-plus-scope-test-dir-locals-apply-to-the-buffer ()
  "The premise: a `.dir-locals.el' really does set the value locally.
If this fails, every other test in this file is measuring nothing."
  (ltex-plus-scope-test--with-documents
    (should (equal (buffer-local-value 'lsp-ltex-plus-language german) "de-DE"))
    (should (equal (buffer-local-value 'lsp-ltex-plus-language plain)
                   (default-value 'lsp-ltex-plus-language)))))

;;;; -- Resolving a document URI back to its buffer ----------------------------

(ert-deftest ltex-plus-scope-test-uri-resolves-to-its-own-buffer ()
  "Each open document's URI finds the buffer holding it."
  (ltex-plus-scope-test--with-documents
    (should (eq (lsp-ltex-plus--buffer-for-uri (lsp-ltex-plus--buffer-uri german)) german))
    (should (eq (lsp-ltex-plus--buffer-for-uri (lsp-ltex-plus--buffer-uri plain)) plain))))

(ert-deftest ltex-plus-scope-test-unknown-uri-resolves-to-nil ()
  "A URI naming no open document answers nil rather than a wrong buffer.
Picking an arbitrary buffer instead is the bug this whole path exists
to avoid."
  (should-not (lsp-ltex-plus--buffer-for-uri "file:///nowhere/doc.rst"))
  (should-not (lsp-ltex-plus--buffer-for-uri nil)))

;;;; -- The answer differs per document ----------------------------------------

(ert-deftest ltex-plus-scope-test-configuration-is-answered-per-document ()
  "Two documents open at once are answered from their own buffers.
This is the point of the exercise."
  (ltex-plus-scope-test--with-documents
    (let ((reply (ltex-plus-scope-test--answer
                  (cons (lsp-ltex-plus--buffer-uri german) "ltex")
                  (cons (lsp-ltex-plus--buffer-uri plain) "ltex"))))
      (should (vectorp reply))
      (should (= 2 (length reply)))
      (should (equal (plist-get (aref reply 0) :language) "de-DE"))
      (should (equal (plist-get (aref reply 1) :language)
                     (default-value 'lsp-ltex-plus-language))))))

(ert-deftest ltex-plus-scope-test-the-order-of-items-is-the-order-of-answers ()
  "Answers come back in the order asked; the server matches by position.
The same two documents asked for the other way round are answered the
other way round."
  (ltex-plus-scope-test--with-documents
    (let ((reply (ltex-plus-scope-test--answer
                  (cons (lsp-ltex-plus--buffer-uri plain) "ltex")
                  (cons (lsp-ltex-plus--buffer-uri german) "ltex"))))
      (should (equal (plist-get (aref reply 0) :language)
                     (default-value 'lsp-ltex-plus-language)))
      (should (equal (plist-get (aref reply 1) :language) "de-DE")))))

(ert-deftest ltex-plus-scope-test-dead-document-answers-globally ()
  "A URI whose buffer is gone is answered with the global settings.
A buffer can be killed between the check starting and the pull arriving.
The server then finishes that check and publishes for a document nothing
displays, so the answer cannot be observed; the reply only has to carry
an entry for it.  What it must not do is answer from whatever buffer
happens to be current: here that is the German one, and the dead
document must not be reported as de-DE."
  (ltex-plus-scope-test--with-documents
    (with-current-buffer german
      (let ((reply (ltex-plus-scope-test--answer '("file:///gone/doc.rst" . "ltex"))))
        (should (= 1 (length reply)))
        (should (equal (plist-get (aref reply 0) :language)
                       (default-value 'lsp-ltex-plus-language)))))))

;;;; -- Sections ---------------------------------------------------------------

(ert-deftest ltex-plus-scope-test-sections-are-read-the-way-the-protocol-spells-them ()
  "No section is the whole configuration; a dotted one is a value inside it.
A section this client does not have is answered with null, which is
what other clients answer and what the server is written to accept."
  (with-temp-buffer
    (setq-local lsp-ltex-plus-language "fr")
    (should (equal (plist-get (plist-get (lsp-ltex-plus--configuration-section nil) :ltex)
                              :language)
                   "fr"))
    (should (equal (plist-get (lsp-ltex-plus--configuration-section "ltex") :language)
                   "fr"))
    (should (equal (lsp-ltex-plus--configuration-section "ltex.language") "fr"))
    (should (equal (lsp-ltex-plus--configuration-section "ltex.trace.server")
                   lsp-ltex-plus-trace-server))
    (should-not (lsp-ltex-plus--configuration-section "ltex.no.such.thing"))
    (should-not (lsp-ltex-plus--configuration-section "python"))))

;;;; -- The server's own request -------------------------------------------------

(ert-deftest ltex-plus-scope-test-custom-handler-answers-one-entry-per-item ()
  "`ltex/workspaceSpecificConfiguration' replies with the four maps per item.
When the client advertises the custom capability the server takes the
four language-keyed settings from here alone, so a missing field means
the document is checked against nothing."
  (ltex-plus-test-reset)
  (setq lsp-ltex-plus-dictionary '(:en-US ["global-word"]))
  (ltex-plus-scope-test--with-documents
    (let ((reply (lsp-ltex-plus--answer-workspace-specific-configuration
                  (list :items (vector (list :scopeUri (lsp-ltex-plus--buffer-uri german))
                                       (list :scopeUri (lsp-ltex-plus--buffer-uri plain)))))))
      (should (vectorp reply))
      (should (= 2 (length reply)))
      (dolist (entry (append reply nil))
        (dolist (field '(:dictionary :disabledRules :enabledRules :hiddenFalsePositives))
          (should (plist-member entry field)))
        (should (equal (ltex-plus-test-words (plist-get entry :dictionary))
                       '("global-word")))))))

(ert-deftest ltex-plus-scope-test-custom-handler-folds-in-the-project-list ()
  "A project's own dictionary is in the entry for its document only.
The other document, in a root with no list of its own, gets the global
list alone; a dead document gets the global list too."
  (ltex-plus-test-reset)
  (setq lsp-ltex-plus-dictionary '(:en-US ["global-word"]))
  (ltex-plus-fake-with-connection
    (ltex-plus-test-with-project
        '((".dir-locals.el"
           . "((nil . ((lsp-ltex-plus-project-dictionary-file . \".ltex/words.eld\"))))")
          (".ltex/words.eld" . "(:en-US [\"Wittgenstein\"])")
          ("doc.rst" . "text\n"))
      (let ((inside (ltex-plus-test-visit (project-file "doc.rst"))))
        (with-current-buffer inside (rst-mode))
        (lsp-ltex-plus--open-document inside)
        (ltex-plus-fake-wait-for (lambda () (ltex-plus-fake-received 'textDocument/didOpen)))
        (let ((reply (lsp-ltex-plus--answer-workspace-specific-configuration
                      (list :items (vector (list :scopeUri (lsp-ltex-plus--buffer-uri inside))
                                           (list :scopeUri "file:///gone/doc.rst"))))))
          (should (equal (ltex-plus-test-words (plist-get (aref reply 0) :dictionary))
                         '("global-word" "Wittgenstein")))
          (should (equal (ltex-plus-test-words (plist-get (aref reply 1) :dictionary))
                         '("global-word"))))))))

;;;; -- Over the wire ----------------------------------------------------------

(ert-deftest ltex-plus-scope-test-the-server-s-pull-is-answered-from-the-document ()
  "The fake's own pull for the German document comes back saying de-DE.
This is the dispatch, end to end: the request arrives with a string id
from the server's numbering, is routed to the handler, and the reply is
built in the right buffer."
  (ltex-plus-scope-test--with-documents
    (let ((uri (lsp-ltex-plus--buffer-uri german)))
      (ltex-plus-fake-wait-for
       (lambda () (seq-find (lambda (entry)
                              (and (equal (car entry) uri)
                                   (eq (cadr entry) 'workspace/configuration)))
                            ltex-plus-fake-config-replies)))
      (let ((entry (seq-find (lambda (entry)
                               (and (equal (car entry) uri)
                                    (eq (cadr entry) 'workspace/configuration)))
                             ltex-plus-fake-config-replies)))
        (should-not (eq (nth 2 entry) :error))
        (should (equal (plist-get (aref (nth 2 entry) 0) :language) "de-DE"))))))

(ert-deftest ltex-plus-scope-test-both-pulls-are-answered-before-the-check ()
  "The fake is as unforgiving as the real server about a refused pull.
Pins the fixture: with both handlers in place the check completes and
diagnostics arrive; a refusal of either would end it.  Both replies for
the document are recorded, and the custom one carries the four maps."
  (ltex-plus-fake-with-connection
    (ltex-plus-test-with-project '(("doc.rst" . "Hello teh world.\n"))
      (let ((buffer (ltex-plus-test-visit (project-file "doc.rst"))))
        (with-current-buffer buffer (rst-mode))
        (lsp-ltex-plus--open-document buffer)
        (ltex-plus-fake-wait-for
         (lambda () (buffer-local-value 'lsp-ltex-plus--diagnostics buffer)))
        (should (equal ltex-plus-fake-strict-pulls
                       '(workspace/configuration ltex/workspaceSpecificConfiguration)))
        (let* ((uri (lsp-ltex-plus--buffer-uri buffer))
               (custom (seq-find (lambda (entry)
                                   (and (equal (car entry) uri)
                                        (eq (cadr entry) 'ltex/workspaceSpecificConfiguration)))
                                 ltex-plus-fake-config-replies)))
          (should custom)
          (should-not (eq (nth 2 custom) :error))
          (should (plist-member (aref (nth 2 custom) 0) :hiddenFalsePositives)))))))

(provide 'ltex-plus-scope-test)
;;; ltex-plus-scope-test.el ends here
