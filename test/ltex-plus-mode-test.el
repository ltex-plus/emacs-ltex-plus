;;; ltex-plus-mode-test.el --- The minor mode's own decisions -*- lexical-binding: t; -*-

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:

;; `lsp-ltex-plus-mode' is the entry point, and most of it needs a live
;; server: the five-way `cond' over startup paths, and the deactivation
;; path that has to tell a sole client from one with co-tenants.  Those
;; stay in the manual checklist in the developer guide.
;;
;; Everything the mode decides *before* it reaches for the server does
;; not, and that is what this file covers: the programming-language
;; guard, registering a major mode it has not seen, and giving up when
;; the binary is missing.  `executable-find' is stubbed to fail, which is
;; both how a user without the server sees the mode behave and a clean
;; place for a test to stop -- the mode aborts there having already made
;; every decision above.

;;; Code:

(require 'ltex-plus-test-helper)

(defvar ltex-plus-mode-test--looked-for-server nil
  "Set when the mode body got as far as looking for the binary.")

(defmacro ltex-plus-mode-test--in-mode (mode &rest body)
  "Run BODY in a temp buffer whose `major-mode' is MODE, server absent.
`executable-find' answers nil throughout, so the mode aborts where it
looks for `ltex-ls-plus' instead of starting one, and
`ltex-plus-mode-test--looked-for-server' records whether it got that
far.  The two mode tables are restored on exit, since activation in an
unregistered mode writes to both."
  (declare (indent 1) (debug t))
  `(let ((ltex-plus-mode-test--looked-for-server nil)
         (lsp-ltex-plus-major-modes (copy-tree lsp-ltex-plus-major-modes))
         (lsp-language-id-configuration (copy-alist lsp-language-id-configuration))
         (inhibit-message t))
     (cl-letf (((symbol-function 'executable-find)
                (lambda (&rest _)
                  (setq ltex-plus-mode-test--looked-for-server t)
                  nil)))
       (with-temp-buffer
         (setq major-mode ,mode)
         ,@body))))

;;;; -- The programming-language guard -----------------------------------------

(ert-deftest ltex-plus-mode-test-dispatcher-skips-programming-modes ()
  "Activation from the dispatcher bails out in a programming buffer.
With `lsp-ltex-plus-check-programming-languages' off, a mode marked
`PROGRAMMING-P' must not start the client -- and must not merely fail
later, but stop before looking for the server at all, since the whole
point is that opening a Python file costs nothing."
  (let ((lsp-ltex-plus-check-programming-languages nil))
    (ltex-plus-mode-test--in-mode 'python-mode
      (lsp-ltex-plus-mode 1)
      (should-not lsp-ltex-plus-mode)
      (should-not ltex-plus-mode-test--looked-for-server))))

