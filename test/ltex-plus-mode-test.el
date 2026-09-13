;;; ltex-plus-mode-test.el --- The minor mode's own decisions -*- lexical-binding: t; -*-

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:

;; `lsp-ltex-plus-mode' is the entry point.  What it decides before it
;; reaches for the server -- the programming-language guard, registering
;; a major mode it has not seen, giving up when the binary is missing --
;; is tested with the binary stubbed away, so the mode aborts exactly
;; where it looks for the server.  What it does once it reaches for the
;; server is tested against the fake: opening and closing the document,
;; attaching the front-end, and the two commands that stop and restart the
;; server for every buffer at once.

;;; Code:

(require 'ltex-plus-test-helper)
(require 'ltex-plus-fake-server)
(require 'flyspell)

(defvar ltex-plus-mode-test--looked-for-server nil
  "Set when the mode body got as far as looking for the binary.")

(defmacro ltex-plus-mode-test--in-mode (mode &rest body)
  "Run BODY in a temp buffer whose `major-mode' is MODE, server absent.
`lsp-ltex-plus--server-executable' answers nil throughout, so the mode
aborts where it looks for `ltex-ls-plus' instead of starting one, and
`ltex-plus-mode-test--looked-for-server' records whether it got that
far.  The mode table is restored on exit, since activation in an
unregistered mode writes to it."
  (declare (indent 1) (debug t))
  `(let ((ltex-plus-mode-test--looked-for-server nil)
         (lsp-ltex-plus-major-modes (copy-tree lsp-ltex-plus-major-modes))
         (inhibit-message t))
     (cl-letf (((symbol-function 'lsp-ltex-plus--server-executable)
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

;;;; -- Giving up when the server is not installed -----------------------------

(ert-deftest ltex-plus-mode-test-a-missing-binary-turns-the-mode-off ()
  "Without `ltex-ls-plus' the mode reports and switches itself off.
Leaving the mode variable on would show a lighter for a buffer nothing
is checking."
  (ltex-plus-mode-test--in-mode 'markdown-mode
    (lsp-ltex-plus-mode 1)
    (should ltex-plus-mode-test--looked-for-server)
    (should-not lsp-ltex-plus-mode)))

(ert-deftest ltex-plus-mode-test-the-report-names-the-configured-executable ()
  "The message about a missing binary says which name was looked for.
Setting `lsp-ltex-plus-ls-plus-executable' to an absolute path is the
documented way to run a server that is not on PATH, and the message is
where a typo in it shows up."
  (let ((lsp-ltex-plus-ls-plus-executable "/opt/ltex/bin/no-such-ltex-ls-plus")
        (lsp-ltex-plus-ltex-ls-path nil)
        (lsp-ltex-plus-major-modes (copy-tree lsp-ltex-plus-major-modes))
        (said nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
      (with-temp-buffer
        (setq major-mode 'markdown-mode)
        (lsp-ltex-plus-mode 1)
        (should-not lsp-ltex-plus-mode)))
    (should (string-match-p "/opt/ltex/bin/no-such-ltex-ls-plus" said))
    (should (string-match-p "lsp-ltex-plus-ls-plus-executable" said))))

;;;; -- Registering an unknown major mode --------------------------------------

;; These run with the binary apparently installed but opening the document
;; stubbed out, so the mode registers the major mode and stops short of
;; the server; the registration is what is under test.  The stub matters
;; on a machine that has a real ltex-ls-plus on PATH: without it these
;; tests would start a JVM, and later tests would reuse it in place of
;; the fake.

(defmacro ltex-plus-mode-test--with-server-present (&rest body)
  "Run BODY with a temp buffer current and the binary apparently installed."
  (declare (indent 0) (debug t))
  `(let ((lsp-ltex-plus-major-modes (copy-tree lsp-ltex-plus-major-modes))
         (inhibit-message t))
     (cl-letf (((symbol-function 'lsp-ltex-plus--server-executable)
                (lambda (&rest _) "ltex-ls-plus"))
               ((symbol-function 'lsp-ltex-plus--open-document) #'ignore))
       (with-temp-buffer
         ,@body))))

(ert-deftest ltex-plus-mode-test-unknown-mode-is-registered-silently ()
  "A mode the package has not seen is added, defaulting to plaintext.
Called from the dispatcher there is nobody to ask, so no prompt may
appear; the entry is markup (`PROGRAMMING-P' nil), since an unknown mode
is far likelier to be a writing context than a language."
  (ltex-plus-mode-test--with-server-present
    (setq major-mode 'ltex-plus-mode-test-unknown-mode)
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _) (error "Nobody should be asked"))))
      (lsp-ltex-plus-mode 1))
    (should (equal (assq 'ltex-plus-mode-test-unknown-mode lsp-ltex-plus-major-modes)
                   '(ltex-plus-mode-test-unknown-mode "plaintext" nil)))))

(ert-deftest ltex-plus-mode-test-an-explicit-call-asks-for-the-language ()
  "Interactively the language identifier is requested, with a default."
  (ltex-plus-mode-test--with-server-present
    (setq major-mode 'ltex-plus-mode-test-asked-mode)
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "typst")))
      (funcall-interactively #'lsp-ltex-plus-mode 1))
    (should (equal (assq 'ltex-plus-mode-test-asked-mode lsp-ltex-plus-major-modes)
                   '(ltex-plus-mode-test-asked-mode "typst" nil)))))

(ert-deftest ltex-plus-mode-test-a-known-mode-is-not-registered-twice ()
  "A mode already in the table is left exactly as it is."
  (ltex-plus-mode-test--with-server-present
    (setq major-mode 'markdown-mode)
    (let ((before (copy-tree lsp-ltex-plus-major-modes)))
      (lsp-ltex-plus-mode 1)
      (should (equal lsp-ltex-plus-major-modes before)))))

(ert-deftest ltex-plus-mode-test-a-file-less-buffer-is-declined-when-opted-out ()
  "With `lsp-ltex-plus-check-fileless-buffers' off, a buffer with no file is left alone.
The mode variable is left nil, so nothing claims to be checking it."
  (ltex-plus-mode-test--with-server-present
    (setq major-mode 'markdown-mode)
    (let ((lsp-ltex-plus-check-fileless-buffers nil))
      (lsp-ltex-plus-mode 1))
    (should-not lsp-ltex-plus-mode)))

;;;; -- Against the fake -------------------------------------------------------

(defmacro ltex-plus-mode-test--with-file (var contents &rest body)
  "Run BODY with VAR bound to a buffer visiting an `.rst' file of CONTENTS."
  (declare (indent 2) (debug (symbolp form body)))
  `(ltex-plus-test-with-project (list (cons "note.rst" ,contents))
     (let ((,var (ltex-plus-test-visit (project-file "note.rst")))
           (inhibit-message t))
       (with-current-buffer ,var (rst-mode))
       ,@body)))

(ert-deftest ltex-plus-mode-test-enabling-opens-the-document-under-flymake ()
  "Turning the mode on opens the buffer on the server and shows its findings."
  (ltex-plus-fake-with-connection
    (ltex-plus-mode-test--with-file buffer "Hello teh world.\n"
      (with-current-buffer buffer
        (lsp-ltex-plus-mode 1)
        (should lsp-ltex-plus-mode)
        (should flymake-mode)
        (should (memq #'lsp-ltex-plus-flymake-backend flymake-diagnostic-functions))
        (flymake-start))
      (ltex-plus-fake-wait-for (lambda () (ltex-plus-fake-received 'textDocument/didOpen)))
      (should (lsp-ltex-plus--document-open-p buffer))
      (ltex-plus-fake-wait-for
       (lambda () (with-current-buffer buffer (flymake-diagnostics)))))))

(ert-deftest ltex-plus-mode-test-disabling-closes-the-document-and-clears ()
  "Turning the mode off closes the document and takes the underlines away.
The server keeps running: another buffer may need it."
  (ltex-plus-fake-with-connection
    (ltex-plus-mode-test--with-file buffer "Hello teh world.\n"
      (with-current-buffer buffer (lsp-ltex-plus-mode 1) (flymake-start))
      (ltex-plus-fake-wait-for
       (lambda () (with-current-buffer buffer (flymake-diagnostics))))
      (with-current-buffer buffer (lsp-ltex-plus-mode -1))
      (ltex-plus-fake-wait-for (lambda () (ltex-plus-fake-received 'textDocument/didClose)))
      (should-not (lsp-ltex-plus--document-open-p buffer))
      (should-not (with-current-buffer buffer (flymake-diagnostics)))
      (should-not (with-current-buffer buffer
                    (memq #'lsp-ltex-plus-flymake-backend flymake-diagnostic-functions)))
      (should (lsp-ltex-plus--live-connection)))))

;;;; -- Flyspell ------------------------------------------------------------------

;; The real `flyspell-mode' needs a spell-checking program, which the CI
;; runners do not have, and stays off without one.  What is under test is
;; what this package reads and calls, so the mode function is stubbed to
;; toggle the variable and record the calls.

(defmacro ltex-plus-mode-test--with-stub-flyspell (calls &rest body)
  "Run BODY with `flyspell-mode' stubbed; CALLS collects its arguments."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((,calls nil))
     (cl-letf (((symbol-function 'flyspell-mode)
                (lambda (&optional arg)
                  (push arg ,calls)
                  (setq flyspell-mode (not (and (numberp arg) (< arg 0)))))))
       ,@body)))

(ert-deftest ltex-plus-mode-test-flyspell-is-left-alone-by-default ()
  "With the option off, flyspell is neither stopped nor started."
  (ltex-plus-fake-with-connection
    (ltex-plus-mode-test--with-file buffer "Text.\n"
      (with-current-buffer buffer
        (ltex-plus-mode-test--with-stub-flyspell calls
          (setq-local flyspell-mode t)
          (let ((lsp-ltex-plus-disable-flyspell nil))
            (lsp-ltex-plus-mode 1)
            (lsp-ltex-plus-mode -1))
          (should flyspell-mode)
          (should-not calls))))))

(ert-deftest ltex-plus-mode-test-flyspell-is-stopped-and-restored-when-asked ()
  "With the option on, flyspell goes off with the mode and comes back with it."
  (ltex-plus-fake-with-connection
    (ltex-plus-mode-test--with-file buffer "Text.\n"
      (with-current-buffer buffer
        (ltex-plus-mode-test--with-stub-flyspell calls
          (setq-local flyspell-mode t)
          (let ((lsp-ltex-plus-disable-flyspell t))
            (lsp-ltex-plus-mode 1)
            (should-not flyspell-mode)
            (should lsp-ltex-plus--stopped-flyspell)
            (lsp-ltex-plus-mode -1))
          (should flyspell-mode)
          (should-not lsp-ltex-plus--stopped-flyspell)
          (should (equal (reverse calls) '(-1 1))))))))

(ert-deftest ltex-plus-mode-test-flyspell-that-was-off-stays-off ()
  "The option never turns flyspell on: a buffer without it is left without it."
  (ltex-plus-fake-with-connection
    (ltex-plus-mode-test--with-file buffer "Text.\n"
      (with-current-buffer buffer
        (ltex-plus-mode-test--with-stub-flyspell calls
          (should-not flyspell-mode)
          (let ((lsp-ltex-plus-disable-flyspell t))
            (lsp-ltex-plus-mode 1)
            (lsp-ltex-plus-mode -1))
          (should-not flyspell-mode)
          (should-not calls))))))

;;;; -- Choosing the front-end -------------------------------------------------

;; The flycheck side is stubbed here: what is under test is which
;; front-end the mode reaches for and which it lets go of, not what
;; flycheck does once reached.  `ltex-plus-flycheck-test.el' covers that.

(defmacro ltex-plus-mode-test--with-stub-flycheck (available calls &rest body)
  "Run BODY with flycheck AVAILABLE or not, its attach and detach stubbed.
CALLS collects the stubs' names in the order they were called."
  (declare (indent 2) (debug (form symbolp body)))
  `(let ((,calls nil)
         (lsp-ltex-plus--warned-about-flycheck nil))
     (cl-letf (((symbol-function 'lsp-ltex-plus--flycheck-available-p)
                (lambda () ,available))
               ((symbol-function 'lsp-ltex-plus--flycheck-attach)
                (lambda () (push 'attach ,calls)))
               ((symbol-function 'lsp-ltex-plus--flycheck-detach)
                (lambda () (push 'detach ,calls))))
       ,@body)))

(ert-deftest ltex-plus-mode-test-flymake-is-the-default-front-end ()
  "With the option at its default, flymake is attached and flycheck untouched."
  (ltex-plus-fake-with-connection
    (ltex-plus-mode-test--with-file buffer "Text.\n"
      (with-current-buffer buffer
        (ltex-plus-mode-test--with-stub-flycheck t calls
          (let ((lsp-ltex-plus-diagnostics-provider 'flymake))
            (lsp-ltex-plus-mode 1)
            (should (eq 'flymake lsp-ltex-plus--attached-provider))
            (should (memq #'lsp-ltex-plus-flymake-backend flymake-diagnostic-functions))
            (lsp-ltex-plus-mode -1))
          (should-not lsp-ltex-plus--attached-provider)
          (should-not (memq #'lsp-ltex-plus-flymake-backend flymake-diagnostic-functions))
          (should-not calls))))))

(ert-deftest ltex-plus-mode-test-flycheck-is-attached-when-chosen-and-present ()
  "Asking for flycheck attaches it, not flymake, and detaches it with the mode."
  (ltex-plus-fake-with-connection
    (ltex-plus-mode-test--with-file buffer "Text.\n"
      (with-current-buffer buffer
        (ltex-plus-mode-test--with-stub-flycheck t calls
          (let ((lsp-ltex-plus-diagnostics-provider 'flycheck))
            (lsp-ltex-plus-mode 1)
            (should (eq 'flycheck lsp-ltex-plus--attached-provider))
            (should-not (memq #'lsp-ltex-plus-flymake-backend flymake-diagnostic-functions))
            (should-not flymake-mode)
            (lsp-ltex-plus-mode -1))
          (should-not lsp-ltex-plus--attached-provider)
          (should (equal (reverse calls) '(attach detach))))))))

(ert-deftest ltex-plus-mode-test-flycheck-absent-falls-back-on-flymake-with-one-warning ()
  "Flycheck chosen but not installed gives flymake, and says so once.
Declining to check the buffer over a display preference would be the
wrong trade; a warning on every buffer would be noise."
  (ltex-plus-fake-with-connection
    (ltex-plus-test-with-project '(("a.rst" . "Text.\n") ("b.rst" . "More.\n"))
      (let ((warnings nil)
            (inhibit-message t))
        (ltex-plus-mode-test--with-stub-flycheck nil calls
          (cl-letf (((symbol-function 'display-warning)
                     (lambda (_type message &rest _) (push message warnings))))
            (let ((lsp-ltex-plus-diagnostics-provider 'flycheck))
              (dolist (name '("a.rst" "b.rst"))
                (with-current-buffer (ltex-plus-test-visit (project-file name))
                  (rst-mode)
                  (lsp-ltex-plus-mode 1)
                  (should (eq 'flymake lsp-ltex-plus--attached-provider))
                  (should (memq #'lsp-ltex-plus-flymake-backend
                                flymake-diagnostic-functions))))))
          (should-not calls)
          (should (= 1 (length warnings)))
          (should (string-match-p "flycheck is not installed" (car warnings))))))))

(ert-deftest ltex-plus-mode-test-detaching-undoes-the-front-end-actually-attached ()
  "A buffer attached under flymake is detached from flymake, whatever the option now says.
Changing the option while a buffer is being checked must not leave the
old front-end's backend behind, nor poke a front-end that was never
attached."
  (ltex-plus-fake-with-connection
    (ltex-plus-mode-test--with-file buffer "Text.\n"
      (with-current-buffer buffer
        (ltex-plus-mode-test--with-stub-flycheck t calls
          (let ((lsp-ltex-plus-diagnostics-provider 'flymake))
            (lsp-ltex-plus-mode 1))
          (let ((lsp-ltex-plus-diagnostics-provider 'flycheck))
            (lsp-ltex-plus-mode -1))
          (should-not (memq #'lsp-ltex-plus-flymake-backend flymake-diagnostic-functions))
          (should-not lsp-ltex-plus--attached-provider)
          (should-not calls))))))

(ert-deftest ltex-plus-mode-test-shutting-the-server-down-switches-the-mode-off ()
  "`lsp-ltex-plus-shutdown-server' ends the server and the mode in its buffers."
  (ltex-plus-fake-with-connection
    (ltex-plus-mode-test--with-file buffer "Text.\n"
      (with-current-buffer buffer (lsp-ltex-plus-mode 1))
      (ltex-plus-fake-wait-for (lambda () (ltex-plus-fake-received 'textDocument/didOpen)))
      (lsp-ltex-plus-shutdown-server)
      (should-not (lsp-ltex-plus--live-connection))
      (should-not (buffer-local-value 'lsp-ltex-plus-mode buffer))
      (should-not (lsp-ltex-plus--document-open-p buffer)))))

(ert-deftest ltex-plus-mode-test-a-server-that-dies-switches-the-mode-off ()
  "When the server goes away on its own, no buffer is left claiming to be checked."
  (ltex-plus-fake-with-connection
    (ltex-plus-mode-test--with-file buffer "Text.\n"
      (with-current-buffer buffer (lsp-ltex-plus-mode 1))
      (ltex-plus-fake-wait-for (lambda () (ltex-plus-fake-received 'textDocument/didOpen)))
      (let ((conn lsp-ltex-plus--connection))
        (ltex-plus-fake-stop)
        (ltex-plus-fake-wait-for (lambda () (not (jsonrpc-running-p conn)))))
      (should-not (buffer-local-value 'lsp-ltex-plus-mode buffer)))))

(ert-deftest ltex-plus-mode-test-restarting-reopens-every-checked-buffer ()
  "`lsp-ltex-plus-restart-server' brings a new server up with the same buffers."
  (ltex-plus-fake-with-connection
    (ltex-plus-mode-test--with-file buffer "Text.\n"
      (with-current-buffer buffer (lsp-ltex-plus-mode 1))
      (ltex-plus-fake-wait-for (lambda () (ltex-plus-fake-received 'textDocument/didOpen)))
      (let ((first lsp-ltex-plus--connection))
        ;; The fake must be listening again for the new server to connect.
        (cl-letf (((symbol-function 'lsp-ltex-plus--shutdown-connection)
                   (let ((original (symbol-function 'lsp-ltex-plus--shutdown-connection)))
                     (lambda (&rest args)
                       (apply original args)
                       (ltex-plus-fake-start)))))
          (lsp-ltex-plus-restart-server))
        (should (buffer-local-value 'lsp-ltex-plus-mode buffer))
        (ltex-plus-fake-wait-for (lambda () (ltex-plus-fake-received 'textDocument/didOpen)))
        (should-not (eq first lsp-ltex-plus--connection))
        (should (lsp-ltex-plus--document-open-p buffer))))))

(provide 'ltex-plus-mode-test)
;;; ltex-plus-mode-test.el ends here
