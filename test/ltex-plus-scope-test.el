;;; ltex-plus-scope-test.el --- Per-document configuration replies -*- lexical-binding: t; -*-

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:

;; The server tags every configuration pull with the `scopeUri' of the
;; document it is about to check.  lsp-mode's generic responder ignores
;; that tag and answers from whichever buffer comes first in the
;; workspace's buffer list, so with two projects open one project's
;; `.dir-locals.el' can end up answering for the other's documents.  This
;; package replaces the responder for its own client and resolves the URI
;; instead.
;;
;; Nothing here needs a live server: the two handlers are ordinary
;; functions of (WORKSPACE PARAMS), and a workspace is only used to bind
;; `lsp--cur-workspace' and to supply a fallback root.  What the tests
;; assert is the part that would silently regress -- that two documents in
;; one session get two different answers.

;;; Code:

(require 'ltex-plus-test-helper)

(defconst ltex-plus-scope-test--project-spec
  '((".dir-locals.el"
     . "((nil . ((lsp-ltex-plus-language . \"de-DE\"))))")
    ("german/doc.md" . "text\n")
    ("plain/doc.md"  . "text\n"))
  "Two documents, of which only the first is governed by a `.dir-locals.el'.")

(defmacro ltex-plus-scope-test--with-documents (&rest body)
  "Run BODY with `german' and `plain' bound to two visiting buffers.
Only `german' is under a `.dir-locals.el'; it sets the checking language
to de-DE, which is the difference every test here looks for."
  (declare (indent 0) (debug t))
  `(ltex-plus-test-with-project ltex-plus-scope-test--project-spec
     ;; The `.dir-locals.el' sits at the root and governs `german/doc.md';
     ;; `plain/doc.md' gets its own root so that nothing governs it.
     (let* ((other-root (file-name-as-directory
                         (make-temp-file "ltex-plus-test-plain-" t)))
            (plain-file (expand-file-name "doc.md" other-root)))
       (unwind-protect
           (progn
             (ltex-plus-test-write-file plain-file "text\n")
             (let ((german (ltex-plus-test-visit
                            (expand-file-name "german/doc.md" ltex-plus-test-root)))
                   (plain (ltex-plus-test-visit plain-file)))
               (ignore german plain)
               ,@body))
         (delete-directory other-root t)))))

(defun ltex-plus-scope-test--uri (buffer)
  "Return the LSP document URI BUFFER would be opened under."
  (with-current-buffer buffer (lsp--buffer-uri)))

(defun ltex-plus-scope-test--setting (section key)
  "Return KEY from SECTION, the object `--configuration-section' returns.
That object is always a hash table keyed by the JSON name, whatever
representation `lsp-mode' uses for the messages it parses -- it is built
by lsp-mode's own `lsp--section-workspace-configuration', not received
over the wire."
  (gethash key section))

