;;; ltex-plus-benchmark-test.el --- Latency measurement advice -*- lexical-binding: t; -*-

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:

;; Two advices, installed only when `lsp-ltex-plus-show-latency' is on at
;; setup: one around `lsp-notify' to record when a trigger went out, one
;; after `lsp--on-diagnostics' to report how long the answer took.
;;
;; They are worth testing out of proportion to the feature, because both
;; sit on functions that carry traffic for every LSP client in the
;; session.  The around-advice is the sharp one: every notification any
;; server sends goes through it, so a path that fails to call the
;; original stops all of them.  Nothing about the symptom would point
;; here -- the feature being advised is a diagnostic aid that most users
;; never switch on.
;;
;; `lsp--on-diagnostics' is also a private lsp-mode function whose
;; signature is not promised, which the source notes as the reason the
;; advice is not installed by default.
;;
;; The functions are called directly rather than through `advice-add':
;; what is under test is the bodies, and installing them would leave
;; global advice on `lsp-mode' for the rest of the process.

;;; Code:

(require 'ltex-plus-test-helper)

(defun ltex-plus-benchmark-test--workspace (server-id)
  "Return a workspace fixture belonging to SERVER-ID."
  (make-lsp--workspace :client (make-lsp--client :server-id server-id)))

(defmacro ltex-plus-benchmark-test--with (&rest body)
  "Run BODY with latency reporting on and an empty measurement table.
Binds `ours' and `theirs' to two workspaces, and `said' to whatever the
echo area was told, updated as messages are emitted."
  (declare (indent 0) (debug t))
  `(let ((lsp-ltex-plus-show-latency t)
         (lsp-ltex-plus-debug nil)
         (lsp-ltex-plus--pending-measurements (make-hash-table :test 'eq))
         (ours (ltex-plus-benchmark-test--workspace 'ltex-ls-plus))
         (theirs (ltex-plus-benchmark-test--workspace 'texlab))
         (said nil))
     (cl-letf (((symbol-function 'message)
                (lambda (format &rest args) (setq said (apply #'format format args)))))
       (ignore ours theirs said)
       ,@body)))

(defun ltex-plus-benchmark-test--pending (workspace table)
  "Return the measurement recorded for WORKSPACE in TABLE, if any."
  (gethash workspace table))

;;;; -- The around-advice must never swallow a notification --------------------

(ert-deftest ltex-plus-benchmark-test-the-notification-always-goes-out ()
  "Every path through the advice calls the function it wraps.
It sits on `lsp-notify', which carries traffic for every LSP client in
the session.  A path that returned without calling the original would
stop all of them, and the symptom would point nowhere near a latency
measurement nobody switched on."
  (dolist (case (list
                 ;; a trigger we measure, in our own workspace
                 (list 'ltex-ls-plus "textDocument/didChange" t)
                 ;; a method we do not measure
                 (list 'ltex-ls-plus "textDocument/didSave" t)
                 ;; another server's traffic
                 (list 'texlab "textDocument/didChange" t)
                 ;; no workspace current at all
                 (list nil "textDocument/didChange" t)
                 ;; reporting switched off
                 (list 'ltex-ls-plus "textDocument/didChange" nil)))
    (pcase-let ((`(,server-id ,method ,latency) case))
      (let ((lsp-ltex-plus-show-latency latency)
            (lsp-ltex-plus--pending-measurements (make-hash-table :test 'eq))
            (lsp--cur-workspace (and server-id
                                     (ltex-plus-benchmark-test--workspace server-id)))
            (forwarded nil))
        (lsp-ltex-plus--benchmark-outgoing
         (lambda (&rest args) (setq forwarded args) 'the-original-value)
         method '(:some "params"))
        (should (equal forwarded (list method '(:some "params"))))))))

(ert-deftest ltex-plus-benchmark-test-the-original-return-value-is-kept ()
  "The advice returns whatever `lsp-notify' returned.
It observes; it does not answer for the function it wraps."
  (let ((lsp--cur-workspace (ltex-plus-benchmark-test--workspace 'ltex-ls-plus))
        (lsp-ltex-plus-show-latency t)
        (lsp-ltex-plus--pending-measurements (make-hash-table :test 'eq)))
    (should (eq (lsp-ltex-plus--benchmark-outgoing
                 (lambda (&rest _) 'from-lsp-notify)
                 "textDocument/didChange" nil)
                'from-lsp-notify))))

;;;; -- What gets recorded ------------------------------------------------------

(ert-deftest ltex-plus-benchmark-test-only-triggers-are-recorded ()
  "A measurement starts for the two methods that cause a check, not others."
  (ltex-plus-benchmark-test--with
    (let ((lsp--cur-workspace ours))
      (dolist (method '("textDocument/didOpen" "textDocument/didChange"))
        (clrhash lsp-ltex-plus--pending-measurements)
        (lsp-ltex-plus--benchmark-outgoing #'ignore method nil)
        (should (gethash ours lsp-ltex-plus--pending-measurements)))
      (dolist (method '("textDocument/didSave" "textDocument/didClose"
                        "workspace/didChangeConfiguration"))
        (clrhash lsp-ltex-plus--pending-measurements)
        (lsp-ltex-plus--benchmark-outgoing #'ignore method nil)
        (should-not (gethash ours lsp-ltex-plus--pending-measurements))))))

(ert-deftest ltex-plus-benchmark-test-another-server-is-not-recorded ()
  "Traffic belonging to another server starts no measurement.
The advice is global; the measurement is not."
  (ltex-plus-benchmark-test--with
    (let ((lsp--cur-workspace theirs))
      (lsp-ltex-plus--benchmark-outgoing #'ignore "textDocument/didChange" nil)
      (should (= 0 (hash-table-count lsp-ltex-plus--pending-measurements))))))

(ert-deftest ltex-plus-benchmark-test-the-label-follows-the-method ()
  "didOpen is recorded as a cold start, didChange as a warm one.
The two are reported in different words, so the numbers can be told
apart; that distinction begins here."
  (ltex-plus-benchmark-test--with
    (let ((lsp--cur-workspace ours))
      (lsp-ltex-plus--benchmark-outgoing #'ignore "textDocument/didOpen" nil)
      (should (equal (nth 2 (gethash ours lsp-ltex-plus--pending-measurements))
                     "initial"))
      (lsp-ltex-plus--benchmark-outgoing #'ignore "textDocument/didChange" nil)
      (should (equal (nth 2 (gethash ours lsp-ltex-plus--pending-measurements))
                     "incremental")))))

(ert-deftest ltex-plus-benchmark-test-the-latest-trigger-wins ()
  "A second trigger overwrites the first, one slot per workspace.
A `publishDiagnostics' carries nothing that says which trigger it
answers, so the source keeps only the most recent and documents the
resulting bias as always optimistic.  This is that choice, pinned."
  (ltex-plus-benchmark-test--with
    (let ((lsp--cur-workspace ours))
      (lsp-ltex-plus--benchmark-outgoing #'ignore "textDocument/didOpen" nil)
      (lsp-ltex-plus--benchmark-outgoing #'ignore "textDocument/didChange" nil)
      (should (= 1 (hash-table-count lsp-ltex-plus--pending-measurements)))
      (should (equal (nth 2 (gethash ours lsp-ltex-plus--pending-measurements))
                     "incremental")))))

(ert-deftest ltex-plus-benchmark-test-switching-reporting-off-stops-recording ()
  "With the option off the advice records nothing, though it stays installed.
It is installed once at setup and never removed, so the body has to read
the option rather than assume it."
  (ltex-plus-benchmark-test--with
    (let ((lsp--cur-workspace ours)
          (lsp-ltex-plus-show-latency nil))
      (lsp-ltex-plus--benchmark-outgoing #'ignore "textDocument/didChange" nil)
      (should (= 0 (hash-table-count lsp-ltex-plus--pending-measurements))))))

;;;; -- What gets reported ------------------------------------------------------

(ert-deftest ltex-plus-benchmark-test-a-round-trip-is-reported-once ()
  "A trigger followed by diagnostics reports, and clears the slot.
Leaving the entry behind would let the next unrelated publish report a
second time, timed from a trigger it has nothing to do with."
  (ltex-plus-benchmark-test--with
    (let ((lsp--cur-workspace ours))
      (lsp-ltex-plus--benchmark-outgoing #'ignore "textDocument/didChange" nil))
    (lsp-ltex-plus--benchmark-diagnostics ours)
    (should (string-match-p "Completed spell check in [0-9]+ ms" said))
    (should (= 0 (hash-table-count lsp-ltex-plus--pending-measurements)))
    (setq said nil)
    (lsp-ltex-plus--benchmark-diagnostics ours)
    (should-not said)))

(ert-deftest ltex-plus-benchmark-test-a-cold-start-is-worded-differently ()
  "didOpen reports an initial check, didChange a plain one."
  (ltex-plus-benchmark-test--with
    (let ((lsp--cur-workspace ours))
      (lsp-ltex-plus--benchmark-outgoing #'ignore "textDocument/didOpen" nil))
    (lsp-ltex-plus--benchmark-diagnostics ours)
    (should (string-match-p "initial spell check" said))))

(ert-deftest ltex-plus-benchmark-test-diagnostics-without-a-trigger-are-quiet ()
  "Diagnostics arriving with nothing pending report nothing.
The server publishes on its own account too -- on a settings change, for
instance -- and there is no elapsed time to quote for those."
  (ltex-plus-benchmark-test--with
    (lsp-ltex-plus--benchmark-diagnostics ours)
    (should-not said)))

(ert-deftest ltex-plus-benchmark-test-another-server-is-not-reported ()
  "Diagnostics from another server report nothing.
`lsp--on-diagnostics' is shared by every client in the session, so the
advice checks whose diagnostics these are.  A measurement is planted
under the other workspace directly: recording one the ordinary way is
impossible, and without it the hash lookup would fail on its own and the
check under test would never be reached."
  (ltex-plus-benchmark-test--with
    (puthash theirs (list (current-time) (current-buffer) "incremental")
             lsp-ltex-plus--pending-measurements)
    (lsp-ltex-plus--benchmark-diagnostics theirs)
    (should-not said)
    (should (gethash theirs lsp-ltex-plus--pending-measurements))))

(ert-deftest ltex-plus-benchmark-test-reporting-tolerates-extra-arguments ()
  "The advice accepts whatever `lsp--on-diagnostics' is called with.
It is a private lsp-mode function; the source says as much, and gives it
as the reason this advice is not installed by default.  A signature that
grows an argument must not turn into an error on every publish."
  (ltex-plus-benchmark-test--with
    (let ((lsp--cur-workspace ours))
      (lsp-ltex-plus--benchmark-outgoing #'ignore "textDocument/didChange" nil))
    (lsp-ltex-plus--benchmark-diagnostics ours '(:uri "file:///x.md") 'extra 42)
    (should said)))

(ert-deftest ltex-plus-benchmark-test-the-report-stays-out-of-the-message-log ()
  "The timing is shown, not logged.
It fires on every check; in *Messages* it would bury everything else."
  (ltex-plus-benchmark-test--with
    (let ((lsp--cur-workspace ours))
      (lsp-ltex-plus--benchmark-outgoing #'ignore "textDocument/didChange" nil))
    (let ((seen 'unset))
      (cl-letf (((symbol-function 'message)
                 (lambda (&rest _) (setq seen message-log-max))))
        (lsp-ltex-plus--benchmark-diagnostics ours))
      (should-not seen))))

(provide 'ltex-plus-benchmark-test)
;;; ltex-plus-benchmark-test.el ends here
