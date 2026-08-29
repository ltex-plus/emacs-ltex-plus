;;; ltex-plus-test-helper.el --- Shared fixtures for the test suite -*- lexical-binding: t; -*-

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:

;; Loaded first by every file in `test/'.  It does three things, in order,
;; and the order matters:
;;
;; 1. Redirects `user-emacs-directory' into a throwaway sandbox.  Both
;;    `lsp-mode' and this package derive file paths from it at *load* time
;;    -- the four `lsp-ltex-plus-*-file' variables among them -- so a test
;;    run must never see, and can never write to, the real one.  Without
;;    this the suite silently mixes the developer's own dictionary into its
;;    results.
;;
;; 2. Finds `lsp-mode' and its dependencies.  There is no Cask or Eldev
;;    here, so the search is by convention: `LTEX_PLUS_LOAD_PATH' if set,
;;    otherwise the first straight.el build tree or package.el archive
;;    found in the usual places.  See `ltex-plus-test--dependency-roots'.
;;
;; 3. Loads the package, which runs `lsp-ltex-plus--setup' -- in the
;;    sandbox, so it reads four files that do not exist.
;;
;; What is left is fixtures.  `ltex-plus-test-with-project' builds a
;; throwaway project tree and visits files in it; `ltex-plus-test-reset'
;; empties every list the package holds in memory and points the global
;; files at a fresh directory.  Call the latter at the top of any test that
;; asserts on list contents: `lsp-ltex-plus--setup' has run by then, and a
;; test that inherits its state from a previous one is a test that passes
;; alone and fails in the suite.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ert)

;;;; -- Sandboxed `user-emacs-directory' ---------------------------------------

