;;; lsp-ltex-plus.el --- Grammar and spell checking for LaTeX, Markdown, Org and more -*- lexical-binding: t; -*-

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Assisted-by: Claude:claude-opus-4-7
;; Version: 1.0.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: lsp, grammar, spelling, convenience
;; URL: https://github.com/ltex-plus/emacs-ltex-plus

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:
;;
;; `lsp-ltex-plus' is an Emacs client for LTeX+, a LanguageTool-based
;; grammar, spell, and style checker.  It brings professional-grade writing
;; feedback into Emacs for:
;;
;;   * Markup and writing languages — LaTeX, Markdown, Org, RestructuredText,
;;     HTML, BibTeX, AsciiDoc, Typst, Quarto, Magit commit messages, plain
;;     text, and many others (checked by default).
;;   * Comments and string literals in 30+ programming languages — Python,
;;     C/C++, Rust, Java, JavaScript/TypeScript, Go, Ruby, … (opt-in via
;;     `lsp-ltex-plus-check-programming-languages').
;;
;; Highlights:
;;
;;   * Self-contained -- speaks the Language Server Protocol over the
;;     `jsonrpc' library bundled with Emacs and reports through flymake,
;;     so it runs beside any other language server without configuration.
;;   * Offline by default — the local `ltex-ls-plus' binary checks documents
;;     entirely on your machine, no network involved.  An optional remote
;;     LanguageTool server (with optional LanguageTool Premium credentials)
;;     is supported for users who want it.
;;   * Multilingual — every external setting is keyed by language code
;;     (`:en-US', `:de-DE', `:fr', …), so dictionaries, disabled rules,
;;     enabled rules, and hidden false-positives are tracked per language.
;;   * Persistent state — words you "add to dictionary", rules you disable,
;;     and false positives you hide are saved as plist files under
;;     `user-emacs-directory' and survive Emacs restarts.  User-level
;;     `:custom' entries seed the defaults and remain pristine (never
;;     mutated by the package at runtime).
;;   * Lazy loading — split into a tiny bootstrap file loaded at Emacs
;;     startup and a full client loaded only on first use, so installing
;;     the package costs essentially no startup time.
;;   * Simple setup — one call to `lsp-ltex-plus-enable-for-modes' from
;;     the `:init' block of `use-package' activates the client across
;;     every supported major mode.  Narrow the set with the `:restrict-to'
;;     or `:exclude' keywords, or add your own modes with `:extend-to',
;;     without editing `lsp-ltex-plus-major-modes'.  All settings are
;;     defcustoms under the `lsp-ltex-plus-' prefix, configurable via
;;     `:custom' or `M-x customize-group RET lsp-ltex-plus RET'.
;;
;; Minimal setup with `use-package':
;;
;;   (use-package lsp-ltex-plus
;;     :init (lsp-ltex-plus-enable-for-modes))
;;
;; See the README at URL `https://github.com/ltex-plus/emacs-ltex-plus' for
;; full configuration, multi-language setup, performance tuning, and a
;; comparison with the older `lsp-ltex' package.
;;
;; External dependencies:
;;
;;   - `ltex-ls-plus' binary on `exec-path'.
;;   - Java runtime — platform-specific `ltex-ls-plus' releases include a
;;     bundled JRE; otherwise Java 21 or later must be installed.
;;   - Optional: LanguageTool.org account for premium rules.

;;; Code:

(require 'seq)
(require 'cl-lib)
(require 'lsp-ltex-plus-bootstrap)
(require 'lsp-ltex-plus-settings)
(require 'lsp-ltex-plus-conn)
(require 'lsp-ltex-plus-diag)
(require 'lsp-ltex-plus-flycheck)
(require 'lsp-ltex-plus-actions)
(require 'lsp-ltex-plus-comint)

;;;; -- Setup and reload -------------------------------------------------------

(defun lsp-ltex-plus--setup ()
  "Load the persisted lists and apply the debug defaults.
Run once when the package loads and again by `lsp-ltex-plus-reload-settings',
so it must stay idempotent: nothing here accumulates."
  (unless lsp-ltex-plus--start-time
    (setq lsp-ltex-plus--start-time (current-time)))
  (lsp-ltex-plus--log "Loading settings...")
  ;; TODO(2027-05): Remove this migration block (see
  ;; `lsp-ltex-plus--migrate-extensionless-file').
  (dolist (pair `((,lsp-ltex-plus-dictionary-file
                   . ,(expand-file-name "lsp-ltex-plus/stored-dictionary.eld"
                                        user-emacs-directory))
                  (,lsp-ltex-plus-enabled-rules-file
                   . ,(expand-file-name "lsp-ltex-plus/enabled-rules.eld"
                                        user-emacs-directory))
                  (,lsp-ltex-plus-disabled-rules-file
                   . ,(expand-file-name "lsp-ltex-plus/disabled-rules.eld"
                                        user-emacs-directory))
                  (,lsp-ltex-plus-hidden-false-positives-file
                   . ,(expand-file-name "lsp-ltex-plus/hidden-false-positives.eld"
                                        user-emacs-directory))))
    (lsp-ltex-plus--migrate-extensionless-file (car pair) (cdr pair)))
  (lsp-ltex-plus--load-external-settings)
  ;; Under debug, ask the server for its own trace of the exchange too.
  ;; "messages" rather than "verbose": the jsonrpc events buffer already
  ;; holds every payload, so the verbose trace would double it.
  (when (and lsp-ltex-plus-debug (string= lsp-ltex-plus-trace-server "off"))
    (setq lsp-ltex-plus-trace-server "messages"))
  (lsp-ltex-plus--log "Settings loaded."))