(defun ltex-plus-scope-test--language-for (uri)
  "Return the checking language the client would report for URI."
  (let ((buffer (lsp-ltex-plus--buffer-for-uri uri)))
    (if buffer
        (with-current-buffer buffer
          (ltex-plus-scope-test--setting
           (lsp-ltex-plus--configuration-section "ltex") "language"))
      'no-buffer)))

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
  "Each document's URI finds the buffer visiting it."
  (ltex-plus-scope-test--with-documents
    (should (eq (lsp-ltex-plus--buffer-for-uri (ltex-plus-scope-test--uri german))
                german))
    (should (eq (lsp-ltex-plus--buffer-for-uri (ltex-plus-scope-test--uri plain))
                plain))))

(ert-deftest ltex-plus-scope-test-unknown-uri-resolves-to-nil ()
  "A URI naming no live buffer answers nil rather than a wrong buffer.
The caller falls back to a temp buffer under the workspace root; picking
an arbitrary buffer instead is the bug this whole path exists to avoid."
  (should-not (lsp-ltex-plus--buffer-for-uri "file:///nowhere/doc.md"))
  (should-not (lsp-ltex-plus--buffer-for-uri nil)))

(ert-deftest ltex-plus-scope-test-synthetic-uri-resolves-to-its-buffer ()
  "A file-less buffer is found by the synthetic URI it carries.
It visits no file, so Emacs' file-to-buffer index cannot find it; the
marker `lsp-ltex-plus--fileless-uri' is what identifies it as ours."
  (let ((buffer (generate-new-buffer " *ltex-plus-scope-test-fileless*"))
        (uri "file:///tmp/lsp-ltex-plus-scratch-1-1.txt"))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq-local lsp-ltex-plus--fileless-uri uri)
            (setq-local lsp-buffer-uri uri))
          (should (eq (lsp-ltex-plus--buffer-for-uri uri) buffer)))
      (kill-buffer buffer))))

(ert-deftest ltex-plus-scope-test-unmarked-buffer-is-not-claimed ()
  "A buffer carrying `lsp-buffer-uri' but not our marker is not ours.
Another client may set `lsp-buffer-uri' for its own purposes; only
buffers this package gave a synthetic identity to are matched."
  (let ((buffer (generate-new-buffer " *ltex-plus-scope-test-foreign*"))
        (uri "file:///tmp/some-other-client.txt"))
    (unwind-protect
        (progn
          (with-current-buffer buffer (setq-local lsp-buffer-uri uri))
          (should-not (lsp-ltex-plus--buffer-for-uri uri)))
      (kill-buffer buffer))))

;;;; -- The answer differs per document ----------------------------------------

(ert-deftest ltex-plus-scope-test-configuration-is-answered-per-document ()
  "Two documents open at once are answered from their own buffers.
This is the point of the exercise: with lsp-mode's generic responder
both would get whichever value happened to be first in the workspace."
  (ltex-plus-scope-test--with-documents
    (should (equal (ltex-plus-scope-test--language-for
                    (ltex-plus-scope-test--uri german))
                   "de-DE"))
    (should (equal (ltex-plus-scope-test--language-for
                    (ltex-plus-scope-test--uri plain))
                   (default-value 'lsp-ltex-plus-language)))))

(ert-deftest ltex-plus-scope-test-handler-answers-one-entry-per-item ()
  "`workspace/configuration' replies with a vector, in the order asked.
The server matches replies to requests by position, so a dropped or
reordered entry misfiles one document's settings under another's."
  (ltex-plus-scope-test--with-documents
    (let* ((workspace (ltex-plus-test-workspace))
           (params (ltex-plus-test-obj
                    :items (vector
                            (ltex-plus-test-obj
                             :scopeUri (ltex-plus-scope-test--uri german)
                             :section "ltex")
                            (ltex-plus-test-obj
                             :scopeUri (ltex-plus-scope-test--uri plain)
                             :section "ltex"))))
           (reply (lsp-ltex-plus--request-configuration workspace params)))
      (should (vectorp reply))
      (should (= (length reply) 2))
      (should (equal (ltex-plus-scope-test--setting (aref reply 0) "language")
                     "de-DE"))
      (should (equal (ltex-plus-scope-test--setting (aref reply 1) "language")
                     (default-value 'lsp-ltex-plus-language))))))

(ert-deftest ltex-plus-scope-test-custom-handler-answers-one-entry-per-item ()
  "`ltex/workspaceSpecificConfiguration' replies with the four maps.
When the client advertises the custom capability the server takes the
four language-keyed settings from here alone, so a missing field means
the document is checked against nothing."
  (ltex-plus-test-reset)
  (setq lsp-ltex-plus--dictionary-merged '(:en-US ["global-word"]))
  (ltex-plus-scope-test--with-documents
    (let* ((workspace (ltex-plus-test-workspace))
           (params (ltex-plus-test-obj
                    :items (vector (ltex-plus-test-obj
                                    :scopeUri (ltex-plus-scope-test--uri german)))))
           (reply (lsp-ltex-plus--request-workspace-specific-configuration
                   workspace params)))
      (should (= (length reply) 1))
      (let ((entry (aref reply 0)))
        (dolist (field '(:dictionary :disabledRules :enabledRules
                         :hiddenFalsePositives))
          (should (plist-member entry field)))
        (should (equal (ltex-plus-test-words (plist-get entry :dictionary))
                       '("global-word")))))))

(ert-deftest ltex-plus-scope-test-dead-document-falls-back-to-the-root ()
  "A URI whose buffer is gone is answered from the workspace root.
The buffer can be killed between the check starting and the pull
arriving; a project's settings should still answer for its own files."
  (ltex-plus-test-with-project ltex-plus-scope-test--project-spec
    (let* ((workspace (ltex-plus-test-workspace
                       (expand-file-name "german" ltex-plus-test-root)))
           (params (ltex-plus-test-obj
                    :items (vector (ltex-plus-test-obj
                                    :scopeUri "file:///gone/doc.md"
                                    :section "ltex"))))
           (enable-local-variables :all)
           (reply (lsp-ltex-plus--request-configuration workspace params)))
      (should (equal (ltex-plus-scope-test--setting (aref reply 0) "language")
                     "de-DE")))))

(provide 'ltex-plus-scope-test)
;;; ltex-plus-scope-test.el ends here