(defconst ltex-plus-test-sandbox
  (file-name-as-directory (make-temp-file "ltex-plus-test-home-" t))
  "Throwaway `user-emacs-directory' for this Emacs process.
Installed below before anything else is loaded, so that every path
`lsp-mode' and the package compute from `user-emacs-directory' at load
time lands here rather than in the developer's real configuration.")

(setq user-emacs-directory ltex-plus-test-sandbox)

;;;; -- Locating lsp-mode ------------------------------------------------------

(defun ltex-plus-test--dependency-roots ()
  "Return directories that hold one installed package per subdirectory.
The package has no build tooling of its own, so `lsp-mode' is found
wherever the developer already keeps it: a straight.el build tree or a
package.el archive, under either the XDG or the classic Emacs directory.
Set `LTEX_PLUS_LOAD_PATH' (colon-separated, added verbatim to
`load-path') to override the search entirely."
  (let ((xdg (or (getenv "XDG_CONFIG_HOME") "~/.config")))
    (seq-filter
     #'file-directory-p
     (mapcar
      #'expand-file-name
      (delq nil
            (list (getenv "LTEX_PLUS_STRAIGHT_BUILD")
                  (expand-file-name "emacs/straight/build" xdg)
                  "~/.emacs.d/straight/build"
                  (expand-file-name "emacs/elpa" xdg)
                  "~/.emacs.d/elpa"
                  (bound-and-true-p package-user-dir)))))))

(defun ltex-plus-test--add-dependencies ()
  "Put `lsp-mode' and its dependencies on `load-path'.
Honours `LTEX_PLUS_LOAD_PATH' when set.  Otherwise takes the first root
from `ltex-plus-test--dependency-roots' that actually contains an
`lsp-mode' installation and adds every package directory under it —
`lsp-mode' pulls in dash, f, ht, spinner, markdown-mode and lv, and that
list is upstream's to change, so the whole tree goes on rather than a
hand-kept subset."
  (if-let* ((explicit (getenv "LTEX_PLUS_LOAD_PATH")))
      (dolist (dir (split-string explicit path-separator t))
        (add-to-list 'load-path (expand-file-name dir)))
    (let ((root (seq-find
                 (lambda (dir)
                   (directory-files dir nil "\\`lsp-mode\\(-[0-9]\\|\\'\\)" t))
                 (ltex-plus-test--dependency-roots))))
      (unless root
        (error (concat "Cannot find lsp-mode.  Looked in %S.\n"
                       "Set LTEX_PLUS_LOAD_PATH to a colon-separated list of"
                       " directories holding lsp-mode and its dependencies,"
                       " or LTEX_PLUS_STRAIGHT_BUILD to a straight.el build"
                       " tree.")
               (ltex-plus-test--dependency-roots)))
      (dolist (dir (directory-files root t "\\`[^.]"))
        (when (file-directory-p dir)
          (add-to-list 'load-path dir))))))

(defun ltex-plus-test--load-lsp-mode-autoloads ()
  "Load `lsp-mode''s autoloads, as an installed Emacs would.
`emacs -Q' loads no package autoloads, so every optional `lsp-mode'
feature stays unbound -- and `lsp-configure-buffer' calls several of
them by name.  A live workspace then dies on `void-function
lsp-lens--enable', and the first such failure is swallowed by
`with-demoted-errors' inside the message handler, so it surfaces later
and somewhere else.  Loading the autoloads is what an installed session
does, and costs nothing here."
  (catch 'done
    (dolist (dir load-path)
      (let ((autoloads (expand-file-name "lsp-mode-autoloads.el" dir)))
        (when (file-exists-p autoloads)
          (load autoloads nil t)
          (throw 'done t))))))

(ltex-plus-test--add-dependencies)
(ltex-plus-test--load-lsp-mode-autoloads)

(require 'lsp-mode)

;;;; -- Loading the package under test -----------------------------------------

(defconst ltex-plus-test-repo-root
  (file-name-as-directory
   (expand-file-name
    ".." (file-name-directory (or load-file-name buffer-file-name))))
  "Absolute path of the repository this suite tests.
Derived from this file's own location, so the suite runs from any
working directory and from any clone.")

(add-to-list 'load-path ltex-plus-test-repo-root)

;; Load the two package files by explicit path, with an explicit `.el' and
;; NOSUFFIX set, rather than through `require'.  Two things would otherwise
;; decide for us which code the suite tests, and neither announces itself:
;;
;;   * a stale `.elc' beside the sources -- from compiling in Emacs, or from
;;     an interrupted `make compile' -- shadows the `.el' it was built from,
;;     so the suite quietly tests the previous version of the package;
;;   * the developer very likely has `lsp-ltex-plus' installed for their own
;;     use, and that installation is on `load-path' too, since the search
;;     above adds every package directory it finds.
;;
;; Loading the files runs `lsp-ltex-plus--setup' -- see the bottom of
;; `lsp-ltex-plus.el'.  That is deliberate: the registration path is itself
;; under test (see `ltex-plus-setup-test.el'), and running it in the sandbox
;; costs four reads of files that do not exist.
(setq load-prefer-newer t)

(defconst ltex-plus-test-package-files
  (mapcar (lambda (name) (expand-file-name name ltex-plus-test-repo-root))
          '("lsp-ltex-plus-bootstrap.el" "lsp-ltex-plus.el"))
  "The package sources this suite tests, in load order.")

(dolist (file ltex-plus-test-package-files)
  (unless (file-exists-p file)
    (error "No package source at %s; is %s the repository root?"
           file ltex-plus-test-repo-root))
  (load file nil t t))

;;;; -- Assertions on JSON objects ---------------------------------------------

;; `lsp-mode' represents JSON objects as hash tables, or as plists when it
;; was byte-compiled with `lsp-use-plists' set (the default in Doom).  The
;; package reads them through `lsp-get', which copes with either; fixtures
;; must be built the same way or the suite passes on one machine and fails
;; on the other for reasons that have nothing to do with the code.

(defun ltex-plus-test-obj (&rest pairs)
  "Build a JSON object from PAIRS in lsp-mode's current representation.
PAIRS are alternating keyword keys and values, as in
\(ltex-plus-test-obj :title \"Add \\='x\\='\" :kind \"quickfix\")."
  (if (bound-and-true-p lsp-use-plists)
      pairs
    (let ((table (make-hash-table :test #'equal)))
      (while pairs
        (puthash (substring (symbol-name (pop pairs)) 1) (pop pairs) table))
      table)))

(defun ltex-plus-test-suggestion (command title key entries)
  "Build a code action shaped like the ones ltex-ls-plus sends.
COMMAND is the server command id, TITLE the server's own localised
title, KEY the argument key carrying the entries \(`:words',
`:ruleIds' or `:falsePositives'\) and ENTRIES a list of strings, filed
under `:en-US'."
  (ltex-plus-test-obj
   :title title
   :kind "quickfix.ltex.acceptSuggestions"
   :command (ltex-plus-test-obj
             :command command
             :arguments (vector (ltex-plus-test-obj
                                 key (ltex-plus-test-obj
                                      :en-US (vconcat entries)))))))

(defun ltex-plus-test-accept (action)
  "Invoke ACTION's handler on its command object, as lsp-mode would.
lsp-mode looks the handler up on the registered client through a live
workspace, which a batch test has none of, so the mapping registered in
`lsp-ltex-plus--setup' is spelled out here instead."
  (let* ((command (lsp-get action :command))
         (name (lsp-get command :command))
         (handler (pcase name
                    ("_ltex.addToDictionary"
                     #'lsp-ltex-plus--action-add-to-dictionary)
                    ("_ltex.disableRules"
                     #'lsp-ltex-plus--action-disable-rules)
                    ("_ltex.hideFalsePositives"
                     #'lsp-ltex-plus--action-hide-false-positives)
                    (_ (error "No handler registered for command %S" name)))))
    (funcall handler command)))

(defun ltex-plus-test-titles (actions)
  "Return the `:title' of each action in ACTIONS, as a list."
  (mapcar (lambda (action) (lsp-get action :title)) (append actions nil)))

(defun ltex-plus-test-workspace (&optional root)
  "Return a workspace fixture rooted at ROOT, for the request handlers.
The two handlers take (WORKSPACE PARAMS) and need no live process, but
they do run inside `with-lsp-workspace\=', where `lsp--uri-to-path\='
reaches for the workspace\='s client to look up a `uri->path\=' function.
A workspace built without one therefore resolves no URI at all -- and
because `lsp-ltex-plus--buffer-for-uri\=' wraps that lookup in
`ignore-errors\=', the failure shows up only as every document being
answered from the wrong buffer.  So the fixture carries the real
registered client, exactly as a live session would."
  (make-lsp--workspace
   :root root
   :client (gethash 'ltex-ls-plus lsp-clients)))

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
Loading the package ran `lsp-ltex-plus--setup', and any earlier test may
have written to the mirrors; both are cleared here so that a result can
only come from what the test itself put there.  The four global files are
repointed at a fresh temporary directory, so a test that writes one never
sees another test's leftovers — nor the developer's real dictionary,
which the sandbox already rules out."
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
