;;; ltex-plus-live-helper.el --- Fixture for tests against a real server -*- lexical-binding: t; -*-

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:

;; Everything the unit suite deliberately cannot reach needs a running
;; `ltex-ls-plus': the mode's startup and teardown paths, the
;; configuration pull loop as the server actually drives it, and whether
;; a word this package accepts is a word the server stops flagging.
;;
;; Cost is not the obstacle it looks like.  Starting the JVM and shaking
;; hands takes about five seconds; every document after that is tens of
;; milliseconds, because `lsp-keep-workspace-alive' holds the server up
;; between tests and `:multi-root' lets new roots join the workspace
;; already running.  So the whole live file costs roughly one server
;; start, and there is no reason to reach for a daemon to amortise it.
;;
;; Two rules keep these tests from becoming the flaky ones nobody trusts:
;;
;;   * Wait on a predicate, never on a duration.  `ltex-plus-live-until'
;;     pumps `accept-process-output' to a deadline and reports how long
;;     it waited, so a test that is drifting towards its timeout says so
;;     before it starts failing on a slower machine.
;;
;;   * Never treat "no diagnostics yet" as an answer.  Nothing
;;     distinguishes a document the server has not checked from one it
;;     found nothing wrong with, so any test asserting an absence waits
;;     for a *publish* first -- see `ltex-plus-live-after-publish'.

;;; Code:

