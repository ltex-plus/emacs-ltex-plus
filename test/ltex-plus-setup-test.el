;;; ltex-plus-setup-test.el --- Registration and advice hygiene -*- lexical-binding: t; -*-

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:

;; `lsp-ltex-plus--setup' is idempotent by contract:
;; `lsp-ltex-plus-reload-settings' calls it, so a user can run it any
;; number of times in one session.
;;
;; What that rests on is every advice being added as a *named* function.
;; `advice-add' de-duplicates by comparing what is already there, and two
;; identically written lambdas are never `equal' -- so a lambda would
;; stack a fresh copy on every reload.  Doubled progress-suppression
;; advice would be invisible; doubled benchmark advice would report every
;; timing twice.  Neither would look like a bug in the reload command.
;;
;; This file turns on every gated feature so that all of the advice is
;; live, which is why it wants a process of its own -- `run-tests.sh'
;; gives each file one.

;;; Code:

(require 'ltex-plus-test-helper)

(defconst ltex-plus-setup-test--advised
  '((lsp-code-actions-at-point       . lsp-ltex-plus--expand-suggestions)
    (lsp--modeline-update-code-actions . lsp-ltex-plus--expand-modeline-args)
    (lsp-on-progress-modeline        . lsp-ltex-plus--suppress-progress)
    (lsp-notify                      . lsp-ltex-plus--benchmark-outgoing)
    (lsp--on-diagnostics             . lsp-ltex-plus--benchmark-diagnostics)
    (lsp--parser-on-message          . lsp-ltex-plus--parser-on-message-patch)
    (lsp--create-filter-function     . lsp-ltex-plus--create-filter-function-patch)
    (lsp-request-while-no-input      . lsp-ltex-plus--request-while-no-input-patch)
    (lsp--apply-workspace-edit       . lsp-ltex-plus--apply-workspace-edit-advice))
  "Every function this package advises, and the advice it adds.
Two are placed unconditionally, five are behind a `defcustom' that
defaults to off, and the last is installed the first time a synthetic
buffer is set up.")

(defun ltex-plus-setup-test--advice-count (symbol)
  "Return how many pieces of advice SYMBOL currently carries."
  (let ((count 0))
    (advice-mapc (lambda (&rest _) (setq count (1+ count))) symbol)
    count))

(defun ltex-plus-setup-test--counts ()
  "Return the advice count of every advised function, in table order."
  (mapcar (lambda (entry) (ltex-plus-setup-test--advice-count (car entry)))
          ltex-plus-setup-test--advised))

(defun ltex-plus-setup-test--enable-everything ()
  "Run setup with every gated feature switched on.
The patches are gated on `lsp-ltex-plus--maybe-upstream-fixes-present-p'
as well as on the opt-in, so they are applied here directly rather than
relying on which `lsp-mode' the developer happens to have installed."
  (setq lsp-ltex-plus-show-progress nil
        lsp-ltex-plus-show-latency t
        lsp-ltex-plus-apply-kind-first-patch t)
  (lsp-ltex-plus--setup)
  (lsp-ltex-plus--apply-lsp-mode-patch)
  (lsp-ltex-plus--install-synthetic-edit-routing))

