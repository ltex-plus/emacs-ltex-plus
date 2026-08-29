;;; ltex-plus-patch-test.el --- Kind-First message routing -*- lexical-binding: t; -*-

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:

;; Standard `lsp-mode' routes an incoming JSON-RPC message by looking for
;; an `id' first: with one, it is a response to something the client
;; asked; without one, a notification.  LTeX+ sends server-initiated
;; *requests*, which carry both an `id' and a `method'.  When the
;; server's id happens to match one the client is waiting on, lsp-mode
;; hands the request to the pending response handler and both sides wait
;; for each other for good.
;;
;; The patch routes on kind instead: a `method' makes it a request or a
;; notification whatever the `id' says, and the `id' only separates a
;; response from an error response.  The same fix is upstream now (PR
;; #5055), so on a recent `lsp-mode' the advice is not installed at all
;; -- but the function stays as the backport, and it is only ever
;; exercised on the `lsp-mode' versions that need it.  Which is a good
;; reason to test it here rather than in a live session.
;;
;; These tests call the function directly.  Nothing is advised, so
;; whatever `lsp-mode' does with real traffic is untouched.

;;; Code:

(require 'ltex-plus-test-helper)

(defvar ltex-plus-patch-test--seen nil
  "What the stubbed lsp-mode entry points were handed, most recent first.")

(defmacro ltex-plus-patch-test--dispatch (message &rest body)
  "Route MESSAGE through the patch with lsp-mode's entry points stubbed.
Inside BODY, `ltex-plus-patch-test--seen' holds one (KIND . PAYLOAD)
entry per call the patch made, and `handlers' is the client's pending
response-handler table, pre-loaded with a handler for id 1 recording
\(response . RESULT) or (error . ERROR)."
  (declare (indent 1) (debug t))
  `(let* ((ltex-plus-patch-test--seen nil)
          (handlers (make-hash-table :test #'eql))
          (client (make-lsp--client :server-id 'ltex-ls-plus
                                    :response-handlers handlers))
          (workspace (make-lsp--workspace :client client)))
     (puthash 1
              (list (lambda (result)
                      (push (cons 'response result) ltex-plus-patch-test--seen))
                    (lambda (err)
                      (push (cons 'error err) ltex-plus-patch-test--seen))
                    "textDocument/codeAction"
                    nil
                    nil)
              handlers)
     (cl-letf (((symbol-function 'lsp--on-request)
                (lambda (_workspace params)
                  (push (cons 'request params) ltex-plus-patch-test--seen)))
               ((symbol-function 'lsp--on-notification)
                (lambda (_workspace params)
                  (push (cons 'notification params) ltex-plus-patch-test--seen))))
       (lsp-ltex-plus--parser-on-message-patch ,message workspace)
       ,@body)))

(defun ltex-plus-patch-test--kinds ()
  "Return the kinds the patch dispatched, in the order it dispatched them."
  (mapcar #'car (reverse ltex-plus-patch-test--seen)))

;;;; -- The deadlock ------------------------------------------------------------

(ert-deftest ltex-plus-patch-test-server-request-wins-over-a-colliding-id ()
  "A server request with a colliding id is still a request.
This is the deadlock: the server asks `workspace/configuration' with an
id the client is already waiting on, unpatched lsp-mode calls the
pending response handler with the request's payload, the request is
never answered, and both sides stop."
  (ltex-plus-patch-test--dispatch
      (ltex-plus-test-obj :jsonrpc "2.0"
                          :id 1
                          :method "workspace/configuration"
                          :params (ltex-plus-test-obj :items []))
    (should (equal (ltex-plus-patch-test--kinds) '(request)))
    ;; The pending handler is untouched, so the real response can still
    ;; arrive and be delivered.
    (should (gethash 1 handlers))))

(ert-deftest ltex-plus-patch-test-notification-has-no-id ()
  "A message with a method and no id is a notification."
  (ltex-plus-patch-test--dispatch
      (ltex-plus-test-obj :jsonrpc "2.0"
                          :method "textDocument/publishDiagnostics"
                          :params (ltex-plus-test-obj :uri "file:///doc.md"))
    (should (equal (ltex-plus-patch-test--kinds) '(notification)))))

;;;; -- Responses still work ----------------------------------------------------

(ert-deftest ltex-plus-patch-test-response-reaches-its-callback ()
  "A message with an id and no method is a response, and is delivered once.
The handler is dropped as it fires, so a duplicate reply cannot call it
a second time."
  (ltex-plus-patch-test--dispatch
      (ltex-plus-test-obj :jsonrpc "2.0" :id 1 :result "the result")
    (should (equal ltex-plus-patch-test--seen '((response . "the result"))))
    (should-not (gethash 1 handlers))))

(ert-deftest ltex-plus-patch-test-error-response-reaches-its-callback ()
  "An `error' field routes to the error callback, not the success one."
  (ltex-plus-patch-test--dispatch
      (ltex-plus-test-obj :jsonrpc "2.0"
                          :id 1
                          :error (ltex-plus-test-obj :code -32603
                                                     :message "boom"))
    (should (equal (ltex-plus-patch-test--kinds) '(error)))
    (should-not (gethash 1 handlers))))

(ert-deftest ltex-plus-patch-test-string-ids-are-normalised ()
  "A response whose id arrived as a string finds its handler.
Client-generated ids are numbers; a server that echoes them as strings
would otherwise strand every request."
  (ltex-plus-patch-test--dispatch
      (ltex-plus-test-obj :jsonrpc "2.0" :id "1" :result "the result")
    (should (equal ltex-plus-patch-test--seen '((response . "the result"))))))

(ert-deftest ltex-plus-patch-test-unknown-response-id-is-dropped ()
  "A response nobody is waiting for is discarded quietly."
  (ltex-plus-patch-test--dispatch
      (ltex-plus-test-obj :jsonrpc "2.0" :id 99 :result "orphan")
    (should-not ltex-plus-patch-test--seen)
    (should (gethash 1 handlers))))

;;;; -- Robustness --------------------------------------------------------------

(ert-deftest ltex-plus-patch-test-empty-message-is-a-notification ()
  "A message with neither a method nor an id falls back to notification.
lsp-mode's own handler is left to decide what to make of it; the point
is that the parser does not signal."
  (ltex-plus-patch-test--dispatch (ltex-plus-test-obj :jsonrpc "2.0")
    (should (equal (ltex-plus-patch-test--kinds) '(notification)))))

(ert-deftest ltex-plus-patch-test-a-bad-message-does-not-take-down-the-client ()
  "An error while handling one message is demoted, not raised.
The patch replaces the parser for every LSP client in the session, so a
signal escaping here would take down servers that have nothing to do
with this package."
  (let ((inhibit-message t))
    (ltex-plus-patch-test--dispatch
        (ltex-plus-test-obj :jsonrpc "2.0" :id 1 :result "x")
      ;; Reached at all means `with-demoted-errors' did its job; the
      ;; assertion is simply that the call returned.
      (should t)))
  (let ((inhibit-message t)
        (workspace (make-lsp--workspace :client nil)))
    ;; A workspace with no client makes the handler lookup signal; the
    ;; call must still return normally.
    (should-not (lsp-ltex-plus--parser-on-message-patch
                 (ltex-plus-test-obj :jsonrpc "2.0" :id 1 :result "x")
                 workspace))))

(ert-deftest ltex-plus-patch-test-reads-both-json-representations ()
  "The patch reads hash-table messages and plist messages alike.
It carries its own `json-get' rather than depending on lsp-mode
internals, precisely so it works whichever way `lsp-mode' was compiled;
this suite would otherwise only ever exercise one of the two."
  (dolist (message (list (let ((table (make-hash-table :test #'equal)))
                           (puthash "jsonrpc" "2.0" table)
                           (puthash "id" 1 table)
                           (puthash "method" "workspace/configuration" table)
                           table)
                         '(:jsonrpc "2.0"
                           :id 1
                           :method "workspace/configuration")))
    (ltex-plus-patch-test--dispatch message
      (should (equal (ltex-plus-patch-test--kinds) '(request))))))

;;;; -- Whether the patch is applied at all -------------------------------------

(ert-deftest ltex-plus-patch-test-upstream-detection-answers-cleanly ()
  "The upstream-fix probe returns a boolean and signals nothing.
It gates whether the backport is installed at all, and it works by
inspecting the installed `lsp-mode' -- so it has to cope with whatever
version is there, including ones it has never seen."
  (should (memq (and (lsp-ltex-plus--maybe-upstream-fixes-present-p) t)
                '(nil t))))

(ert-deftest ltex-plus-patch-test-is-not-installed-by-default ()
  "Loading the package leaves lsp-mode's parser alone.
The patch is opt-in: it overrides a function every LSP client in the
session goes through."
  (should-not (advice-member-p #'lsp-ltex-plus--parser-on-message-patch
                               'lsp--parser-on-message))
  (should-not (default-value 'lsp-ltex-plus-apply-kind-first-patch)))

(provide 'ltex-plus-patch-test)
;;; ltex-plus-patch-test.el ends here