(require 'ltex-plus-test-helper)

(defconst ltex-plus-live-timeout 60
  "Seconds to wait for the server.  Generous: it starts a JVM.")

(defconst ltex-plus-live-server-floor "18.7"
  "Oldest `ltex-ls-plus' these tests are written against.
The README calls 18.7 the recommended version; the Emacs-Lisp parser and
the `serverInfo' the tests read both arrived around it.  Nothing in the
package enforces a floor -- an older server simply lacks features, and
fails as a missing diagnostic rather than as a message -- so the suite
declines to run rather than reporting that absence as a bug in the
client.")

(defun ltex-plus-live-server-version ()
  "Return the version `ltex-ls-plus' reports, or nil.
Read from the binary itself rather than through `lsp-mode'.  The
accessors the package uses for this come from an `lsp-mode' pull request
that is approved but not merged, so on a stock `lsp-mode' there is no
version to be had from the workspace at all -- and a check that quietly
does nothing there would be worse than none."
  (when-let* ((executable (executable-find lsp-ltex-plus-ls-plus-executable))
              (output (with-output-to-string
                        (with-current-buffer standard-output
                          (ignore-errors
                            (call-process executable nil t nil "--version"))))))
    ;; The binary answers with JSON: {"ltex-ls": "18.7.1-alpha.32+...", ...}
    (when (string-match "\"ltex-ls\"[[:space:]]*:[[:space:]]*\"\\([^\"]+\\)\"" output)
      (match-string 1 output))))

(defun ltex-plus-live-version-at-least-p (version floor)
  "Non-nil when VERSION is FLOOR or newer.
Only the leading numeric part is compared: a real version looks like
\"18.7.1-alpha.32+2026-08-26.g7977ac67\", and `version-to-list' will not
read the build metadata."
  (and version
       (string-match "\\`\\([0-9]+\\(?:\\.[0-9]+\\)*\\)" version)
       (not (version< (match-string 1 version) floor))))

(defun ltex-plus-live-p ()
  "Non-nil when the live tests should run.
Three things are required, so that a checkout on a machine without a
current server skips rather than failing in ways that look like the
client's fault: an explicit opt-in, a server on PATH, and one new enough
to behave as these tests expect."
  (and (member (getenv "LTEX_PLUS_LIVE") '("1" "t" "yes"))
       (executable-find lsp-ltex-plus-ls-plus-executable)
       (ltex-plus-live-version-at-least-p (ltex-plus-live-server-version)
                                          ltex-plus-live-server-floor)
       t))

(defun ltex-plus-live-reason ()
  "Say why the live tests are being skipped."
  (cond ((not (member (getenv "LTEX_PLUS_LIVE") '("1" "t" "yes")))
         "live tests are opt-in: set LTEX_PLUS_LIVE=1 (or run `make test-live')")
        ((not (executable-find lsp-ltex-plus-ls-plus-executable))
         (format "%s is not on PATH" lsp-ltex-plus-ls-plus-executable))
        (t (format "ltex-ls-plus %s is older than %s, the version these tests assume"
                   (or (ltex-plus-live-server-version) "of an unreadable version")
                   ltex-plus-live-server-floor))))

;;;; -- A batch Emacs that lsp-mode will talk to --------------------------------

(defun ltex-plus-live-configure ()
  "Set the `lsp-mode' options a batch session needs.
Each of these is a question lsp-mode would otherwise ask: with no stdin
to answer from, an unset one hangs the run rather than failing it."
  (setq lsp-auto-guess-root t          ; do not ask which project this is
        lsp-restart 'ignore            ; do not ask whether to restart
        lsp-warn-no-matched-clients nil
        lsp-enable-file-watchers nil   ; nothing here is edited from outside
        lsp-diagnostics-provider :none ; read `lsp-diagnostics', not flycheck
        lsp-idle-delay 0.1
        lsp-response-timeout 30
        ;; Send `didChange' as the edit happens.  lsp-mode otherwise
        ;; defers it to a `run-with-idle-timer', and a batch Emacs never
        ;; becomes idle: idle time is measured from the last input event,
        ;; and there are none -- `accept-process-output' does not count.
        ;; The edit would simply never reach the server, and the test
        ;; would sit out its full timeout looking like a slow server.
        lsp-debounce-full-sync-notifications nil))

;;;; -- Waiting -----------------------------------------------------------------

(defun ltex-plus-live-until (predicate &optional label seconds)
  "Wait for PREDICATE to return non-nil, and return what it returned.
Pumps `accept-process-output' so process filters and timers run, which
in batch they otherwise do not.  Fails the test on timeout, naming LABEL,
rather than letting a later assertion fail for a reason that looks
unrelated."
  (let* ((limit (or seconds ltex-plus-live-timeout))
         (started (float-time))
         (deadline (+ started limit))
         value)
    (while (and (not (setq value (funcall predicate)))
                (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (unless value
      (ert-fail (format "timed out after %.1fs waiting for %s"
                        limit (or label "the server"))))
    value))

(defvar ltex-plus-live--publishes (make-hash-table :test #'equal)
  "Document path -> how many times the server has published for it.
Counted per document, not in total: several documents share one
workspace, so a global counter is satisfied by somebody else's check and
a test waiting on its own would sail past with stale diagnostics still
in hand.  That is not a hypothetical -- it is what the first run of this
file did.")

(defun ltex-plus-live--document-key (&optional buffer)
  "Return the key diagnostics for BUFFER are filed under."
  (with-current-buffer (or buffer (current-buffer))
    (lsp--fix-path-casing
     (or (buffer-file-name)
         (and lsp-ltex-plus--fileless-uri
              (lsp--uri-to-path lsp-ltex-plus--fileless-uri))))))

(defun ltex-plus-live--count-publish (_workspace params)
  "Record that the server published diagnostics, from PARAMS' URI."
  (when-let* ((uri (lsp:publish-diagnostics-params-uri params))
              (key (lsp--fix-path-casing (lsp--uri-to-path uri))))
    (puthash key (1+ (gethash key ltex-plus-live--publishes 0))
             ltex-plus-live--publishes)))

(advice-add 'lsp--on-diagnostics :after #'ltex-plus-live--count-publish)

(defun ltex-plus-live-after-publish (thunk &optional label buffer)
  "Call THUNK, then wait for the server to publish for BUFFER again.
The signal a test asserting an *absence* needs: an empty diagnostic list
means nothing at all until the server has spoken about this document
since the change.  BUFFER defaults to the current one; when it has no
document key yet -- the very first activation -- any publish for it will
do, since there is nothing stale to be confused with."
  (let* ((buffer (or buffer (current-buffer)))
         (key (ltex-plus-live--document-key buffer))
         (before (if key (gethash key ltex-plus-live--publishes 0) 0)))
    (funcall thunk)
    (ltex-plus-live-until
     (lambda ()
       (let ((key (or key (ltex-plus-live--document-key buffer))))
         (and key (> (gethash key ltex-plus-live--publishes 0) before))))
     (or label "the server to publish again"))))

;;;; -- Reading what the server said --------------------------------------------

(defun ltex-plus-live-diagnostics (&optional buffer)
  "Return the diagnostics currently published for BUFFER, as a list."
  (with-current-buffer (or buffer (current-buffer))
    (append (gethash (lsp--fix-path-casing
                      (or (buffer-file-name)
                          (lsp--uri-to-path lsp-ltex-plus--fileless-uri)))
                     (lsp-diagnostics t))
            nil)))

(defun ltex-plus-live-messages (&optional buffer)
  "Return the diagnostic messages for BUFFER, as a list of strings."
  (mapcar #'lsp:diagnostic-message (ltex-plus-live-diagnostics buffer)))

(defun ltex-plus-live-flagged-p (word &optional buffer)
  "Non-nil when some diagnostic in BUFFER is about WORD.
LTEX+ reports an unknown word by quoting it in the message."
  (seq-some (lambda (message) (string-match-p (regexp-quote word) message))
            (ltex-plus-live-messages buffer)))

;;;; -- The shared workspace ----------------------------------------------------

(defvar ltex-plus-live--root nil
  "The one project root every live document in this process lives under.")

(defvar ltex-plus-live--buffers nil
  "Buffers opened by `ltex-plus-live-document', killed on exit.")

(defun ltex-plus-live-root ()
  "Return this process's project root, creating it on first use."
  (or ltex-plus-live--root
      (setq ltex-plus-live--root
            (file-name-as-directory (make-temp-file "ltex-plus-live-" t)))))

(defun ltex-plus-live-write (name contents &optional root)
  "Write CONTENTS to NAME under ROOT (default the shared root); return its path."
  (let ((path (expand-file-name name (or root (ltex-plus-live-root)))))
    (make-directory (file-name-directory path) t)
    (with-temp-file path (insert contents))
    path))

(defun ltex-plus-live-open (path)
  "Visit PATH, start the client, and wait until the server has checked it.
Returns the buffer.  Waits for the workspace to reach `initialized' and
then for one publish, so a test can read diagnostics immediately and an
empty list means the server found nothing rather than that it has not
looked yet."
  (let ((buffer (ltex-plus-test-visit path)))
    (push buffer ltex-plus-live--buffers)
    (with-current-buffer buffer
      (ltex-plus-live-after-publish
       (lambda () (lsp-ltex-plus-mode 1))
       (format "the first check of %s" (file-name-nondirectory path)))
      (ltex-plus-live-until
       (lambda () (seq-find (lambda (workspace)
                              (eq 'ltex-ls-plus (lsp--workspace-server-id workspace)))
                            lsp--buffer-workspaces))
       "the ltex-ls-plus workspace"))
    buffer))

(defun ltex-plus-live-workspace ()
  "Return the running ltex-ls-plus workspace, or nil."
  (seq-find (lambda (workspace)
              (eq 'ltex-ls-plus (lsp--workspace-server-id workspace)))
            (lsp--session-workspaces (lsp-session))))

(defun ltex-plus-live-teardown ()
  "Shut the server down and remove everything this process created."
  (dolist (buffer ltex-plus-live--buffers)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer (set-buffer-modified-p nil))
      (kill-buffer buffer)))
  (setq ltex-plus-live--buffers nil)
  (when-let* ((workspace (ltex-plus-live-workspace)))
    (ignore-errors (lsp-workspace-shutdown workspace)))
  (when (and ltex-plus-live--root (file-directory-p ltex-plus-live--root))
    (delete-directory ltex-plus-live--root t))
  (setq ltex-plus-live--root nil))

(provide 'ltex-plus-live-helper)
;;; ltex-plus-live-helper.el ends here