(ert-deftest ltex-plus-mode-test-an-explicit-call-overrides-the-guard ()
  "`M-x lsp-ltex-plus-mode' proceeds in a programming buffer anyway.
The guard is on dispatcher-driven activation only, so an on-demand check
does not require toggling a global setting first."
  (let ((lsp-ltex-plus-check-programming-languages nil))
    (ltex-plus-mode-test--in-mode 'python-mode
      (funcall-interactively #'lsp-ltex-plus-mode 1)
      (should ltex-plus-mode-test--looked-for-server))))

(ert-deftest ltex-plus-mode-test-opting-in-lifts-the-guard ()
  "With the option on, the dispatcher activates in a programming buffer."
  (let ((lsp-ltex-plus-check-programming-languages t))
    (ltex-plus-mode-test--in-mode 'python-mode
      (lsp-ltex-plus-mode 1)
      (should ltex-plus-mode-test--looked-for-server))))

(ert-deftest ltex-plus-mode-test-markup-modes-are-never-guarded ()
  "A markup mode activates whatever the programming option says."
  (dolist (value '(nil t))
    (let ((lsp-ltex-plus-check-programming-languages value))
      (ltex-plus-mode-test--in-mode 'markdown-mode
        (lsp-ltex-plus-mode 1)
        (should ltex-plus-mode-test--looked-for-server)))))

;;;; -- Registering an unknown major mode --------------------------------------

(ert-deftest ltex-plus-mode-test-unknown-mode-is-registered-silently ()
  "A mode the package has not seen is added, defaulting to plaintext.
Called from the dispatcher there is nobody to ask, so no prompt may
appear; the entry is markup (`PROGRAMMING-P' nil), since an unknown mode
is far likelier to be a writing context than a language."
  (ltex-plus-mode-test--in-mode 'ltex-plus-mode-test-unknown-mode
    (lsp-ltex-plus-mode 1)
    (should (equal (assq 'ltex-plus-mode-test-unknown-mode
                         lsp-ltex-plus-major-modes)
                   '(ltex-plus-mode-test-unknown-mode "plaintext" nil)))
    (should (equal (assq 'ltex-plus-mode-test-unknown-mode
                         lsp-language-id-configuration)
                   '(ltex-plus-mode-test-unknown-mode . "plaintext")))))

(ert-deftest ltex-plus-mode-test-an-explicit-call-asks-for-the-language ()
  "Interactively the language identifier is requested, with a default."
  (ltex-plus-mode-test--in-mode 'ltex-plus-mode-test-asked-mode
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "typst")))
      (funcall-interactively #'lsp-ltex-plus-mode 1))
    (should (equal (assq 'ltex-plus-mode-test-asked-mode
                         lsp-ltex-plus-major-modes)
                   '(ltex-plus-mode-test-asked-mode "typst" nil)))))

(ert-deftest ltex-plus-mode-test-a-known-mode-is-not-registered-twice ()
  "A mode already in the table is left exactly as it is."
  (ltex-plus-mode-test--in-mode 'markdown-mode
    (let ((before (copy-tree lsp-ltex-plus-major-modes)))
      (lsp-ltex-plus-mode 1)
      (should (equal lsp-ltex-plus-major-modes before)))))

;;;; -- Giving up when the server is not installed -----------------------------

(ert-deftest ltex-plus-mode-test-a-missing-binary-turns-the-mode-off ()
  "Without `ltex-ls-plus' on PATH the mode reports and switches itself off.
Leaving the mode variable on would make `:activation-fn' keep saying yes
in a buffer where nothing can start."
  (ltex-plus-mode-test--in-mode 'markdown-mode
    (lsp-ltex-plus-mode 1)
    (should ltex-plus-mode-test--looked-for-server)
    (should-not lsp-ltex-plus-mode)))

(ert-deftest ltex-plus-mode-test-the-configured-executable-is-the-one-sought ()
  "The lookup uses `lsp-ltex-plus-ls-plus-executable', not a fixed name.
Setting it to an absolute path is the documented way to run a server
that is not on PATH."
  (let ((lsp-ltex-plus-ls-plus-executable "/opt/ltex/bin/ltex-ls-plus")
        (sought nil)
        (inhibit-message t)
        (lsp-ltex-plus-major-modes (copy-tree lsp-ltex-plus-major-modes)))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (name &rest _) (setq sought name) nil)))
      (with-temp-buffer
        (setq major-mode 'markdown-mode)
        (lsp-ltex-plus-mode 1)))
    (should (equal sought "/opt/ltex/bin/ltex-ls-plus"))))

;;;; -- The mode is what `:activation-fn' reads --------------------------------

(ert-deftest ltex-plus-mode-test-activation-tracks-the-mode-variable ()
  "Switching the mode off is what stops lsp-mode restarting the client.
`:activation-fn' reads the buffer-local variable and nothing else, so
the abort paths above have to leave it nil rather than merely return."
  (lsp-ltex-plus--setup)
  (let ((activate (lsp--client-activation-fn (gethash 'ltex-ls-plus lsp-clients))))
    (ltex-plus-mode-test--in-mode 'markdown-mode
      (lsp-ltex-plus-mode 1)
      (should-not (funcall activate (buffer-name) major-mode)))))

(provide 'ltex-plus-mode-test)
;;; ltex-plus-mode-test.el ends here
