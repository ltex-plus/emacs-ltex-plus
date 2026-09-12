;;; ltex-plus-actions-test.el --- Code actions, offline -*- lexical-binding: t; -*-

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:

;; Asking the server for code actions and carrying the chosen one out.
;; The fake answers the request with whatever `ltex-plus-fake-code-actions'
;; holds, shaped like what the real server was seen to send, so what is
;; asserted here is this side: which diagnostics go out as context, what
;; range is asked about, and what is done with the answer.

;;; Code:

(require 'ltex-plus-test-helper)
(require 'ltex-plus-fake-server)

;;;; -- Which diagnostics are at point ------------------------------------------

(defmacro ltex-plus-actions-test--with-diagnostics (contents &rest body)
  "Run BODY in a buffer of CONTENTS whose stored diagnostics are the fake's."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (insert ,contents)
     (setq lsp-ltex-plus--diagnostics (append (ltex-plus-fake-diagnostics ,contents) nil))
     ,@body))

(ert-deftest ltex-plus-actions-test-point-on-or-just-after-a-word-finds-it ()
  "A point anywhere on the flagged text, its end included, finds the diagnostic.
The text is \"Hello teh world.\"; the word spans points 7 to 10."
  (ltex-plus-actions-test--with-diagnostics "Hello teh world.\n"
    (dolist (point '(7 8 9 10))
      (should (= 1 (length (lsp-ltex-plus--diagnostics-in point point)))))
    (dolist (point '(1 6 11 17))
      (should-not (lsp-ltex-plus--diagnostics-in point point)))))

(ert-deftest ltex-plus-actions-test-a-region-finds-what-it-overlaps ()
  "A region finds every diagnostic it overlaps, and none it merely abuts."
  (ltex-plus-actions-test--with-diagnostics "teh one and teh two.\n"
    (should (= 2 (length (lsp-ltex-plus--diagnostics-in 1 21))))
    (should (= 1 (length (lsp-ltex-plus--diagnostics-in 1 5))))
    (should (= 1 (length (lsp-ltex-plus--diagnostics-in 13 14))))
    (should-not (lsp-ltex-plus--diagnostics-in 4 13))))

;;;; -- The request --------------------------------------------------------------

(defconst ltex-plus-actions-test--fix
  '(:title "Use 'the'" :kind "quickfix.ltex.acceptSuggestions"
    :edit (:documentChanges
           [(:textDocument (:version 1 :uri "file:///replaced-by-the-test")
             :edits [(:range (:start (:line 0 :character 6)
                             :end (:line 0 :character 9))
                      :newText "the")])]))
  "A replacement suggestion, shaped as the real server sends one.")

(defmacro ltex-plus-actions-test--with-checked-buffer (var contents &rest body)
  "Run BODY with VAR bound to a buffer of CONTENTS checked by the fake."
  (declare (indent 2) (debug (symbolp form body)))
  `(ltex-plus-fake-with-connection
     (ltex-plus-test-with-project (list (cons "note.rst" ,contents))
       (let ((,var (ltex-plus-test-visit (project-file "note.rst"))))
         (with-current-buffer ,var (rst-mode))
         (lsp-ltex-plus--open-document ,var)
         (ltex-plus-fake-wait-for
          (lambda () (buffer-local-value 'lsp-ltex-plus--diagnostics ,var)))
         ,@body))))

(ert-deftest ltex-plus-actions-test-the-request-carries-range-and-diagnostics ()
  "The server is asked about the position and given the diagnostics there."
  (ltex-plus-actions-test--with-checked-buffer buffer "Hello teh world.\n"
    (let ((ltex-plus-fake-code-actions (vector ltex-plus-actions-test--fix)))
      (with-current-buffer buffer
        (let ((actions (lsp-ltex-plus--request-code-actions 8 8)))
          (should (equal actions (list ltex-plus-actions-test--fix)))))
      (let ((sent (car (ltex-plus-fake-received 'textDocument/codeAction))))
        (should (equal (plist-get (plist-get sent :textDocument) :uri)
                       (lsp-ltex-plus--buffer-uri buffer)))
        (should (equal (plist-get sent :range)
                       '(:start (:line 0 :character 7) :end (:line 0 :character 7))))
        (let ((context (plist-get (plist-get sent :context) :diagnostics)))
          (should (= 1 (length context)))
          (should (equal (plist-get (aref context 0) :code) "MORFOLOGIK_RULE_EN_US")))))))

(ert-deftest ltex-plus-actions-test-no-diagnostic-at-point-asks-with-none ()
  "Away from any underline the request still goes out, with an empty context.
The server may still have something to offer, and an empty vector is
what the protocol expects rather than null."
  (ltex-plus-actions-test--with-checked-buffer buffer "Hello teh world.\n"
    (let ((ltex-plus-fake-code-actions []))
      (with-current-buffer buffer
        (should-not (lsp-ltex-plus--request-code-actions 1 1)))
      (let ((sent (car (ltex-plus-fake-received 'textDocument/codeAction))))
        (should (equal (plist-get (plist-get sent :context) :diagnostics) []))))))

(ert-deftest ltex-plus-actions-test-an-unchecked-buffer-cannot-ask ()
  "Asking in a buffer that is not open on a server is a `user-error'."
  (with-temp-buffer
    (should-error (lsp-ltex-plus--request-code-actions 1 1) :type 'user-error)))

;;;; -- Applying an edit ---------------------------------------------------------

(defmacro ltex-plus-actions-test--with-registered-buffer (var uri contents &rest body)
  "Run BODY with VAR a buffer of CONTENTS registered as open under URI.
No server is involved: the table is filled by hand and emptied after."
  (declare (indent 3) (debug (symbolp form form body)))
  `(with-temp-buffer
     (let ((,var (current-buffer)))
       (insert ,contents)
       (setq lsp-ltex-plus--document-uri ,uri
             lsp-ltex-plus--document-version 1)
       (puthash ,uri ,var lsp-ltex-plus--documents)
       (unwind-protect
           (progn ,@body)
         (remhash ,uri lsp-ltex-plus--documents)))))

(defun ltex-plus-actions-test--edit (uri version &rest edits)
  "Return a `WorkspaceEdit' on URI at VERSION with EDITS, in documentChanges form.
Each of EDITS is (START-LINE START-CHAR END-LINE END-CHAR TEXT)."
  (list :documentChanges
        (vector (list :textDocument (list :version version :uri uri)
                      :edits (vconcat
                              (mapcar (pcase-lambda (`(,sl ,sc ,el ,ec ,text))
                                        (list :range (list :start (list :line sl :character sc)
                                                           :end (list :line el :character ec))
                                              :newText text))
                                      edits))))))

(ert-deftest ltex-plus-actions-test-edits-are-applied-from-the-end ()
  "Two edits given in reading order both land where they were aimed.
Applying the first one first would shift the second's positions."
  (ltex-plus-actions-test--with-registered-buffer buffer "file:///t/a.rst" "aaa bbb ccc\n"
    (should (= 1 (lsp-ltex-plus--apply-workspace-edit
                  (ltex-plus-actions-test--edit "file:///t/a.rst" 1
                                                '(0 0 0 3 "X") '(0 8 0 11 "YYYY")))))
    (should (equal (buffer-string) "X bbb YYYY\n"))))

(ert-deftest ltex-plus-actions-test-an-edit-may-span-lines ()
  "A range across a line break is replaced as a whole."
  (ltex-plus-actions-test--with-registered-buffer buffer "file:///t/a.rst" "one\ntwo\nthree\n"
    (lsp-ltex-plus--apply-workspace-edit
     (ltex-plus-actions-test--edit "file:///t/a.rst" 1 '(0 1 2 2 "-")))
    (should (equal (buffer-string) "o-ree\n"))))

(ert-deftest ltex-plus-actions-test-inserts-at-one-position-keep-their-order ()
  "Two insertions at the same point come out in the order the server gave."
  (ltex-plus-actions-test--with-registered-buffer buffer "file:///t/a.rst" "x\n"
    (lsp-ltex-plus--apply-workspace-edit
     (ltex-plus-actions-test--edit "file:///t/a.rst" 1 '(0 0 0 0 "A") '(0 0 0 0 "B")))
    (should (equal (buffer-string) "ABx\n"))))

(ert-deftest ltex-plus-actions-test-the-changes-form-is-applied-too ()
  "An edit in the older `changes' form, keyed by URI, works as well.
jsonrpc hands the object over as a plist whose keys are the URIs read
as keywords."
  (ltex-plus-actions-test--with-registered-buffer buffer "file:///t/a.rst" "teh end\n"
    (lsp-ltex-plus--apply-workspace-edit
     (list :changes (list (intern ":file:///t/a.rst")
                          (vector (list :range '(:start (:line 0 :character 0)
                                                 :end (:line 0 :character 3))
                                        :newText "the")))))
    (should (equal (buffer-string) "the end\n"))))

(ert-deftest ltex-plus-actions-test-a-stale-version-is-refused ()
  "An edit for a version the buffer is no longer at touches nothing."
  (ltex-plus-actions-test--with-registered-buffer buffer "file:///t/a.rst" "aaa\n"
    (setq lsp-ltex-plus--document-version 3)
    (should-error (lsp-ltex-plus--apply-workspace-edit
                   (ltex-plus-actions-test--edit "file:///t/a.rst" 2 '(0 0 0 3 "X")))
                  :type 'user-error)
    (should (equal (buffer-string) "aaa\n"))))

(ert-deftest ltex-plus-actions-test-a-pending-edit-is-refused ()
  "While an edit waits to be sent, the buffer's text is ahead of the server's."
  (ltex-plus-actions-test--with-registered-buffer buffer "file:///t/a.rst" "aaa\n"
    (setq lsp-ltex-plus--change-timer (run-with-timer 1000 nil #'ignore))
    (unwind-protect
        (should-error (lsp-ltex-plus--apply-workspace-edit
                       (ltex-plus-actions-test--edit "file:///t/a.rst" 1 '(0 0 0 3 "X")))
                      :type 'user-error)
      (cancel-timer lsp-ltex-plus--change-timer))
    (should (equal (buffer-string) "aaa\n"))))

(ert-deftest ltex-plus-actions-test-nothing-is-touched-unless-every-document-can-be ()
  "With one good document and one nobody holds, the good one is left alone too."
  (ltex-plus-actions-test--with-registered-buffer buffer "file:///t/a.rst" "aaa\n"
    (should-error
     (lsp-ltex-plus--apply-workspace-edit
      (list :documentChanges
            (vector (aref (plist-get (ltex-plus-actions-test--edit "file:///t/a.rst" 1
                                                                   '(0 0 0 3 "X"))
                                     :documentChanges)
                          0)
                    (aref (plist-get (ltex-plus-actions-test--edit "file:///t/gone.rst" 1
                                                                   '(0 0 0 1 "Y"))
                                     :documentChanges)
                          0))))
     :type 'user-error)
    (should (equal (buffer-string) "aaa\n"))))

(ert-deftest ltex-plus-actions-test-file-operations-are-refused ()
  "A create, rename or delete of a file is not something this client does."
  (should-error (lsp-ltex-plus--apply-workspace-edit
                 '(:documentChanges [(:kind "create" :uri "file:///t/new.rst")]))
                :type 'user-error))

(provide 'ltex-plus-actions-test)
;;; ltex-plus-actions-test.el ends here
