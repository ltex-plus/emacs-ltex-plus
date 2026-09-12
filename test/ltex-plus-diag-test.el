;;; ltex-plus-diag-test.el --- The flymake backend -*- lexical-binding: t; -*-

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:

;; How a protocol diagnostic becomes a flymake one, and how the backend
;; keeps flymake current with a server that pushes.  The last tests run
;; flymake for real, against the fake server: flymake is asked to check
;; once, and every underline after that comes from the server publishing,
;; not from flymake asking again.

;;; Code:

(require 'ltex-plus-test-helper)
(require 'ltex-plus-fake-server)

;;;; -- Conversion -------------------------------------------------------------

(ert-deftest ltex-plus-diag-test-severities-map-to-flymake-types ()
  "Error and warning keep their names; the rest, and no severity, are notes."
  (should (eq :error (lsp-ltex-plus--flymake-type 1)))
  (should (eq :warning (lsp-ltex-plus--flymake-type 2)))
  (should (eq :note (lsp-ltex-plus--flymake-type 3)))
  (should (eq :note (lsp-ltex-plus--flymake-type 4)))
  (should (eq :note (lsp-ltex-plus--flymake-type nil))))

(ert-deftest ltex-plus-diag-test-the-text-carries-the-rule-id ()
  "The rule id follows the message, since it is what disabling a rule needs."
  (should (equal (lsp-ltex-plus--flymake-text '(:message "Oops." :code "RULE_X"))
                 "Oops. [RULE_X]"))
  (should (equal (lsp-ltex-plus--flymake-text '(:message "Oops."))
                 "Oops.")))

(ert-deftest ltex-plus-diag-test-a-diagnostic-spans-the-right-text ()
  "The flymake diagnostic covers the server's range, converted to points."
  (with-temp-buffer
    (insert "Hello teh world.\n")
    (let* ((protocol (aref (ltex-plus-fake-diagnostics "Hello teh world.\n") 0))
           (diagnostic (lsp-ltex-plus--flymake-diagnostic protocol)))
      (should (= 7 (flymake-diagnostic-beg diagnostic)))
      (should (= 10 (flymake-diagnostic-end diagnostic)))
      (should (eq :warning (flymake-diagnostic-type diagnostic)))
      (should (string-match-p "spelling.*\\[MORFOLOGIK_RULE_EN_US\\]"
                              (flymake-diagnostic-text diagnostic)))
      (should (eq protocol (flymake-diagnostic-data diagnostic))))))

;;;; -- The backend ------------------------------------------------------------

(ert-deftest ltex-plus-diag-test-the-backend-answers-with-what-is-stored ()
  "Asked by flymake, the backend reports the stored diagnostics at once."
  (with-temp-buffer
    (insert "Hello teh world.\n")
    (flymake-mode 1)
    (setq lsp-ltex-plus--diagnostics
          (append (ltex-plus-fake-diagnostics "Hello teh world.\n") nil))
    (let ((reported :nothing))
      (lsp-ltex-plus-flymake-backend (lambda (diagnostics &rest _) (setq reported diagnostics)))
      (should (= 1 (length reported)))
      (should (= 7 (flymake-diagnostic-beg (car reported)))))))

(ert-deftest ltex-plus-diag-test-a-publish-reaches-flymake-through-the-kept-function ()
  "After flymake asked once, every publish is reported through that function."
  (with-temp-buffer
    (insert "Hello teh world.\n")
    (flymake-mode 1)
    (let ((reports nil))
      (lsp-ltex-plus-flymake-backend (lambda (diagnostics &rest _) (push diagnostics reports)))
      (should (equal reports '(nil)))
      (setq lsp-ltex-plus--diagnostics
            (append (ltex-plus-fake-diagnostics "Hello teh world.\n") nil))
      (run-hook-with-args 'lsp-ltex-plus--diagnostics-functions (current-buffer))
      (should (= 2 (length reports)))
      (should (= 1 (length (car reports)))))))

(ert-deftest ltex-plus-diag-test-nothing-is-reported-before-flymake-asks ()
  "A publish before flymake has called the backend is kept, not reported.
There is no function to report through yet; the backend answers with
it when flymake does ask."
  (with-temp-buffer
    (insert "Hello teh world.\n")
    (setq lsp-ltex-plus--diagnostics
          (append (ltex-plus-fake-diagnostics "Hello teh world.\n") nil))
    ;; Must not signal.
    (lsp-ltex-plus--flymake-report (current-buffer))
    (should lsp-ltex-plus--diagnostics)))

(ert-deftest ltex-plus-diag-test-detaching-clears-and-removes-the-backend ()
  "Detaching reports an empty list and takes the backend off the hook."
  (with-temp-buffer
    (insert "Hello teh world.\n")
    (flymake-mode 1)
    (lsp-ltex-plus--flymake-attach)
    (should (memq #'lsp-ltex-plus-flymake-backend flymake-diagnostic-functions))
    (let ((reports nil))
      (lsp-ltex-plus-flymake-backend (lambda (diagnostics &rest _) (push diagnostics reports)))
      (setq reports nil)
      (lsp-ltex-plus--flymake-detach)
      (should (equal reports '(nil))))
    (should-not (memq #'lsp-ltex-plus-flymake-backend flymake-diagnostic-functions))
    (should-not lsp-ltex-plus--flymake-report-fn)))

(ert-deftest ltex-plus-diag-test-attaching-turns-flymake-on ()
  "Attaching enables `flymake-mode' when it is off, and leaves it on if on."
  (with-temp-buffer
    (should-not flymake-mode)
    (lsp-ltex-plus--flymake-attach)
    (should flymake-mode)
    (lsp-ltex-plus--flymake-detach)
    (should flymake-mode)))

;;;; -- Against the fake, through flymake itself ---------------------------------

(defmacro ltex-plus-diag-test--with-checked-file (var contents &rest body)
  "Run BODY with VAR bound to a buffer of CONTENTS open on the fake under flymake.
Flymake is asked to check once, explicitly: in a batch Emacs nothing
runs `post-command-hook', which is what `flymake-mode' itself waits for."
  (declare (indent 2) (debug (symbolp form body)))
  `(ltex-plus-fake-with-connection
     (ltex-plus-test-with-project (list (cons "note.rst" ,contents))
       (let ((,var (ltex-plus-test-visit (project-file "note.rst")))
             (lsp-ltex-plus-change-delay 0.1))
         (with-current-buffer ,var
           (rst-mode)
           (lsp-ltex-plus--flymake-attach)
           (flymake-start)
           (lsp-ltex-plus--open-document))
         ,@body))))

(defun ltex-plus-diag-test--underlines (buffer)
  "Return the texts of the flymake diagnostics shown in BUFFER."
  (with-current-buffer buffer
    (mapcar #'flymake-diagnostic-text (flymake-diagnostics))))

(ert-deftest ltex-plus-diag-test-the-server-s-diagnostics-are-shown ()
  "What the server publishes ends up as flymake diagnostics in the buffer."
  (ltex-plus-diag-test--with-checked-file buffer "Hello teh world.\n"
    (ltex-plus-fake-wait-for (lambda () (ltex-plus-diag-test--underlines buffer)))
    (let ((shown (with-current-buffer buffer (flymake-diagnostics))))
      (should (= 1 (length shown)))
      (should (= 7 (flymake-diagnostic-beg (car shown))))
      (should (= 10 (flymake-diagnostic-end (car shown))))
      (should (eq :warning (flymake-diagnostic-type (car shown)))))))

(ert-deftest ltex-plus-diag-test-an-edit-updates-the-underlines-without-flymake-asking ()
  "Fixing the text clears the underline once the server re-publishes.
Flymake is never asked to check again; the report goes through the
function it handed out for the first check."
  (ltex-plus-diag-test--with-checked-file buffer "Hello teh world.\n"
    (ltex-plus-fake-wait-for (lambda () (ltex-plus-diag-test--underlines buffer)))
    (with-current-buffer buffer
      (goto-char 7)
      (delete-char 3)
      (insert "the"))
    (ltex-plus-fake-wait-for (lambda () (ltex-plus-fake-received 'textDocument/didChange)))
    (ltex-plus-fake-wait-for (lambda () (null (ltex-plus-diag-test--underlines buffer))))
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert "And teh end.\n"))
    (ltex-plus-fake-wait-for (lambda () (ltex-plus-diag-test--underlines buffer)))
    (should (= 1 (length (ltex-plus-diag-test--underlines buffer))))))

(ert-deftest ltex-plus-diag-test-a-later-publish-replaces-the-earlier-one ()
  "A new publish replaces what was shown; an empty one clears it.
Flymake adds a backend's later reports to its earlier ones unless the
report names a region, so without the region an underline the user did
not edit away would stay for ever.  The text is not edited here, so
nothing but the report can take the underlines away."
  (ltex-plus-diag-test--with-checked-file buffer "teh one and teh two.\n"
    (ltex-plus-fake-wait-for
     (lambda () (= 2 (length (ltex-plus-diag-test--underlines buffer)))))
    (let ((uri (lsp-ltex-plus--buffer-uri buffer))
          (one (aref (ltex-plus-fake-diagnostics "teh one and teh two.\n") 0)))
      (ltex-plus-fake-publish uri (vector one))
      (ltex-plus-fake-wait-for
       (lambda () (= 1 (length (ltex-plus-diag-test--underlines buffer)))))
      (ltex-plus-fake-publish uri [])
      (ltex-plus-fake-wait-for
       (lambda () (null (ltex-plus-diag-test--underlines buffer)))))))

(provide 'ltex-plus-diag-test)
;;; ltex-plus-diag-test.el ends here
