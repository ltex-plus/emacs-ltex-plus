;;; ltex-plus-bootstrap-test.el --- Activation model -*- lexical-binding: t; -*-

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:

;; The mode table and the single dispatcher that reads it.
;;
;; Activation deliberately does not use per-mode hooks; the reason is
;; recorded under "Do not revert activation to per-mode hooks" in
;; `CLAUDE.md'.  Emacs mode hooks inherit, so `text-mode-hook' fires in an
;; `org-mode' buffer and `:exclude '(org-mode)' could not actually exclude
;; anything.  `lsp-ltex-plus--maybe-activate' matches `major-mode' with
;; `memq' instead, and `ltex-plus-bootstrap-test-dispatcher-...' below is
;; what would fail if someone went back to `add-hook'.

;;; Code:

(require 'ltex-plus-test-helper)

(ert-deftest ltex-plus-bootstrap-test-the-package-under-test-is-this-clone ()
  "The suite loaded this repository's sources, not an installed copy.
Two things can quietly substitute other code: a stale `.elc' beside the
sources, and the developer's own installation of the package, which the
dependency search puts on `load-path' along with everything else.  The
helper loads the two files by explicit path to rule both out; this is
that guarantee, asserted rather than assumed."
  (dolist (symbol '(lsp-ltex-plus--setup lsp-ltex-plus--maybe-activate))
    (should (member (symbol-file symbol 'defun) ltex-plus-test-package-files))))

;;;; -- The mode table ---------------------------------------------------------

(ert-deftest ltex-plus-bootstrap-test-entries-are-well-formed ()
  "Every entry is (MAJOR-MODE LANGUAGE-ID PROGRAMMING-P), and nothing else.
A fourth element or a missing language id would be read as nil by
`cadr'/`caddr' and send the wrong `languageId' over the wire, silently."
  (dolist (entry lsp-ltex-plus-major-modes)
    (should (= (length entry) 3))
    (pcase-let ((`(,mode ,language-id ,programming-p) entry))
      (should (symbolp mode))
      (should (stringp language-id))
      (should (> (length language-id) 0))
      (should (memq programming-p '(nil t))))))

(ert-deftest ltex-plus-bootstrap-test-modes-are-unique ()
  "No major mode is listed twice.
Two entries for one mode make the language id depend on `assq' order."
  (let ((modes (mapcar #'car lsp-ltex-plus-major-modes)))
    (should (equal (sort (copy-sequence modes) #'string<)
                   (sort (seq-uniq modes) #'string<)))))

(ert-deftest ltex-plus-bootstrap-test-markup-modes-are-not-programming ()
  "The modes checked by default stay checked by default.
`PROGRAMMING-P' gates a mode behind
`lsp-ltex-plus-check-programming-languages'; flipping one of these to t
would quietly stop checking prose."
  (dolist (mode '(text-mode markdown-mode org-mode latex-mode LaTeX-mode
                  rst-mode bibtex-mode html-mode))
    (should (equal (assq mode lsp-ltex-plus-major-modes)
                   (list mode (cadr (assq mode lsp-ltex-plus-major-modes)) nil))))
  (dolist (mode '(python-mode c-mode rust-mode emacs-lisp-mode sh-mode))
    (should (nth 2 (assq mode lsp-ltex-plus-major-modes)))))

(ert-deftest ltex-plus-bootstrap-test-enabled-languages-are-unique ()
  "`ltex.enabled' carries each language id once.
Several modes share an id — three map to \"latex\" — and the server is
sent the set, not the multiset."
  (let ((languages (lsp-ltex-plus--enabled-languages)))
    (should (equal languages (seq-uniq languages #'string=)))
    (should (member "latex" languages))
    (should (member "markdown" languages))))

;;;; -- Building the enabled set -----------------------------------------------

(defmacro ltex-plus-bootstrap-test--with-clean-hook (&rest body)
  "Run BODY with the dispatcher hook and enabled set restored afterwards.
`lsp-ltex-plus-enable-for-modes' writes to both, and they are global."
  (declare (indent 0) (debug t))
  `(let ((after-change-major-mode-hook (copy-sequence after-change-major-mode-hook))
         (lsp-ltex-plus--enabled-modes lsp-ltex-plus--enabled-modes))
     ,@body))

(ert-deftest ltex-plus-bootstrap-test-default-enables-every-mode ()
  "With no arguments the whole table is enabled."
  (ltex-plus-bootstrap-test--with-clean-hook
    (lsp-ltex-plus-enable-for-modes)
    (should (equal lsp-ltex-plus--enabled-modes
                   (mapcar #'car lsp-ltex-plus-major-modes)))))

(ert-deftest ltex-plus-bootstrap-test-restrict-to-is-a-whitelist ()
  "`:restrict-to' keeps only the listed modes, and drops unknown ones.
A mode absent from the table has no language id, so enabling it would
mean sending nil over the wire; it is skipped rather than guessed at."
  (ltex-plus-bootstrap-test--with-clean-hook
    (lsp-ltex-plus-enable-for-modes
     :restrict-to '(org-mode markdown-mode no-such-mode))
    (should (equal lsp-ltex-plus--enabled-modes '(org-mode markdown-mode)))))

(ert-deftest ltex-plus-bootstrap-test-exclude-is-a-blacklist ()
  "`:exclude' removes the listed modes and leaves the rest."
  (ltex-plus-bootstrap-test--with-clean-hook
    (lsp-ltex-plus-enable-for-modes :exclude '(org-mode python-mode))
    (should-not (memq 'org-mode lsp-ltex-plus--enabled-modes))
    (should-not (memq 'python-mode lsp-ltex-plus--enabled-modes))
    (should (memq 'markdown-mode lsp-ltex-plus--enabled-modes))))

(ert-deftest ltex-plus-bootstrap-test-extend-to-appends ()
  "`:extend-to' adds modes the table does not carry."
  (ltex-plus-bootstrap-test--with-clean-hook
    (lsp-ltex-plus-enable-for-modes
     :restrict-to '(org-mode)
     :extend-to '((ltex-plus-test-fake-mode "plaintext" nil)))
    (should (equal lsp-ltex-plus--enabled-modes
                   '(org-mode ltex-plus-test-fake-mode)))))

(ert-deftest ltex-plus-bootstrap-test-extend-to-survives-exclude ()
  "`:extend-to' is applied after `:exclude', so it is never filtered out.
Documented in `lsp-ltex-plus-enable-for-modes': the additions are
\"never affected by `:exclude'\"."
  (ltex-plus-bootstrap-test--with-clean-hook
    (lsp-ltex-plus-enable-for-modes
     :restrict-to '(org-mode markdown-mode)
     :exclude '(markdown-mode ltex-plus-test-fake-mode)
     :extend-to '((ltex-plus-test-fake-mode "plaintext" nil)))
    (should (equal lsp-ltex-plus--enabled-modes
                   '(org-mode ltex-plus-test-fake-mode)))))

(ert-deftest ltex-plus-bootstrap-test-calling-again-replaces-the-set ()
  "A second call replaces the enabled set and does not stack the hook."
  (ltex-plus-bootstrap-test--with-clean-hook
    (lsp-ltex-plus-enable-for-modes :restrict-to '(org-mode))
    (lsp-ltex-plus-enable-for-modes :restrict-to '(markdown-mode))
    (should (equal lsp-ltex-plus--enabled-modes '(markdown-mode)))
    (should (= 1 (seq-count (lambda (f) (eq f #'lsp-ltex-plus--maybe-activate))
                            after-change-major-mode-hook)))))

(ert-deftest ltex-plus-bootstrap-test-does-not-mutate-the-table ()
  "Filtering leaves `lsp-ltex-plus-major-modes' as it found it.
The list is copied before `:exclude' runs; without that, one call with
`:exclude' would narrow every later call."
  (ltex-plus-bootstrap-test--with-clean-hook
    (let ((before (copy-tree lsp-ltex-plus-major-modes)))
      (lsp-ltex-plus-enable-for-modes :exclude '(org-mode)
                                      :extend-to '((fake-mode "plaintext" nil)))
      (should (equal lsp-ltex-plus-major-modes before)))))

;;;; -- The dispatcher ---------------------------------------------------------

(defun ltex-plus-bootstrap-test--activations (mode &rest body-settings)
  "Return the modes `lsp-ltex-plus--maybe-activate' would turn the client on in.
Runs the dispatcher in a temp buffer whose `major-mode' is MODE, with
`lsp-ltex-plus-mode' stubbed out so nothing is started.  BODY-SETTINGS
are extra (SYMBOL VALUE) bindings in force during the call."
  (let ((called nil))
    (cl-letf (((symbol-function 'lsp-ltex-plus-mode)
               (lambda (&rest _) (setq called t))))
      (with-temp-buffer
        (setq major-mode mode)
        (cl-progv (mapcar #'car body-settings) (mapcar #'cadr body-settings)
          (lsp-ltex-plus--maybe-activate))))
    called))

(ert-deftest ltex-plus-bootstrap-test-dispatcher-matches-exactly ()
  "The dispatcher matches `major-mode' itself, never a parent mode.
This is the whole reason activation is one dispatcher rather than a hook
per mode: `org-mode' derives from `text-mode', so with per-mode hooks an
enabled `text-mode' would activate the client in every org buffer and
`:exclude \\='(org-mode)' would be unable to stop it."
  (ltex-plus-bootstrap-test--with-clean-hook
    (lsp-ltex-plus-enable-for-modes :restrict-to '(text-mode))
    (should (ltex-plus-bootstrap-test--activations 'text-mode))
    (should-not (ltex-plus-bootstrap-test--activations 'org-mode))))

(ert-deftest ltex-plus-bootstrap-test-dispatcher-skips-unlisted-modes ()
  "A mode outside the enabled set is left alone."
  (ltex-plus-bootstrap-test--with-clean-hook
    (lsp-ltex-plus-enable-for-modes :restrict-to '(markdown-mode))
    (should-not (ltex-plus-bootstrap-test--activations 'python-mode))))

(ert-deftest ltex-plus-bootstrap-test-dispatcher-and-fileless-buffers ()
  "A file-less buffer is dispatched only when the user has opted in.
`lsp-ltex-plus-check-fileless-buffers' lives in the lazily-loaded half of
the package, so the dispatcher reads it with `bound-and-true-p' rather
than forcing that load; both answers must still be honoured."
  (ltex-plus-bootstrap-test--with-clean-hook
    (lsp-ltex-plus-enable-for-modes :restrict-to '(text-mode))
    (should (ltex-plus-bootstrap-test--activations
             'text-mode '(lsp-ltex-plus-check-fileless-buffers t)))
    (should-not (ltex-plus-bootstrap-test--activations
                 'text-mode '(lsp-ltex-plus-check-fileless-buffers nil)))))

;;;; -- Language id resolution -------------------------------------------------

(ert-deftest ltex-plus-bootstrap-test-language-ids-are-registered ()
  "`lsp-ltex-plus--setup' seeds `lsp-language-id-configuration'.
Only to keep lsp-mode from warning \"Unable to calculate the
languageId\"; the id actually sent comes from the `:language-id' lambda,
which reads the same table."
  (dolist (mode '(markdown-mode org-mode text-mode))
    (should (assq mode lsp-language-id-configuration))))

(ert-deftest ltex-plus-bootstrap-test-setup-leaves-the-table-alone-on-rerun ()
  "Re-running setup adds nothing to `lsp-language-id-configuration'.
`lsp-ltex-plus-reload-settings' calls `lsp-ltex-plus--setup', so repeated
calls are a user-facing path: the mode registration pushes only entries
that are absent, and must not grow the alist each time round."
  (let ((before (copy-alist lsp-language-id-configuration)))
    (lsp-ltex-plus--setup)
    (should (equal lsp-language-id-configuration before))))

(ert-deftest ltex-plus-bootstrap-test-setup-defers-to-lsp-mode ()
  "A mode lsp-mode already maps is not remapped by our setup.
The registration exists only to silence lsp-mode's \"Unable to calculate
the languageId\" warning; where lsp-mode has an opinion it keeps it."
  (let* ((mode 'ltex-plus-test-claimed-mode)
         (lsp-language-id-configuration
          (cons (cons mode "claimed-by-lsp-mode")
                (copy-alist lsp-language-id-configuration)))
         (lsp-ltex-plus-major-modes
          (cons (list mode "claimed-by-ltex-plus" nil)
                lsp-ltex-plus-major-modes)))
    (lsp-ltex-plus--setup)
    (should (equal (cdr (assq mode lsp-language-id-configuration))
                   "claimed-by-lsp-mode"))
    (should (= 1 (seq-count (lambda (e) (eq (car-safe e) mode))
                            lsp-language-id-configuration)))))

(provide 'ltex-plus-bootstrap-test)
;;; ltex-plus-bootstrap-test.el ends here
