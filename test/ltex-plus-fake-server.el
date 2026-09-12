;;; ltex-plus-fake-server.el --- An in-process stand-in for ltex-ls-plus -*- lexical-binding: t; -*-

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:

;; A fake `ltex-ls-plus' that lives inside the test's own Emacs, so the
;; connection layer can be exercised offline and in CI: no JVM, no
;; binary, no network beyond a loopback socket.
;;
;; It follows the pattern of `jsonrpc''s own test suite.  A listening
;; socket accepts one connection and wraps it in a
;; `jsonrpc-process-connection' speaking as the server.  The client under
;; test is pointed at it by overriding the one function that creates the
;; server process, `lsp-ltex-plus--make-process', to return a network
;; stream instead; everything above that function, the handshake, the
;; dispatchers, document sync, runs unchanged.
;;
;; The fake behaves the way the real server was observed to (see
;; CLAUDE.md, "Server Protocol Facts"): it answers `initialize' with the
;; capabilities `ltex-ls-plus' advertises, and on every `didOpen' and
;; `didChange' it first pulls configuration through both of the server's
;; requests and then publishes diagnostics, one for each match of
;; `ltex-plus-fake-flag-regexp' in the document text it holds.  Every
;; message it receives is recorded, so a test can assert on exactly what
;; went over the wire.
;;
;; What it cannot stand in for is the real server's judgement of a text;
;; that stays with the live suite.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'jsonrpc)
(require 'ltex-plus-test-helper)

;;;; -- State ------------------------------------------------------------------

(defvar ltex-plus-fake-listener nil
  "The listening socket, while the fake is up.")

(defvar ltex-plus-fake-peer nil
  "The server-side `jsonrpc-process-connection' to the client under test.
Tests use it to send the client anything the real server might.")

(defvar ltex-plus-fake-received nil
  "Every message the fake received, newest first, as (METHOD . PARAMS).
METHOD is a symbol; requests and notifications are recorded alike.")

(defvar ltex-plus-fake-config-replies nil
  "Replies to the fake's configuration pulls, newest first.
Each entry is (URI METHOD RESULT), or (URI METHOD :error ERROR) when
the client refused the request.")

(defvar ltex-plus-fake-documents nil
  "Alist of URI to (VERSION . TEXT) for every document the client opened.")

(defvar ltex-plus-fake-flag-regexp "\\bteh\\b"
  "Every match of this in a document's text becomes one diagnostic.")

(defvar ltex-plus-fake-pull-configuration t
  "Whether to pull configuration before publishing, as the real server does.")

(defvar ltex-plus-fake-server-version "18.7.1"
  "The version the fake reports in `serverInfo'.")

(defvar ltex-plus-fake-code-actions []
  "The vector of code actions the fake returns to `textDocument/codeAction'.")

(defun ltex-plus-fake-received (method)
  "Return the params of every message with METHOD, oldest first."
  (mapcar #'cdr (seq-filter (lambda (entry) (eq (car entry) method))
                            (reverse ltex-plus-fake-received))))

;;;; -- Positions --------------------------------------------------------------

(defun ltex-plus-fake--utf16-width (string)
  "Return the length of STRING in UTF-16 code units."
  (cl-loop for char across string sum (if (> char #xFFFF) 2 1)))

(defun ltex-plus-fake--position (text index)
  "Return the LSP position of character INDEX in TEXT.
Lines count from zero; the character offset is in UTF-16 code units,
the protocol default the client declared."
  (let* ((before (substring text 0 index))
         (line-start (or (cl-position ?\n before :from-end t) -1)))
    (list :line (cl-count ?\n before)
          :character (ltex-plus-fake--utf16-width
                      (substring before (1+ line-start))))))

(defun ltex-plus-fake-diagnostics (text)
  "Return the diagnostics the fake publishes for TEXT, as a vector."
  (let ((found nil) (start 0))
    (while (string-match ltex-plus-fake-flag-regexp text start)
      (push (list :range (list :start (ltex-plus-fake--position text (match-beginning 0))
                               :end (ltex-plus-fake--position text (match-end 0)))
                  :severity 2
                  :code "MORFOLOGIK_RULE_EN_US"
                  :source "LTeX+"
                  :message (format "Possible spelling mistake found: %s"
                                   (match-string 0 text)))
            found)
      (setq start (match-end 0)))
    (vconcat (nreverse found))))

;;;; -- What the fake answers --------------------------------------------------

(defconst ltex-plus-fake-capabilities
  '(:textDocumentSync 1
    :completionProvider (:triggerCharacters [])
    :codeActionProvider (:codeActionKinds ["quickfix.ltex.acceptSuggestions"])
    :executeCommandProvider (:commands ["_ltex.checkDocument" "_ltex.getServerStatus"])
    :workspace (:workspaceFolders (:supported t :changeNotifications t)))
  "The capabilities `ltex-ls-plus' advertises, as observed.")

(defun ltex-plus-fake--handle-request (_conn method params)
  "Answer the client's request METHOD with PARAMS, as the real server would."
  (push (cons method params) ltex-plus-fake-received)
  (pcase method
    ('initialize
     (list :capabilities ltex-plus-fake-capabilities
           :serverInfo (list :name "ltex-ls-plus"
                             :version ltex-plus-fake-server-version)))
    ('shutdown nil)
    ('textDocument/codeAction ltex-plus-fake-code-actions)
    (_ (jsonrpc-error :code -32601 :message (format "Unknown method %s" method)))))

(defun ltex-plus-fake--handle-notification (conn method params)
  "Act on the client's notification METHOD with PARAMS."
  (push (cons method params) ltex-plus-fake-received)
  (pcase method
    ('exit
     (delete-process (jsonrpc--process conn)))
    ('textDocument/didOpen
     (let ((document (plist-get params :textDocument)))
       (ltex-plus-fake--document-changed (plist-get document :uri)
                                         (plist-get document :version)
                                         (plist-get document :text))))
    ('textDocument/didChange
     (let ((document (plist-get params :textDocument))
           (changes (plist-get params :contentChanges)))
       (ltex-plus-fake--document-changed
        (plist-get document :uri)
        (plist-get document :version)
        (plist-get (aref changes (1- (length changes))) :text))))
    ('textDocument/didClose
     (let ((uri (plist-get (plist-get params :textDocument) :uri)))
       (setq ltex-plus-fake-documents (assoc-delete-all uri ltex-plus-fake-documents))
       (ltex-plus-fake-publish uri [] nil)))))

(defun ltex-plus-fake--document-changed (uri version text)
  "Record TEXT as VERSION of URI, then pull configuration and publish."
  (setf (alist-get uri ltex-plus-fake-documents nil nil #'equal) (cons version text))
  (if ltex-plus-fake-pull-configuration
      (ltex-plus-fake--pull uri 'workspace/configuration
                            (lambda ()
                              (ltex-plus-fake--pull uri 'ltex/workspaceSpecificConfiguration
                                                    (lambda () (ltex-plus-fake--check uri)))))
    (ltex-plus-fake--check uri)))

(defun ltex-plus-fake--pull (uri method then)
  "Ask the client for configuration of URI with METHOD, then call THEN.
The reply, or the refusal, is recorded in `ltex-plus-fake-config-replies'
either way, and THEN runs either way: the real server publishes on what
it has."
  (jsonrpc-async-request
   ltex-plus-fake-peer method
   (list :items (vector (list :scopeUri uri :section "ltex")))
   :success-fn (lambda (result)
                 (push (list uri method result) ltex-plus-fake-config-replies)
                 (funcall then))
   :error-fn (lambda (err)
               (push (list uri method :error err) ltex-plus-fake-config-replies)
               (funcall then))
   :timeout 5))

(defun ltex-plus-fake--check (uri)
  "Publish the diagnostics for the text the fake holds for URI, if any."
  (when-let* ((entry (assoc uri ltex-plus-fake-documents)))
    (ltex-plus-fake-publish uri (ltex-plus-fake-diagnostics (cddr entry)) (cadr entry))))

(defun ltex-plus-fake-publish (uri diagnostics &optional version)
  "Send the client `textDocument/publishDiagnostics' for URI.
DIAGNOSTICS is a vector; VERSION, when non-nil, is included."
  (jsonrpc-notify ltex-plus-fake-peer 'textDocument/publishDiagnostics
                  (append (list :uri uri :diagnostics diagnostics)
                          (and version (list :version version)))))

;;;; -- Starting and stopping ---------------------------------------------------

(defun ltex-plus-fake--accept (proc event)
  "Wrap the connection PROC in a server-side jsonrpc connection on EVENT."
  (when (string-match-p "\\`open" event)
    (setq ltex-plus-fake-peer
          (make-instance 'jsonrpc-process-connection
                         :name "ltex-plus-fake"
                         :process proc
                         :request-dispatcher #'ltex-plus-fake--handle-request
                         :notification-dispatcher #'ltex-plus-fake--handle-notification
                         :events-buffer-config '(:size 0)))))

(defun ltex-plus-fake-start ()
  "Start the fake listening on a loopback port, and return that port.
Stops a fake that is already up, and resets everything it records."
  (ltex-plus-fake-stop)
  (setq ltex-plus-fake-received nil
        ltex-plus-fake-config-replies nil
        ltex-plus-fake-documents nil
        ltex-plus-fake-peer nil)
  (setq ltex-plus-fake-listener
        (make-network-process :name "ltex-plus-fake-listener"
                              :server t
                              :host "127.0.0.1"
                              :service t
                              :noquery t
                              :coding 'binary
                              :sentinel #'ltex-plus-fake--accept))
  (process-contact ltex-plus-fake-listener :service))

(defun ltex-plus-fake-stop ()
  "Stop the fake and drop its connection to the client."
  (when ltex-plus-fake-peer
    (ignore-errors (delete-process (jsonrpc--process ltex-plus-fake-peer)))
    (setq ltex-plus-fake-peer nil))
  (when ltex-plus-fake-listener
    (ignore-errors (delete-process ltex-plus-fake-listener))
    (setq ltex-plus-fake-listener nil)))

(defun ltex-plus-fake--connect (name _command _root)
  "Return a network stream to the fake, in place of a server process.
Bound over `lsp-ltex-plus--make-process' while the fake is in use; NAME
is the connection's name, the other two arguments are what a real
server would have been started with."
  (make-network-process :name name
                        :host "127.0.0.1"
                        :service (process-contact ltex-plus-fake-listener :service)
                        :noquery t
                        :coding 'binary))

(defmacro ltex-plus-fake-with-connection (&rest body)
  "Run BODY with the client under test able to connect to the fake.
The fake is started first and stopped afterwards, whatever BODY does;
any connection the client opened is shut down too, so the next test
starts from nothing."
  (declare (indent 0) (debug t))
  `(progn
     (ltex-plus-fake-start)
     (unwind-protect
         (cl-letf (((symbol-function 'lsp-ltex-plus--server-executable)
                    (lambda () "ltex-ls-plus"))
                   ((symbol-function 'lsp-ltex-plus--server-command)
                    (lambda () (list "ltex-ls-plus")))
                   ((symbol-function 'lsp-ltex-plus--make-process)
                    #'ltex-plus-fake--connect))
           ,@body)
       (when (lsp-ltex-plus--live-connection)
         (ignore-errors (lsp-ltex-plus--shutdown-connection)))
       (setq lsp-ltex-plus--connection nil)
       (ltex-plus-fake-stop))))

(defun ltex-plus-fake-wait-for (predicate &optional timeout)
  "Let processes run until PREDICATE returns non-nil, and return that value.
Signals an error after TIMEOUT seconds (default 5): a test that waits
forever is a test that hangs CI."
  (let ((deadline (+ (float-time) (or timeout 5)))
        (value nil))
    (while (not (setq value (funcall predicate)))
      (when (> (float-time) deadline)
        (error "Timed out waiting for %S" predicate))
      (accept-process-output nil 0.05))
    value))

(defun ltex-plus-fake-ready-connection ()
  "Start the client's connection to the fake and wait until it is ready."
  (let ((conn (lsp-ltex-plus--ensure-connection)))
    (ltex-plus-fake-wait-for (lambda () (lsp-ltex-plus--connection-ready conn)))
    conn))

(provide 'ltex-plus-fake-server)
;;; ltex-plus-fake-server.el ends here