;;;###autoload
(defun lsp-ltex-plus-reload-settings ()
  "Apply changes to any `lsp-ltex-plus-*\=' setting, without restarting Emacs.

Everything the client reads is refreshed in one go:

  1. The four word-list files under the `lsp-ltex-plus/\=' subdirectory of
     `user-emacs-directory\=' are re-read and their merged views rebuilt,
     and the cache of project settings files is dropped (see the
     `lsp-ltex-plus-project-*-file\=' settings).
  2. The running server is told the configuration changed, so it fetches
     its settings again and the change takes effect on the next check
     with no server restart.

Use it after changing any `lsp-ltex-plus-*\=' setting in a running
session, or after hand-editing one of the word-list files.  Project
files are noticed on their own when their modification time moves, so
they need this only if one was changed in a way that left the time
untouched.

What it cannot reach is a setting the server reads only when it
starts, such as the executable or the Java to run it with; those need
`lsp-ltex-plus-restart-server'.  Safe to run as often as you like."
  (interactive)
  (lsp-ltex-plus--setup)
  (if (lsp-ltex-plus--push-configuration)
      (message "[lsp-ltex-plus] Settings reloaded and pushed to the server.")
    (message "[lsp-ltex-plus] Settings reloaded; no server is running.")))

;;;; -- Key binding ------------------------------------------------------------

;; One key, for the one command a writer reaches for while typing: the
;; menu of what the server suggests.  Everything else is rare enough to be
;; called by name.  The key is a setting; changing it through Customize
;; rebinds at once.

(defvar lsp-ltex-plus-mode-map (make-sparse-keymap)
  "Keymap of `lsp-ltex-plus-mode'.
Holds `lsp-ltex-plus-actions' under `lsp-ltex-plus-actions-key'.")

(defun lsp-ltex-plus--bind-actions-key (symbol key)
  "Bind `lsp-ltex-plus-actions' to KEY in the mode map; set SYMBOL.
The `:set' function of `lsp-ltex-plus-actions-key'.  The previous key,
if any, is unbound first, so changing the setting moves the command
rather than duplicating it."
  (when (and (boundp symbol) (symbol-value symbol))
    (define-key lsp-ltex-plus-mode-map (kbd (symbol-value symbol)) nil t))
  (set-default symbol key)
  (when key
    (define-key lsp-ltex-plus-mode-map (kbd key) #'lsp-ltex-plus-actions)))

(defcustom lsp-ltex-plus-actions-key "C-c \""
  "Key that opens the menu of LTeX+ suggestions, `lsp-ltex-plus-actions'.
A key description as `kbd' reads it, bound in `lsp-ltex-plus-mode-map'.
Those who let `lsp-ltex-plus-disable-flyspell' switch flyspell off may
like flyspell's own key, which that frees.  Set to nil to bind nothing
and call the command by name."
  :type '(choice (string :tag "Key description") (const :tag "No binding" nil))
  :set #'lsp-ltex-plus--bind-actions-key
  :group 'lsp-ltex-plus)

;;;; -- Minor mode -------------------------------------------------------------

;; Activation is a few decisions and two calls.  The decisions are the
;; mode's own -- whether a programming-language buffer should be checked,
;; and registering a major mode it has not met -- and are taken before the
;; server is involved at all.  The calls attach the flymake backend and
;; open the document on the session's server, starting it if this is the
;; first buffer to ask.  There is no workspace to find or join: one
;; server serves every buffer, and a buffer is either open on it or not.

(defvar lsp-ltex-plus-mode)  ; defined below; the helpers set it when they decline
(defvar flyspell-mode)
(declare-function flyspell-mode "flyspell")

(defvar-local lsp-ltex-plus--stopped-flyspell nil
  "Non-nil when this package switched `flyspell-mode\\=' off in this buffer.
Only then does turning the mode off switch flyspell back on; a buffer
where flyspell was already off is left as it was.")

(defun lsp-ltex-plus--stop-flyspell ()
  "Switch flyspell off in the current buffer if asked to, and remember it."
  (when (and lsp-ltex-plus-disable-flyspell (bound-and-true-p flyspell-mode))
    (flyspell-mode -1)
    (setq lsp-ltex-plus--stopped-flyspell t)))

(defun lsp-ltex-plus--restore-flyspell ()
  "Switch flyspell back on in the current buffer if this package stopped it."
  (when lsp-ltex-plus--stopped-flyspell
    (setq lsp-ltex-plus--stopped-flyspell nil)
    (flyspell-mode 1)))

(defun lsp-ltex-plus--register-major-mode (interactive)
  "Add the current `major-mode' to `lsp-ltex-plus-major-modes' if it is absent.
With INTERACTIVE non-nil the language id is asked for, defaulting to
plain text; otherwise plain text is used silently.  A mode added this
way is markup, not a programming language: an unknown mode is far
likelier to be a writing context than a language."
  (unless (assq major-mode lsp-ltex-plus-major-modes)
    (let ((language-id (if interactive
                           (read-string
                            (format "Language ID for %s (RET for \"plaintext\"): "
                                    major-mode)
                            nil nil "plaintext")
                         "plaintext")))
      (push (list major-mode language-id nil) lsp-ltex-plus-major-modes))))

(defun lsp-ltex-plus--enable (interactive)
  "Turn checking on in the current buffer; the body of `lsp-ltex-plus-mode'.
INTERACTIVE says whether the user asked for it by name, which lifts the
programming-language guard and makes an unknown mode's language id a
question rather than a default.  Each way this can decline leaves the
mode variable nil, so the mode line and the dispatcher agree with what
happened."
  (let* ((entry (assq major-mode lsp-ltex-plus-major-modes))
         (programming-p (and entry (nth 2 entry))))
    (if (and programming-p
             (not lsp-ltex-plus-check-programming-languages)
             (not interactive))
        ;; Dispatcher-driven activation in a programming buffer with the
        ;; option off: the whole point is that opening such a file costs
        ;; nothing, so stop here, before anything else is looked at.
        (setq lsp-ltex-plus-mode nil)
      (lsp-ltex-plus--register-major-mode interactive)
      (lsp-ltex-plus--start-checking))))

(defun lsp-ltex-plus--start-checking ()
  "Attach flymake and open the current buffer on the server, if it can be.
The second half of `lsp-ltex-plus--enable', reached once the buffer's
major mode is known to the table."
  (cond
   ((not (lsp-ltex-plus--server-executable))
    (message (concat "[lsp-ltex-plus] Cannot find `%s'.  See the installation"
                     " instructions at https://github.com/ltex-plus/emacs-ltex-plus"
                     " or set `lsp-ltex-plus-ls-plus-executable' to the binary's path")
             lsp-ltex-plus-ls-plus-executable)
    (setq lsp-ltex-plus-mode nil))
   ((and (not buffer-file-name) (not lsp-ltex-plus-check-fileless-buffers))
    (lsp-ltex-plus--log "Not checking %s: it visits no file and the option is off"
                        (buffer-name))
    (setq lsp-ltex-plus-mode nil))
   ((and (lsp-ltex-plus--comint-buffer-p) (not lsp-ltex-plus-check-comint-input))
    (lsp-ltex-plus--log "Not checking %s: comint input and the option is off"
                        (buffer-name))
    (setq lsp-ltex-plus-mode nil))
   (t
    (lsp-ltex-plus--log "Enabling LTeX+ in %s" (buffer-name))
    (condition-case err
        (progn
          ;; A comint buffer's document is its input region, never the
          ;; output above it; set that up before the document opens.
          (when (lsp-ltex-plus--comint-buffer-p)
            (lsp-ltex-plus--comint-setup))
          (lsp-ltex-plus--flymake-attach)
          (lsp-ltex-plus--open-document)
          (lsp-ltex-plus--stop-flyspell))
      (error
       (lsp-ltex-plus--flymake-detach)
       (lsp-ltex-plus--comint-teardown)
       (lsp-ltex-plus--restore-flyspell)
       (setq lsp-ltex-plus-mode nil)
       (message "[lsp-ltex-plus] Could not start checking: %s"
                (error-message-string err)))))))

(defun lsp-ltex-plus--disable ()
  "Turn checking off in the current buffer; the body of `lsp-ltex-plus-mode'.
The document is closed on the server and the underlines are cleared.
The server itself keeps running for the other buffers, and for this one
should the mode come back; `lsp-ltex-plus-shutdown-server' stops it."
  (lsp-ltex-plus--log "Disabling LTeX+ in %s" (buffer-name))
  (lsp-ltex-plus--close-document)
  (lsp-ltex-plus--flymake-detach)
  (lsp-ltex-plus--comint-teardown)
  (lsp-ltex-plus--restore-flyspell))

;; A major-mode change discards the buffer's local variables, the flymake
;; backend and its report function among them; clearing the underlines
;; first is the only chance to do so.
(add-hook 'lsp-ltex-plus--document-closing-functions #'lsp-ltex-plus--flymake-detach)

;;;###autoload
(define-minor-mode lsp-ltex-plus-mode
  "Grammar and spell checking of the current buffer by LTeX+.

When enabled, the buffer is opened on the session's `ltex-ls-plus'
server, started if this is the first buffer to need it, and the
server's findings are shown through flymake.  Run
`lsp-ltex-plus-mode-hook' to apply any per-buffer tweaks.

If the current major mode is not in `lsp-ltex-plus-major-modes', it is
registered automatically before the server starts.  When called
interactively the language identifier is requested from the user
\(default: \"plaintext\"); when called from a hook or from Lisp,
\"plaintext\" is used silently.

In a buffer whose major mode is marked as a programming language,
activation from the dispatcher is declined unless
`lsp-ltex-plus-check-programming-languages' is non-nil; an explicit
\\[lsp-ltex-plus-mode] always proceeds, so an on-demand check needs no
global setting first."
  :lighter " LTeX+"
  :keymap lsp-ltex-plus-mode-map
  :group 'lsp-ltex-plus
  (if lsp-ltex-plus-mode
      (lsp-ltex-plus--enable (called-interactively-p 'any))
    (lsp-ltex-plus--disable)))

;;;; -- The server as a whole --------------------------------------------------

(defun lsp-ltex-plus--checked-buffers ()
  "Return the live buffers in which `lsp-ltex-plus-mode' is on."
  (seq-filter (lambda (buffer) (buffer-local-value 'lsp-ltex-plus-mode buffer))
              (buffer-list)))

(defvar lsp-ltex-plus--restarting nil
  "Non-nil while `lsp-ltex-plus-restart-server' is stopping the old server.
Keeps the buffers from being told the server went away, since they are
about to get it back.")

(defun lsp-ltex-plus--on-server-gone (_conn)
  "Switch the mode off wherever it was on, once the server has ended.
On `lsp-ltex-plus--after-shutdown-functions'.  A buffer whose server
has gone is not being checked, and its mode line should not say it is;
turning the mode on again starts a new server."
  (unless lsp-ltex-plus--restarting
    (let ((buffers (lsp-ltex-plus--checked-buffers)))
      (dolist (buffer buffers)
        (with-current-buffer buffer
          (lsp-ltex-plus-mode -1)))
      (when buffers
        (message "[lsp-ltex-plus] ltex-ls-plus stopped; checking is off in %d buffer%s"
                 (length buffers) (if (= 1 (length buffers)) "" "s"))))))

(add-hook 'lsp-ltex-plus--after-shutdown-functions #'lsp-ltex-plus--on-server-gone)

;;;###autoload
(defun lsp-ltex-plus-shutdown-server ()
  "Stop the session's `ltex-ls-plus' server.
The mode is switched off in every buffer it was checking; turning it on
again in any buffer starts a new server."
  (interactive)
  (if (lsp-ltex-plus--live-connection)
      (lsp-ltex-plus--shutdown-connection)
    (message "[lsp-ltex-plus] No ltex-ls-plus server is running")))

;;;###autoload
(defun lsp-ltex-plus-restart-server ()
  "Stop the session's `ltex-ls-plus' server and start a new one.
Every buffer that was being checked is reopened on the new server.  Use
it after changing a setting the server reads only at start, or when the
server has got into a state a fresh one would not be in."
  (interactive)
  (let ((buffers (lsp-ltex-plus--checked-buffers)))
    (let ((lsp-ltex-plus--restarting t))
      (dolist (buffer buffers)
        (with-current-buffer buffer (lsp-ltex-plus-mode -1)))
      (lsp-ltex-plus--shutdown-connection))
    (dolist (buffer buffers)
      (with-current-buffer buffer (lsp-ltex-plus-mode 1)))
    (message "[lsp-ltex-plus] ltex-ls-plus restarted for %d buffer%s"
             (length buffers) (if (= 1 (length buffers)) "" "s"))))

;; Load the persisted lists once, at load time.  In a test run this reads
;; four files that do not exist under the sandboxed `user-emacs-directory'.
(lsp-ltex-plus--setup)

(provide 'lsp-ltex-plus)
;;; lsp-ltex-plus.el ends here
