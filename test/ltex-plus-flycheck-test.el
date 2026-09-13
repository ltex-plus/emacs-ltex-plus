;;; ltex-plus-flycheck-test.el --- The flycheck checker -*- lexical-binding: t; -*-

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:

;; How a protocol diagnostic becomes a flycheck error, and how the checker
;; keeps flycheck current with a server that pushes when flycheck takes
;; one answer per check.  The last tests run flycheck for real, against
;; the fake server, with flycheck's own triggers switched off: every error
;; that appears or goes is the checker asking for a check on a publish.
;;
;; Flycheck is not part of Emacs.  The tests that need it run when
;; LTEX_PLUS_FLYCHECK_DIR names the directory holding flycheck.el
;; (test/run-tests.sh puts it on the load path) and report as skipped
;; otherwise, with the reason.  The conversions need no flycheck and
;; always run.

;;; Code:

(require 'ltex-plus-test-helper)
(require 'ltex-plus-fake-server)
(require 'flycheck nil t)

(defun ltex-plus-flycheck-test--need-flycheck ()
  "Skip the current test unless flycheck is loaded."
  (unless (featurep 'flycheck)
    (ert-skip "flycheck is not on the load path; set LTEX_PLUS_FLYCHECK_DIR")))

;;;; -- Conversion -------------------------------------------------------------

(ert-deftest ltex-plus-flycheck-test-severities-map-to-flycheck-levels ()
  "Error and warning keep their names; the rest, and no severity, are info."
  (should (eq 'error (lsp-ltex-plus--flycheck-level 1)))
  (should (eq 'warning (lsp-ltex-plus--flycheck-level 2)))
  (should (eq 'info (lsp-ltex-plus--flycheck-level 3)))
  (should (eq 'info (lsp-ltex-plus--flycheck-level 4)))
  (should (eq 'info (lsp-ltex-plus--flycheck-level nil))))

(ert-deftest ltex-plus-flycheck-test-line-and-column-are-one-based-and-absolute ()
  "Points become 1-based lines and columns, counted in the widened buffer.
Flycheck resolves them there; a narrowed buffer would otherwise put
every error a few lines off."
  (with-temp-buffer
    (insert "Hello teh world.\nSecond teh line.\n")
    (should (equal '(1 . 1) (lsp-ltex-plus--flycheck-line-column 1)))
    (should (equal '(1 . 7) (lsp-ltex-plus--flycheck-line-column 7)))
    (should (equal '(2 . 8) (lsp-ltex-plus--flycheck-line-column 25)))
    (should (equal '(3 . 1) (lsp-ltex-plus--flycheck-line-column (point-max))))
    (narrow-to-region 18 (point-max))
    (should (equal '(2 . 8) (lsp-ltex-plus--flycheck-line-column 25)))))

(ert-deftest ltex-plus-flycheck-test-an-error-spans-the-right-text ()
  "The flycheck error carries the server's range as an exact region.
Start and end line and column are what flycheck highlights exactly, in
every highlighting mode; the rule id is the error's id, which flycheck
shows after the message."
  (ltex-plus-flycheck-test--need-flycheck)
  (with-temp-buffer
    (insert "Hello teh world.\nSecond teh line.\n")
    (let* ((text "Hello teh world.\nSecond teh line.\n")
           (protocol (aref (ltex-plus-fake-diagnostics text) 1))
           (err (lsp-ltex-plus--flycheck-error protocol)))
      (should (= 2 (flycheck-error-line err)))
      (should (= 8 (flycheck-error-column err)))
      (should (= 2 (flycheck-error-end-line err)))
      (should (= 11 (flycheck-error-end-column err)))
      (should (eq 'warning (flycheck-error-level err)))
      (should (equal "MORFOLOGIK_RULE_EN_US" (flycheck-error-id err)))
      (should (string-match-p "spelling" (flycheck-error-message err)))
      (should (eq 'lsp-ltex-plus (flycheck-error-checker err)))
      (should (eq (current-buffer) (flycheck-error-buffer err)))
      (should-not (flycheck-error-filename err))
      (should (equal '(25 . 28) (flycheck-error-region-for-mode err 'symbols))))))

;;;; -- The checker ------------------------------------------------------------

(ert-deftest ltex-plus-flycheck-test-the-checker-is-defined-for-the-mode-table ()
  "Loading flycheck defines the checker, for every mode the package knows.
Its predicate keeps it out of a buffer the package is not checking, so
that listing it in `flycheck-checkers' cannot make it claim a buffer and
show nothing."
  (ltex-plus-flycheck-test--need-flycheck)
  (should (flycheck-valid-checker-p 'lsp-ltex-plus))
  (should (flycheck-checker-supports-major-mode-p 'lsp-ltex-plus 'rst-mode))
  (should (flycheck-checker-supports-major-mode-p 'lsp-ltex-plus 'org-mode))
  (with-temp-buffer
    (setq major-mode 'rst-mode)
    (should-not (flycheck-may-use-checker 'lsp-ltex-plus))
    (setq lsp-ltex-plus--flycheck-attached t)
    (should (flycheck-may-use-checker 'lsp-ltex-plus))
    (should (= 2 (length (lsp-ltex-plus--flycheck-verify 'lsp-ltex-plus))))))

(ert-deftest ltex-plus-flycheck-test-a-check-answers-with-what-is-stored ()
  "Asked by flycheck, the start function finishes at once with the stored errors."
  (ltex-plus-flycheck-test--need-flycheck)
  (with-temp-buffer
    (insert "Hello teh world.\n")
    (setq lsp-ltex-plus--diagnostics
          (append (ltex-plus-fake-diagnostics "Hello teh world.\n") nil))
    (let ((reported :nothing))
      (lsp-ltex-plus--flycheck-start
       'lsp-ltex-plus
       (lambda (status errors) (setq reported (cons status errors))))
      (should (eq 'finished (car reported)))
      (should (= 1 (length (cdr reported))))
      (should (= 7 (flycheck-error-column (cadr reported)))))))

(ert-deftest ltex-plus-flycheck-test-a-refresh-waits-for-a-running-check ()
  "While another checker runs, the request queues once and fires when it ends.
`flycheck-buffer' does nothing during a running check; a publish that
arrived then would be lost until the next edit, and the last state the
server sent would not be the one shown."
  (with-temp-buffer
    (setq-local flycheck-mode t)
    (let ((running t) (checks 0))
      (cl-letf (((symbol-function 'flycheck-running-p) (lambda () running))
                ((symbol-function 'flycheck-buffer) (lambda () (cl-incf checks))))
        (lsp-ltex-plus--flycheck-refresh)
        (lsp-ltex-plus--flycheck-refresh)
        (should (= 0 checks))
        (should (memq #'lsp-ltex-plus--flycheck-recheck flycheck-after-syntax-check-hook))
        (setq running nil)
        (run-hooks 'flycheck-after-syntax-check-hook)
        (should (= 1 checks))
        (should-not (memq #'lsp-ltex-plus--flycheck-recheck
                          flycheck-after-syntax-check-hook))))))

(ert-deftest ltex-plus-flycheck-test-attaching-selects-the-checker-and-detaching-restores ()
  "Attaching makes this the buffer's checker and turns flycheck on.
Detaching puts the previous selection back and leaves `flycheck-mode'
on, since the buffer may well have been using it before."
  (ltex-plus-flycheck-test--need-flycheck)
  (ltex-plus-test-with-project '(("note.rst" . "Text.\n"))
    (with-current-buffer (ltex-plus-test-visit (project-file "note.rst"))
      (rst-mode)
      (let ((inhibit-message t))
        (setq flycheck-checker 'proselint)
        (should-not flycheck-mode)
        (lsp-ltex-plus--flycheck-attach)
        (should flycheck-mode)
        (should lsp-ltex-plus--flycheck-attached)
        (should (eq 'lsp-ltex-plus flycheck-checker))
        (lsp-ltex-plus--flycheck-detach)
        (should flycheck-mode)
        (should-not lsp-ltex-plus--flycheck-attached)
        (should (eq 'proselint flycheck-checker))))))

;;;; -- Against the fake, through flycheck itself ---------------------------------

(defmacro ltex-plus-flycheck-test--with-checked-file (var contents &rest body)
  "Run BODY with VAR bound to a buffer of CONTENTS checked on the fake under flycheck.
Flycheck's own triggers are switched off in the buffer, so a check can
only come from the checker asking for one."
  (declare (indent 2) (debug (symbolp form body)))
  `(ltex-plus-fake-with-connection
     (ltex-plus-test-with-project (list (cons "note.rst" ,contents))
       (let ((,var (ltex-plus-test-visit (project-file "note.rst")))
             (lsp-ltex-plus-diagnostics-provider 'flycheck)
             (lsp-ltex-plus-change-delay 0.1)
             (inhibit-message t))
         (with-current-buffer ,var
           (rst-mode)
           (setq-local flycheck-check-syntax-automatically nil)
           (lsp-ltex-plus-mode 1))
         ,@body))))

(defun ltex-plus-flycheck-test--errors (buffer)
  "Return the flycheck errors currently shown in BUFFER."
  (buffer-local-value 'flycheck-current-errors buffer))

(ert-deftest ltex-plus-flycheck-test-the-server-s-diagnostics-are-shown ()
  "What the server publishes ends up as flycheck errors, and overlays, in the buffer."
  (ltex-plus-flycheck-test--need-flycheck)
  (ltex-plus-flycheck-test--with-checked-file buffer "Hello teh world.\n"
    (with-current-buffer buffer
      (should flycheck-mode)
      (should (eq 'flycheck lsp-ltex-plus--attached-provider))
      (should (eq 'lsp-ltex-plus flycheck-checker)))
    (ltex-plus-fake-wait-for (lambda () (ltex-plus-flycheck-test--errors buffer)))
    (let ((shown (ltex-plus-flycheck-test--errors buffer)))
      (should (= 1 (length shown)))
      (should (= 1 (flycheck-error-line (car shown))))
      (should (= 7 (flycheck-error-column (car shown))))
      (should (= 10 (flycheck-error-end-column (car shown))))
      (should (eq 'warning (flycheck-error-level (car shown)))))
    (with-current-buffer buffer
      (let ((overlays (flycheck-overlays-in (point-min) (point-max))))
        (should (= 1 (length overlays)))
        (should (= 7 (overlay-start (car overlays))))
        (should (= 10 (overlay-end (car overlays))))))))

(ert-deftest ltex-plus-flycheck-test-an-edit-updates-the-errors-without-flycheck-asking ()
  "Fixing the text clears the error once the server re-publishes.
Flycheck's triggers are off; the check that clears it is the one the
checker asks for on the publish."
  (ltex-plus-flycheck-test--need-flycheck)
  (ltex-plus-flycheck-test--with-checked-file buffer "Hello teh world.\n"
    (ltex-plus-fake-wait-for (lambda () (ltex-plus-flycheck-test--errors buffer)))
    (with-current-buffer buffer
      (goto-char 7)
      (delete-char 3)
      (insert "the"))
    (ltex-plus-fake-wait-for (lambda () (ltex-plus-fake-received 'textDocument/didChange)))
    (ltex-plus-fake-wait-for (lambda () (null (ltex-plus-flycheck-test--errors buffer))))
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert "And teh end.\n"))
    (ltex-plus-fake-wait-for (lambda () (ltex-plus-flycheck-test--errors buffer)))
    (should (= 1 (length (ltex-plus-flycheck-test--errors buffer))))
    (should (= 2 (flycheck-error-line (car (ltex-plus-flycheck-test--errors buffer)))))))

(ert-deftest ltex-plus-flycheck-test-a-later-publish-replaces-the-earlier-one ()
  "A new publish replaces what was shown; an empty one clears it.
The text is not edited here, so nothing but the check asked for on the
publish can take the errors away."
  (ltex-plus-flycheck-test--need-flycheck)
  (ltex-plus-flycheck-test--with-checked-file buffer "teh one and teh two.\n"
    (ltex-plus-fake-wait-for
     (lambda () (= 2 (length (ltex-plus-flycheck-test--errors buffer)))))
    (let ((uri (lsp-ltex-plus--buffer-uri buffer))
          (one (aref (ltex-plus-fake-diagnostics "teh one and teh two.\n") 0)))
      (ltex-plus-fake-publish uri (vector one))
      (ltex-plus-fake-wait-for
       (lambda () (= 1 (length (ltex-plus-flycheck-test--errors buffer)))))
      (ltex-plus-fake-publish uri [])
      (ltex-plus-fake-wait-for
       (lambda () (null (ltex-plus-flycheck-test--errors buffer)))))))

(ert-deftest ltex-plus-flycheck-test-disabling-clears-and-lets-go-of-the-buffer ()
  "Turning the mode off takes the errors away and gives flycheck the buffer back."
  (ltex-plus-flycheck-test--need-flycheck)
  (ltex-plus-flycheck-test--with-checked-file buffer "Hello teh world.\n"
    (ltex-plus-fake-wait-for (lambda () (ltex-plus-flycheck-test--errors buffer)))
    (with-current-buffer buffer
      (lsp-ltex-plus-mode -1)
      (should-not (ltex-plus-flycheck-test--errors buffer))
      (should-not (flycheck-overlays-in (point-min) (point-max)))
      (should-not flycheck-checker)
      (should-not lsp-ltex-plus--flycheck-attached)
      (should flycheck-mode))))

(provide 'ltex-plus-flycheck-test)
;;; ltex-plus-flycheck-test.el ends here
