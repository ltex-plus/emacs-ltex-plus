;;; ltex-plus-live-helper.el --- Fixture for tests against a real server -*- lexical-binding: t; -*-

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:

;; The fake server in `ltex-plus-fake-server.el' proves the client keeps
;; its side of the protocol.  What it cannot prove is that the real
;; `ltex-ls-plus' behaves as the fake was written to: that the custom
;; capability really makes it pull configuration before every check, that
;; a word this package accepts is a word the server stops flagging, that
;; its `serverInfo' says what the binary says.  That needs a JVM.
;;
;; Cost is not the obstacle it looks like.  Starting the server and
;; shaking hands takes about five seconds; every document after that is
;; tens of milliseconds, because one connection serves every buffer in
;; the session and it stays up between tests.  So the whole live file
;; costs roughly one server start.
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

;; The shared helper points the executable setting at a name that does not
;; exist, so that no offline test can start a real server by accident.
;; This file is the one place that means to.
(setq lsp-ltex-plus-ls-plus-executable
      (eval (car (get 'lsp-ltex-plus-ls-plus-executable 'standard-value))))

(defconst ltex-plus-live-timeout 60
  "Seconds to wait for the server.  Generous: it starts a JVM.")

(defconst ltex-plus-live-server-floor "18.7.0"
  "Oldest `ltex-ls-plus' these tests are written against.
The README calls 18.7 the recommended version; the Emacs-Lisp parser
and the `serverInfo' the tests read both arrived around it.  An older
server lacks features and fails as a missing diagnostic rather than as
a message, so the suite declines to run rather than reporting that
absence as a bug in the client.")

(defun ltex-plus-live-server-version ()
  "Return the version the installed `ltex-ls-plus' reports, or nil.
