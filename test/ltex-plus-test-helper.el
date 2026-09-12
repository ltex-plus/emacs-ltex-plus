;;; ltex-plus-test-helper.el --- Shared fixtures for the test suite -*- lexical-binding: t; -*-

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:

;; Loaded first by every file in `test/'.  It does two things, in order,
;; and the order matters:
;;
;; 1. Redirects `user-emacs-directory' into a throwaway sandbox.  The
;;    package derives file paths from it at *load* time -- the four
;;    `lsp-ltex-plus-*-file' variables among them -- so a test run must
;;    never see, and can never write to, the real one.  Without this the
;;    suite silently mixes the developer's own dictionary into its
;;    results.
;;
;; 2. Loads the package from this repository, by explicit path.
;;
;; What is left is fixtures.  `ltex-plus-test-with-project' builds a
;; throwaway project tree and visits files in it; `ltex-plus-test-reset'
;; empties every list the package holds in memory and points the global
;; files at a fresh directory.  Call the latter at the top of any test that
;; asserts on list contents: a test that inherits its state from a
;; previous one is a test that passes alone and fails in the suite.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ert)

;;;; -- Sandboxed `user-emacs-directory' ---------------------------------------

(defconst ltex-plus-test-sandbox
  (file-name-as-directory (make-temp-file "ltex-plus-test-home-" t))
  "Throwaway `user-emacs-directory' for this Emacs process.
Installed below before anything else is loaded, so that every path the
package computes from `user-emacs-directory' at load time lands here
rather than in the developer's real configuration.")

(setq user-emacs-directory ltex-plus-test-sandbox)

;;;; -- Loading the package under test -----------------------------------------

(defconst ltex-plus-test-repo-root
  (file-name-as-directory
   (expand-file-name
    ".." (file-name-directory (or load-file-name buffer-file-name))))
  "Absolute path of the repository this suite tests.
Derived from this file's own location, so the suite runs from any
working directory and from any clone.")

(add-to-list 'load-path ltex-plus-test-repo-root)

;; Load the package files by explicit path, with an explicit `.el' and
;; NOSUFFIX set, rather than through `require'.  Two things would otherwise
;; decide for us which code the suite tests, and neither announces itself:
;;
;;   * a stale `.elc' beside the sources -- from compiling in Emacs, or from
;;     an interrupted `make compile' -- shadows the `.el' it was built from,
;;     so the suite quietly tests the previous version of the package;
;;   * the developer very likely has `lsp-ltex-plus' installed for their own
;;     use, and an installed copy may be on `load-path' too.
(setq load-prefer-newer t)

(defconst ltex-plus-test-package-files
  (mapcar (lambda (name) (expand-file-name name ltex-plus-test-repo-root))
          '("lsp-ltex-plus-bootstrap.el" "lsp-ltex-plus-settings.el"
            "lsp-ltex-plus-conn.el" "lsp-ltex-plus.el"))
  "The package sources this suite tests, in load order.")

(dolist (file ltex-plus-test-package-files)
  (unless (file-exists-p file)
    (error "No package source at %s; is %s the repository root?"
           file ltex-plus-test-repo-root))
  (load file nil t t))

;;;; -- Demoted errors under ERT -----------------------------------------------

