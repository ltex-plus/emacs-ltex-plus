;;; ltex-plus-synthetic-test.el --- File-less and comint buffers -*- lexical-binding: t; -*-

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:

;; `lsp-mode' is built around buffers that visit a file.  Two kinds of
;; buffer this package checks do not: `*scratch*' and friends, and the
;; input region of a comint buffer.  Both are given a synthetic `file://'
;; URI and an `lsp--virtual-buffer' plist standing in for the buffer's
;; identity; the difference between them is the plist.
;;
;; The file-less plist is a whole-buffer pass-through and must carry every
;; key lsp-mode reaches for, because once `lsp--virtual-buffer' is non-nil
;; `lsp-current-buffer' returns the *plist* and a missing key makes
;; lsp-mode quietly filter the buffer out of the workspace -- no error,
;; just a document that is never opened.  The comint plist adds the
;; region-mapping keys the file-less one deliberately omits.

;;; Code:

(require 'ltex-plus-test-helper)
(require 'comint)

(defmacro ltex-plus-synthetic-test--with-buffer (&rest body)
  "Run BODY in a fresh file-less buffer bound to `buffer', then kill it."
  (declare (indent 0) (debug t))
  `(let ((buffer (generate-new-buffer " *ltex-plus-synthetic-test*")))
     (unwind-protect
         (with-current-buffer buffer ,@body)
       (kill-buffer buffer))))

;;;; -- Synthetic identities ---------------------------------------------------

(ert-deftest ltex-plus-synthetic-test-uris-are-unique ()
  "Every file-less buffer gets a document of its own.
The buffer name is deliberately not used: it renames, it uniquifies
\(\"foo<2>\"\), and it collides."
  (let ((first (lsp-ltex-plus--make-fileless-uri))
        (second (lsp-ltex-plus--make-fileless-uri)))
    (should-not (equal first second))
    (should (string-prefix-p "file://" first))
    (should (string-match-p (format "lsp-ltex-plus-scratch-%d-" (emacs-pid))
                            first))))

(ert-deftest ltex-plus-synthetic-test-uri-lives-under-the-temp-directory ()
  "The synthetic path sits in `temporary-file-directory'.
Nothing is ever read or written there -- the workspace root only has to
exist -- so no directory of our own is created, and in particular it is
not put under the settings directory, which holds durable data."
  (should (string-prefix-p
           (expand-file-name (file-name-as-directory temporary-file-directory))
           (lsp--uri-to-path (lsp-ltex-plus--make-fileless-uri)))))

(ert-deftest ltex-plus-synthetic-test-uri-is-assigned-once ()
  "A buffer keeps the URI it was given for its whole life."
  (ltex-plus-synthetic-test--with-buffer
    (lsp-ltex-plus--setup-fileless-buffer)
    (let ((uri lsp-ltex-plus--fileless-uri))
      (lsp-ltex-plus--setup-fileless-buffer)
      (should (equal lsp-ltex-plus--fileless-uri uri))
      (should (equal lsp-buffer-uri uri)))))

;;;; -- The file-less virtual buffer -------------------------------------------

(ert-deftest ltex-plus-synthetic-test-fileless-plist-is-complete ()
  "The pass-through plist carries every key lsp-mode reaches for.
A partial plist is the failure mode worth guarding: lsp-mode filters the
buffer out of the workspace, never sends `didOpen', and the only symptom
is the server logging \"Could not find document with URI\"."
  (ltex-plus-synthetic-test--with-buffer
    (let ((plist (lsp-ltex-plus--setup-fileless-buffer)))
      (dolist (key '(:buffer :with-current-buffer :buffer-live? :buffer-uri
                     :buffer-file-name :major-mode :buffer-name :in-range
                     :goto-buffer :workspaces))
        (should (plist-member plist key)))
      (should (eq (plist-get plist :buffer) buffer))
      (should (funcall (plist-get plist :buffer-live?) plist))
      (should (equal (funcall (plist-get plist :buffer-name) plist)
                     (buffer-name buffer))))))

(ert-deftest ltex-plus-synthetic-test-fileless-omits-region-mapping ()
  "The whole-buffer path maps positions straight through.
`lsp-virtual-buffer-call' returns nil for a key the plist does not
carry, which is exactly the identity mapping a whole buffer wants.  The
comint path is where these keys belong."
  (ltex-plus-synthetic-test--with-buffer
    (let ((plist (lsp-ltex-plus--setup-fileless-buffer)))
      (dolist (key '(:real->virtual-line :real->virtual-char
                     :line/character->point :cur-position :buffer-string))
        (should-not (plist-member plist key))))))

(ert-deftest ltex-plus-synthetic-test-fileless-key-matches-diagnostics ()
  "`:buffer-file-name' equals the key `lsp--on-diagnostics' stores under.
`lsp--get-buffer-diagnostics' prefers the virtual buffer's
`:buffer-file-name', so a different spelling of the same path means the
overlays are filed where nothing looks for them."
  (ltex-plus-synthetic-test--with-buffer
    (let ((plist (lsp-ltex-plus--setup-fileless-buffer)))
      (should (equal (plist-get plist :buffer-file-name)
                     (lsp--fix-path-casing
                      (lsp--uri-to-path lsp-ltex-plus--fileless-uri)))))))

(ert-deftest ltex-plus-synthetic-test-fileless-never-touches-disk ()
  "`didOpen' must not try to create the synthetic file."
  (ltex-plus-synthetic-test--with-buffer
    (lsp-ltex-plus--setup-fileless-buffer)
    (should-not lsp-auto-touch-files)
    (should-not (file-exists-p (lsp--uri-to-path lsp-ltex-plus--fileless-uri)))))

(ert-deftest ltex-plus-synthetic-test-buffer-stays-fileless ()
  "Setting up a synthetic identity does not give the buffer a file name.
`buffer-file-name' is bound to the synthetic path for the duration of
the workspace handshake only -- `lsp--start-workspace' calls
`file-remote-p' on it, which signals on nil -- and `didOpen' fires
afterwards, outside that binding, from `lsp-buffer-uri'."
  (ltex-plus-synthetic-test--with-buffer
    (lsp-ltex-plus--setup-fileless-buffer)
    (should-not (buffer-file-name))))

;;;; -- The comint input region ------------------------------------------------

(defmacro ltex-plus-synthetic-test--with-comint (prompt input &rest body)
  "Run BODY in a comint buffer showing PROMPT and INPUT as pending input.
The buffer holds a line of earlier output, then PROMPT and INPUT on one
line, with the process mark between them -- the shape every comint
buffer has while the user is typing.  `plist' is bound to the virtual
buffer, `input-start' to the process mark's position."
  (declare (indent 2) (debug t))
  `(let* ((buffer (generate-new-buffer " *ltex-plus-comint-test*"))
          ;; A process with no program: Emacs allocates the pty and the
          ;; process mark, and runs nothing.  No external command needed.
          (process (start-process "ltex-plus-test" buffer nil)))
     (unwind-protect
         (with-current-buffer buffer
           (comint-mode)
           (insert "earlier output\n" ,prompt)
           (set-marker (process-mark process) (point))
           (insert ,input)
           (let ((input-start (marker-position (process-mark process)))
                 (plist (lsp-ltex-plus--setup-comint-buffer)))
             (ignore input-start plist)
             ,@body))
       (delete-process process)
       (kill-buffer buffer))))

(ert-deftest ltex-plus-synthetic-test-comint-region-starts-at-the-mark ()
  "The input region begins at the process mark."
  (ltex-plus-synthetic-test--with-comint "shell> " "he go to school"
    (should (= (lsp-ltex-plus--comint-input-start) input-start))
    (should (= (lsp-ltex-plus--comint-input-prompt-width) (length "shell> ")))))

(ert-deftest ltex-plus-synthetic-test-comint-region-has-no-process ()
  "With no live process the region falls back rather than signalling.
A dead REPL should leave the buffer inert, not raise on every change."
  (let ((buffer (generate-new-buffer " *ltex-plus-comint-test*")))
    (unwind-protect
        (with-current-buffer buffer
          (comint-mode)
          (insert "output\n")
          (should (= (lsp-ltex-plus--comint-input-start) (point-max))))
      (kill-buffer buffer))))

(ert-deftest ltex-plus-synthetic-test-comint-sends-only-the-input ()
  "The document is the input region, left-padded by the prompt width.
The prompt is not editable and must not be checked, but flycheck
positions diagnostics by column from the line beginning, so the pad is
what makes the reported columns land on the real text."
  (ltex-plus-synthetic-test--with-comint "shell> " "he go to school"
    (should (equal (funcall (plist-get plist :buffer-string))
                   "       he go to school"))
    (should-not (string-match-p "earlier output"
                                (funcall (plist-get plist :buffer-string))))))

(ert-deftest ltex-plus-synthetic-test-comint-output-is-out-of-range ()
  "An edit above the input region fires no check.
`lsp-virtual-buffer-on-change' only emits a `didChange' when the change
falls inside `:in-range', which is what keeps the program's output from
being checked at all."
  (ltex-plus-synthetic-test--with-comint "shell> " "he go to school"
    (let ((in-range (plist-get plist :in-range)))
      (should (funcall in-range input-start))
      (should (funcall in-range (point-max)))
      (should-not (funcall in-range (point-min))))))

(ert-deftest ltex-plus-synthetic-test-comint-busy-empties-the-region ()
  "While the program is streaming there is nothing to check.
This is load-bearing, not an optimisation: shell-maker inserts output at
`point-max' and only afterwards advances the process mark, so during the
insert the output sits inside the region and would be checked, with its
diagnostics accumulating.  Returning \"\" also clears whatever was
published before."
  (ltex-plus-synthetic-test--with-comint "shell> " "he go to school"
    (defvar shell-maker--busy)
    (let ((shell-maker--busy t))
      (should (equal (funcall (plist-get plist :buffer-string)) ""))
      (should-not (funcall (plist-get plist :in-range) (point-max))))
    (let ((shell-maker--busy nil))
      (should-not (equal (funcall (plist-get plist :buffer-string)) "")))))

(ert-deftest ltex-plus-synthetic-test-comint-plain-buffers-are-ready ()
  "A plain comint buffer, where `shell-maker--busy' is unbound, is ready."
  (should (lsp-ltex-plus--comint-input-ready-p)))

(ert-deftest ltex-plus-synthetic-test-comint-positions-round-trip ()
  "A position maps to the document and back to the same point.
The first line's columns include the prompt pad, so both directions have
to agree about where the line begins -- the true beginning, crossing the
prompt field, not the input start."
  (ltex-plus-synthetic-test--with-comint "shell> " "he go to school"
    (let ((to-point (plist-get plist :line/character->point))
          (position (plist-get plist :cur-position)))
      (dolist (offset '(0 3 6))
        (goto-char (+ input-start offset))
        (let* ((here (funcall position))
               (line (plist-get here :line))
               (character (plist-get here :character)))
          (should (= line 0))
          (should (= character (+ (length "shell> ") offset)))
          (should (= (funcall to-point line character) (point))))))))

(ert-deftest ltex-plus-synthetic-test-comint-region-follows-the-mark ()
  "The region tracks itself as output scrolls it down the buffer.
The plist's lambdas read the process mark live, so nothing has to be
remapped when a line of output arrives."
  (ltex-plus-synthetic-test--with-comint "shell> " "he go to school"
    (let ((before (funcall (plist-get plist :buffer-string))))
      (save-excursion
        (goto-char (point-min))
        (insert "another line of output\n"))
      (should (equal (funcall (plist-get plist :buffer-string)) before)))))

(ert-deftest ltex-plus-synthetic-test-comint-teardown-is-idempotent ()
  "Tearing down twice is harmless, and the submit hook goes away."
  (ltex-plus-synthetic-test--with-comint "shell> " "input"
    (setq lsp-ltex-plus--comint-active t)
    (add-hook 'comint-input-filter-functions
              #'lsp-ltex-plus--comint-on-submit nil t)
    (lsp-ltex-plus--comint-teardown)
    (should-not lsp-ltex-plus--comint-active)
    (should-not (memq #'lsp-ltex-plus--comint-on-submit
                      comint-input-filter-functions))
    (lsp-ltex-plus--comint-teardown)))

;;;; -- Routing a WorkspaceEdit back to a synthetic buffer ---------------------

(ert-deftest ltex-plus-synthetic-test-edit-routing-is-installed ()
  "Setting up either kind of synthetic buffer installs the routing advice."
  (ltex-plus-synthetic-test--with-buffer
    (lsp-ltex-plus--setup-fileless-buffer)
    (should (advice-member-p #'lsp-ltex-plus--apply-workspace-edit-advice
                             'lsp--apply-workspace-edit))))

(ert-deftest ltex-plus-synthetic-test-finds-its-own-buffer-only ()
  "Only a buffer this package set up is claimed by its URI."
  (ltex-plus-synthetic-test--with-buffer
    (lsp-ltex-plus--setup-fileless-buffer)
    (should (eq (plist-get (lsp-ltex-plus--synthetic-buffer-for-uri
                            lsp-ltex-plus--fileless-uri)
                           :buffer)
                buffer))
    (should-not (lsp-ltex-plus--synthetic-buffer-for-uri
                 "file:///tmp/not-ours.txt"))
    (should-not (lsp-ltex-plus--synthetic-buffer-for-uri nil))))

(ert-deftest ltex-plus-synthetic-test-edit-target-uri-is-read-from-both-shapes ()
  "The target URI is found in `documentChanges' and in `changes' alike.
LTEX+ sends the former; the latter is the simpler shape the LSP spec
also allows."
  (let ((uri "file:///tmp/lsp-ltex-plus-scratch-1-1.txt"))
    (should (equal (lsp-ltex-plus--workspace-edit-target-uri
                    (ltex-plus-test-obj
                     :documentChanges
                     (vector (ltex-plus-test-obj
                              :textDocument (ltex-plus-test-obj :uri uri
                                                                :version 0)
                              :edits []))))
                   uri))
    (should (equal (lsp-ltex-plus--workspace-edit-target-uri
                    (ltex-plus-test-obj
                     :changes (let ((table (make-hash-table :test #'equal)))
                                (puthash uri [] table)
                                table)))
                   uri))
    (should-not (lsp-ltex-plus--workspace-edit-target-uri
                 (ltex-plus-test-obj :documentChanges [])))))

(defun ltex-plus-synthetic-test--edit (uri line start end replacement)
  "Return a WorkspaceEdit replacing columns START..END of LINE in URI."
  (ltex-plus-test-obj
   :documentChanges
   (vector (ltex-plus-test-obj
            :textDocument (ltex-plus-test-obj :uri uri :version 0)
            :edits (vector
                    (ltex-plus-test-obj
                     :range (ltex-plus-test-obj
                             :start (ltex-plus-test-obj :line line
                                                        :character start)
                             :end (ltex-plus-test-obj :line line
                                                      :character end))
                     :newText replacement))))))

(ert-deftest ltex-plus-synthetic-test-edit-reaches-the-real-buffer ()
  "An accepted suggestion is applied in the synthetic buffer itself.
lsp-mode would resolve the URI with `find-file-noselect' and edit a
phantom temp-file buffer instead; the fix affects `*scratch*' as much as
comint input."
  (ltex-plus-synthetic-test--with-buffer
    (insert "I beleive so\n")
    (lsp-ltex-plus--setup-fileless-buffer)
    (lsp-ltex-plus--apply-workspace-edit-advice
     (lambda (&rest _) (error "The edit was not routed to the buffer"))
     (ltex-plus-synthetic-test--edit lsp-ltex-plus--fileless-uri 0 2 9 "believe")
     'test)
    (should (equal (buffer-string) "I believe so\n"))))

(ert-deftest ltex-plus-synthetic-test-foreign-edits-pass-straight-through ()
  "An edit for any other buffer is handed to the original untouched.
The advice is global, so every WorkspaceEdit in the session goes through
it; anything but a strict pass-through here corrupts other servers'
refactorings."
  (ltex-plus-synthetic-test--with-buffer
    (lsp-ltex-plus--setup-fileless-buffer)
    (let* ((edit (ltex-plus-synthetic-test--edit
                  "file:///some/real/file.txt" 0 0 1 "x"))
           (seen nil)
           (result (lsp-ltex-plus--apply-workspace-edit-advice
                    (lambda (given operation)
                      (setq seen (list given operation))
                      'original-return-value)
                    edit 'test)))
      (should (equal result 'original-return-value))
      (should (eq (nth 0 seen) edit))
      (should (eq (nth 1 seen) 'test)))))

(provide 'ltex-plus-synthetic-test)
;;; ltex-plus-synthetic-test.el ends here