Read from the binary, so that it can be compared with what the running
server says about itself.  A binary the kernel refuses to run -- wrong
architecture, a script whose interpreter is missing -- is reported and
counts as no version, which makes the suite skip and say so."
  (when-let* ((executable (lsp-ltex-plus--server-executable))
              (output (with-output-to-string
                        (with-current-buffer standard-output
                          (condition-case err
                              (call-process executable nil t nil "--version")
                            (file-error
                             (message "[live] Cannot run %s: %s"
                                      executable (error-message-string err))))))))
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
client's fault: an explicit opt-in, a server that can be found, and one
new enough to behave as these tests expect."
  (and (member (getenv "LTEX_PLUS_LIVE") '("1" "t" "yes"))
       (lsp-ltex-plus--server-executable)
       (ltex-plus-live-version-at-least-p (ltex-plus-live-server-version)
                                          ltex-plus-live-server-floor)
       t))

(defun ltex-plus-live-reason ()
  "Say why the live tests are being skipped."
  (cond ((not (member (getenv "LTEX_PLUS_LIVE") '("1" "t" "yes")))
         "live tests are opt-in: set LTEX_PLUS_LIVE=1 (or run `make test-live')")
        ((not (lsp-ltex-plus--server-executable))
         (format "%s cannot be found" lsp-ltex-plus-ls-plus-executable))
        (t (format "ltex-ls-plus %s is older than %s, the version these tests assume"
                   (or (ltex-plus-live-server-version) "of an unreadable version")
                   ltex-plus-live-server-floor))))

;;;; -- A batch session ---------------------------------------------------------

(defun ltex-plus-live-configure ()
  "Set what a batch session needs to talk to the server briskly.
Only the change delay: the client asks no questions and needs no
autoloads, so there is nothing else to pre-answer."
  (setq lsp-ltex-plus-change-delay 0.1))

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

(defvar ltex-plus-live--publishes (make-hash-table :test #'eq)
  "Buffer -> how many times the server has published for it.
Counted per buffer, not in total: several buffers share one server, so
a global counter is satisfied by somebody else's check and a test
waiting on its own would sail past with stale diagnostics in hand.")

(defun ltex-plus-live--count-publish (buffer)
  "Record that the server published for BUFFER.
On `lsp-ltex-plus--diagnostics-functions', which also runs when a buffer
leaves the server and its diagnostics are cleared; that is not a
publish, and the buffer is no longer open by then, so it is not
counted."
  (when (lsp-ltex-plus--document-open-p buffer)
    (puthash buffer (1+ (gethash buffer ltex-plus-live--publishes 0))
             ltex-plus-live--publishes)))

(add-hook 'lsp-ltex-plus--diagnostics-functions #'ltex-plus-live--count-publish)

(defun ltex-plus-live-after-publish (thunk &optional label buffer)
  "Call THUNK, then wait for the server to publish for BUFFER again.
The signal a test asserting an *absence* needs: an empty diagnostic list
means nothing at all until the server has spoken about this buffer
since the change.  BUFFER defaults to the current one."
  (let* ((buffer (or buffer (current-buffer)))
         (before (gethash buffer ltex-plus-live--publishes 0)))
    (funcall thunk)
    (ltex-plus-live-until
     (lambda () (> (gethash buffer ltex-plus-live--publishes 0) before))
     (or label "the server to publish again"))))

;;;; -- Reading what the server said --------------------------------------------

(defun ltex-plus-live-diagnostics (&optional buffer)
  "Return the diagnostics the server last published for BUFFER, as a list."
  (buffer-local-value 'lsp-ltex-plus--diagnostics (or buffer (current-buffer))))

(defun ltex-plus-live-messages (&optional buffer)
  "Return the diagnostic messages for BUFFER, as a list of strings."
  (mapcar (lambda (diagnostic) (plist-get diagnostic :message))
          (ltex-plus-live-diagnostics buffer)))

(defun ltex-plus-live-flagged-p (word &optional buffer)
  "Non-nil when some diagnostic in BUFFER is about WORD.
LTeX+ reports an unknown word by quoting it in the message."
  (seq-some (lambda (message) (string-match-p (regexp-quote word) message))
            (ltex-plus-live-messages buffer)))

;;;; -- Documents ---------------------------------------------------------------

(defvar ltex-plus-live--root nil
  "The directory every live document in this process lives under.")

(defvar ltex-plus-live--buffers nil
  "Buffers opened by `ltex-plus-live-open', killed on exit.")

(defun ltex-plus-live-root ()
  "Return this process's document root, creating it on first use."
  (or ltex-plus-live--root
      (setq ltex-plus-live--root
            (file-name-as-directory (make-temp-file "ltex-plus-live-" t)))))

(defun ltex-plus-live-write (name contents &optional root)
  "Write CONTENTS to NAME under ROOT (default the shared root); return its path.
NAME must be unique across the file.  Buffers opened by one test stay
alive for the rest of the process, so rewriting a name another test is
still visiting makes the next `find-file-noselect' ask whether to reread
it from disk -- and in batch that question reaches an empty stdin and
fails the test with `end-of-file', naming neither the file nor the
test that wrote it."
  (let ((path (expand-file-name name (or root (ltex-plus-live-root)))))
    (make-directory (file-name-directory path) t)
    (with-temp-file path (insert contents))
    path))

(defun ltex-plus-live-open (path)
  "Visit PATH, turn the mode on, and wait until the server has checked it.
Returns the buffer.  Waits for one publish, so a test can read
diagnostics immediately and an empty list means the server found
nothing rather than that it has not looked yet."
  (let ((buffer (ltex-plus-test-visit path)))
    (push buffer ltex-plus-live--buffers)
    (with-current-buffer buffer
      (ltex-plus-live-after-publish
       (lambda () (let ((inhibit-message t)) (lsp-ltex-plus-mode 1)))
       (format "the first check of %s" (file-name-nondirectory path))))
    buffer))

(defun ltex-plus-live-teardown ()
  "Shut the server down and remove everything this process created."
  (dolist (buffer ltex-plus-live--buffers)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer (set-buffer-modified-p nil))
      (kill-buffer buffer)))
  (setq ltex-plus-live--buffers nil)
  (when (lsp-ltex-plus--live-connection)
    (lsp-ltex-plus--shutdown-connection))
  (when (and ltex-plus-live--root (file-directory-p ltex-plus-live--root))
    (delete-directory ltex-plus-live--root t))
  (setq ltex-plus-live--root nil))

(provide 'ltex-plus-live-helper)
;;; ltex-plus-live-helper.el ends here