(ert-deftest ltex-plus-setup-test-every-advice-is-installed ()
  "With every feature on, each advised function carries its advice.
If this fails the idempotence test below is measuring nothing."
  (ltex-plus-setup-test--enable-everything)
  (pcase-dolist (`(,symbol . ,advice) ltex-plus-setup-test--advised)
    (should (advice-member-p advice symbol))))

(ert-deftest ltex-plus-setup-test-rerunning-never-doubles-an-advice ()
  "Running setup again adds nothing.
`advice-add' declines advice it has already installed -- but only
because every one of them is a named function.  Replace one with an
inline lambda and this is the test that catches it."
  (ltex-plus-setup-test--enable-everything)
  (let ((before (ltex-plus-setup-test--counts)))
    (dotimes (_ 3)
      (ltex-plus-setup-test--enable-everything))
    (should (equal (ltex-plus-setup-test--counts) before))))

(ert-deftest ltex-plus-setup-test-advice-is-never-an-inline-lambda ()
  "Every advice this package installs is a symbol, not a lambda.
The property the test above depends on, asserted directly, so the reason
survives even if the counting is ever changed."
  (pcase-dolist (`(,_symbol . ,advice) ltex-plus-setup-test--advised)
    (should (symbolp advice))
    (should (fboundp advice))))

(ert-deftest ltex-plus-setup-test-the-advice-table-is-complete ()
  "Every `advice-add' in the sources appears in the table above.
The two tests before this one are only as good as that table: an advice
added to the package but not listed here is simply never checked, and
the omission looks like nothing at all.  So the sources are read and the
two sets compared."
  (let ((found nil))
    (dolist (file ltex-plus-test-package-files)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        ;; Only real call sites: prose in the docstrings writes the name
        ;; with a quote character, never as the head of a form.
        (while (re-search-forward
                "(advice-add[[:space:]]+'\\([^[:space:])]+\\)" nil t)
          (push (intern (match-string 1)) found))))
    (should found)
    (should (equal (sort (seq-uniq found) #'string<)
                   (sort (mapcar #'car ltex-plus-setup-test--advised)
                         #'string<)))))

(ert-deftest ltex-plus-setup-test-client-registration-holds-its-shape ()
  "The registered client keeps the settings the design depends on.
`:add-on?' is what makes lsp-mode start this server alongside a primary
one instead of choosing between them; `:priority -1' keeps it from ever
winning a feature contest it should lose."
  (lsp-ltex-plus--setup)
  (let ((client (gethash 'ltex-ls-plus lsp-clients)))
    (should client)
    (should (lsp--client-add-on? client))
    (should (= (lsp--client-priority client) -1))
    (should (eq (lsp--client-server-id client) 'ltex-ls-plus))))

(ert-deftest ltex-plus-setup-test-registering-again-replaces-the-client ()
  "Setup replaces the registration rather than adding to it."
  (lsp-ltex-plus--setup)
  (let ((before (hash-table-count lsp-clients)))
    (lsp-ltex-plus--setup)
    (should (= (hash-table-count lsp-clients) before))))

(ert-deftest ltex-plus-setup-test-custom-capability-is-advertised ()
  "The client opts in to the per-document configuration pulls.
Both `workspace/configuration' and
`ltex/workspaceSpecificConfiguration' are gated together on this: without
it the server skips both, checks the document once from the startup
push, and then publishes nothing further as the user types."
  (lsp-ltex-plus--setup)
  (let* ((client (gethash 'ltex-ls-plus lsp-clients))
         (options (funcall (lsp--client-initialization-options client))))
    (should (eq (plist-get (plist-get options :customCapabilities)
                           :workspaceSpecificConfiguration)
                t))))

(ert-deftest ltex-plus-setup-test-both-config-pulls-are-answered-by-us ()
  "The client answers both pulls itself, rather than through lsp-mode.
lsp-mode's generic responder ignores `scopeUri', so a session with two
projects open can answer one project's documents from the other's
buffers.  Request handlers are per client, so this affects nothing
else running alongside."
  (lsp-ltex-plus--setup)
  (let ((handlers (lsp--client-request-handlers
                   (gethash 'ltex-ls-plus lsp-clients))))
    (should (eq (gethash "workspace/configuration" handlers)
                #'lsp-ltex-plus--request-configuration))
    (should (eq (gethash "ltex/workspaceSpecificConfiguration" handlers)
                #'lsp-ltex-plus--request-workspace-specific-configuration))))

(ert-deftest ltex-plus-setup-test-every-suggestion-command-has-a-handler ()
  "The three client-side commands are handled here, not sent to the server.
`_ltex.addToDictionary' and friends never reach `workspace/executeCommand';
an unregistered one would be sent onwards and silently do nothing."
  (lsp-ltex-plus--setup)
  (let ((handlers (lsp--client-action-handlers
                   (gethash 'ltex-ls-plus lsp-clients))))
    (dolist (entry lsp-ltex-plus--setting-kinds)
      (when-let* ((command (plist-get (cdr entry) :command)))
        (should (functionp (gethash command handlers)))))))

(ert-deftest ltex-plus-setup-test-language-id-comes-from-the-mode-table ()
  "The `languageId' sent over the wire is read from the one table.
`lsp-language-id-configuration' is populated only to silence a warning;
this lambda is the single source of truth."
  (lsp-ltex-plus--setup)
  (let ((resolve (lsp--client-language-id (gethash 'ltex-ls-plus lsp-clients))))
    (with-temp-buffer
      (setq major-mode 'markdown-mode)
      (should (equal (funcall resolve (current-buffer)) "markdown")))
    (with-temp-buffer
      (setq major-mode 'LaTeX-mode)
      (should (equal (funcall resolve (current-buffer)) "latex")))))

(ert-deftest ltex-plus-setup-test-activation-follows-the-minor-mode ()
  "The client starts only where `lsp-ltex-plus-mode' is on.
This is also what stops lsp-mode restarting the server after the user
has switched the mode off."
  (lsp-ltex-plus--setup)
  (let ((activate (lsp--client-activation-fn (gethash 'ltex-ls-plus lsp-clients))))
    (with-temp-buffer
      (setq-local lsp-ltex-plus-mode nil)
      (should-not (funcall activate (buffer-name) major-mode))
      (setq-local lsp-ltex-plus-mode t)
      (should (funcall activate (buffer-name) major-mode)))))

(provide 'ltex-plus-setup-test)
;;; ltex-plus-setup-test.el ends here