(defmacro ltex-plus-test-without-debugger (&rest body)
  "Run BODY with `debug-on-error\=' nil, whatever ERT set it to.
`with-demoted-errors\=' is `condition-case-unless-debug\=', so it demotes
nothing while the debugger is armed.  ERT up to Emacs 29 arms it around
every test (from Emacs 30 it uses `handler-bind\=' and leaves the
variable alone), which turns any test of a demoted path into a test of
the Emacs version instead: passing on 30 and later, failing on 29.  Wrap
such a test in this to assert on what a user actually gets."
  (declare (indent 0) (debug t))
  `(let ((debug-on-error nil))
     ,@body))

;;;; -- Reading the language-keyed plists --------------------------------------

(defun ltex-plus-test-words (plist &optional language)
  "Return PLIST's entries for LANGUAGE (default `:en-US') as a list.
The package stores them as vectors; a list compares more legibly in a
failure report."
  (append (plist-get plist (or language :en-US)) nil))

(defun ltex-plus-test-read-file (path)
  "Return the plist stored at PATH, or nil when PATH does not exist."
  (when (file-exists-p path)
    (with-temp-buffer
      (insert-file-contents path)
      (read (current-buffer)))))

(defun ltex-plus-test-write-file (path contents)
  "Write CONTENTS, a string, to PATH, creating parent directories."
  (make-directory (file-name-directory path) t)
  (with-temp-file path (insert contents)))

;;;; -- Resetting the package's in-memory state --------------------------------

(defvar ltex-plus-test--global-dir nil
  "Directory the global settings files point at for the current test.")

(defun ltex-plus-test-global-file (kind)
  "Return the path of the global file for KIND during the current test.
KIND is a key of `lsp-ltex-plus--setting-kinds'."
  (symbol-value (lsp-ltex-plus--kind-get kind :global-file)))

(defun ltex-plus-test-reset ()
  "Give the current test empty lists and its own global settings files.
Any earlier test may have written to the mirrors; they are cleared here
so that a result can only come from what the test itself put there.  The
four global files are repointed at a fresh temporary directory, so a
test that writes one never sees another test's leftovers — nor the
developer's real dictionary, which the sandbox already rules out."
  (setq ltex-plus-test--global-dir
        (file-name-as-directory (make-temp-file "ltex-plus-test-global-" t)))
  (setq lsp-ltex-plus-dictionary-file
        (expand-file-name "stored-dictionary.eld" ltex-plus-test--global-dir)
        lsp-ltex-plus-enabled-rules-file
        (expand-file-name "enabled-rules.eld" ltex-plus-test--global-dir)
        lsp-ltex-plus-disabled-rules-file
        (expand-file-name "disabled-rules.eld" ltex-plus-test--global-dir)
        lsp-ltex-plus-hidden-false-positives-file
        (expand-file-name "hidden-false-positives.eld" ltex-plus-test--global-dir))
  (setq lsp-ltex-plus-dictionary nil
        lsp-ltex-plus-enabled-rules nil
        lsp-ltex-plus-disabled-rules nil
        lsp-ltex-plus-hidden-false-positives nil
        lsp-ltex-plus--dictionary-stored nil
        lsp-ltex-plus--enabled-rules-stored nil
        lsp-ltex-plus--disabled-rules-stored nil
        lsp-ltex-plus--hidden-false-positives-stored nil)
  (clrhash lsp-ltex-plus--project-file-cache)
  (lsp-ltex-plus--recompute-merged))

;;;; -- Throwaway project trees ------------------------------------------------

(defvar ltex-plus-test-root nil
  "Root of the throwaway directory tree inside `ltex-plus-test-with-project'.")

(defun ltex-plus-test-visit (path)
  "Visit PATH with directory-local variables applied, and return the buffer.
Buffers opened this way are killed when `ltex-plus-test-with-project'
unwinds.  `enable-local-variables' is bound to `:all' so that the values
under test apply without a prompt regardless of how the running Emacs is
configured — the safe-value predicates are asserted on directly, in
`ltex-plus-safety-test.el', rather than through this side door."
  (let ((enable-local-variables :all))
    (find-file-noselect path)))

(defmacro ltex-plus-test-with-project (spec &rest body)
  "Run BODY with a throwaway directory tree built from SPEC.

SPEC is a list of (RELATIVE-PATH . CONTENTS) pairs; each file is created
under a fresh temporary root, with parent directories as needed.  Inside
BODY, `ltex-plus-test-root' is that root and the local function
`project-file' expands a relative path against it.

The tree, and every buffer `ltex-plus-test-visit' opened while BODY ran,
are removed on exit — including when BODY signals, so one failing test
does not leave a visiting buffer behind to answer a later test's
`find-buffer-visiting'."
  (declare (indent 1) (debug (form body)))
  `(let* ((ltex-plus-test-root
           (file-name-as-directory (make-temp-file "ltex-plus-test-" t)))
          (ltex-plus-test--buffers-before (buffer-list)))
     (cl-flet ((project-file (name) (expand-file-name name ltex-plus-test-root)))
       (ignore #'project-file)
       (unwind-protect
           (progn
             (pcase-dolist (`(,path . ,contents) ,spec)
               (ltex-plus-test-write-file
                (expand-file-name path ltex-plus-test-root) contents))
             ,@body)
         (dolist (buf (buffer-list))
           (unless (memq buf ltex-plus-test--buffers-before)
             (when (buffer-file-name buf)
               (with-current-buffer buf (set-buffer-modified-p nil))
               (kill-buffer buf))))
         (delete-directory ltex-plus-test-root t)))))

(provide 'ltex-plus-test-helper)
;;; ltex-plus-test-helper.el ends here
