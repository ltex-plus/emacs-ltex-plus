;;; lsp-ltex-plus-conn.el --- The connection to ltex-ls-plus -*- lexical-binding: t; -*-

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Keywords: lsp, grammar, spelling, convenience
;; URL: https://github.com/ltex-plus/emacs-ltex-plus

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:
;;
;; One `ltex-ls-plus' process per Emacs session, spoken to over the
;; `jsonrpc' library that ships with Emacs.  This file owns the process:
;; starting it, the `initialize' handshake, the dispatch of what the server
;; sends back, and shutting it down.  It knows nothing about buffers,
;; diagnostics or code actions; those layers register what they need
;; through the hooks and the dispatchers defined here.
;;
;; Why one process for the whole session: the server keeps no state per
;; workspace folder that matters to a grammar checker, so there is nothing
;; to partition.  The first buffer that needs the server starts it, rooted
;; at that buffer's project; every later buffer, from any project, reuses
;; it.  Which settings a document is checked against is decided per
;; document when the server asks, never per process.
;;
;; The handshake is asynchronous.  A JVM takes seconds to come up, and a
;; synchronous request would freeze Emacs for that long, so `initialize'
;; is sent with `jsonrpc-async-request' and work that needs a ready server
;; is queued with `lsp-ltex-plus--when-ready' until the reply arrives.
;;
;; JSON on this side is what `jsonrpc' hands out: objects are plists with
;; keyword keys, arrays are vectors, `null' is nil and `false' is
;; `:json-false'.  Since nil also serialises as `null', an empty object
;; must be sent as `lsp-ltex-plus--empty-ht' and an empty array as `[]'.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'jsonrpc)
(require 'url-util)
(require 'project)
(require 'lsp-ltex-plus-bootstrap)
(require 'lsp-ltex-plus-settings)

;;;; -- URIs -------------------------------------------------------------------

;; The server identifies a document by the URI the client gives it and
;; quotes that URI back in every request about it.  Both conversions live
;; here so that the round trip is under one roof: a file name turned into
;; a URI and back must come out byte for byte the same, or the buffer the
;; server is asking about can no longer be found by its file name.

(defconst lsp-ltex-plus--uri-path-allowed-chars
  (let ((vec (copy-sequence url-path-allowed-chars)))
    (aset vec ?: nil)
    vec)
  "Characters left unescaped in the path of a `file://' URI.
`url-path-allowed-chars' minus the colon, so that a Windows drive
letter is escaped the way other LSP clients escape it.")

(defun lsp-ltex-plus--path-to-uri (path)
  "Return the `file://' URI for the local file name PATH.
PATH is expanded but not resolved through symbolic links: the buffer
visiting it is looked up by the name it was visited under, and
`lsp-ltex-plus--uri-to-path' must give that name back."
  (concat "file://"
          (if (eq system-type 'windows-nt) "/" "")
          (url-hexify-string (directory-file-name (expand-file-name path))
                             lsp-ltex-plus--uri-path-allowed-chars)))

(defun lsp-ltex-plus--uri-to-path (uri)
  "Return the local file name a `file://' URI names.
The inverse of `lsp-ltex-plus--path-to-uri'.  A URI with any other
scheme is returned with its scheme stripped, which is enough for the
synthetic identities file-less buffers carry."
  (let* ((path (decode-coding-string
                (url-unhex-string (url-filename (url-generic-parse-url uri)))
                'utf-8)))
    (if (and (eq system-type 'windows-nt)
             (string-match-p "\\`/[A-Za-z]:" path))
        (substring path 1)
      path)))

;;;; -- The connection object --------------------------------------------------

(defclass lsp-ltex-plus-connection (jsonrpc-process-connection)
  ((root
    :initarg :root
    :accessor lsp-ltex-plus--connection-root
    :documentation "The directory the server was started in and told about.")
   (ready
    :initform nil
    :accessor lsp-ltex-plus--connection-ready
    :documentation "Non-nil once the server has answered `initialize'.")
   (capabilities
    :initform nil
    :accessor lsp-ltex-plus--connection-capabilities
    :documentation "The `capabilities' object from the `initialize' result.")
   (server-info
    :initform nil
    :accessor lsp-ltex-plus--connection-server-info
    :documentation "The `serverInfo' object from the `initialize' result.")
   (pending
    :initform nil
    :accessor lsp-ltex-plus--connection-pending
    :documentation "Thunks queued by `lsp-ltex-plus--when-ready' before READY."))
  :documentation "A `jsonrpc' connection to one `ltex-ls-plus' process.")

(defvar lsp-ltex-plus--connection nil
  "The session's connection to `ltex-ls-plus', or nil when none is running.
Read through `lsp-ltex-plus--live-connection', which also rules out a
connection whose process has since died.")

(defvar lsp-ltex-plus--after-initialize-functions nil
  "Functions called with the connection once the server is initialized.
Run after the `initialized' notification has gone out and before the
thunks queued with `lsp-ltex-plus--when-ready'.  This is where the
layers above push their configuration and open their documents.")

(defvar lsp-ltex-plus--after-shutdown-functions nil
  "Functions called with the connection after its process has ended.
Run whether the server exited on request or died; the layers above use
it to forget documents and clear diagnostics.")

(defconst lsp-ltex-plus--initialize-timeout 120
  "Seconds to wait for the server to answer `initialize'.
A JVM on a slow machine can take a good while to come up, and the
default `jsonrpc' timeout of ten seconds would give up on a server that
was about to succeed.")

;;;; -- Starting the server ----------------------------------------------------

(defun lsp-ltex-plus--local-directory (directory)
  "Return DIRECTORY if it is local and exists, else the temporary directory.
The server always runs on this machine, so a remote `default-directory'
cannot be the directory it is started in."
  (if (and (not (file-remote-p directory))
           (file-directory-p directory))
      (file-name-as-directory (expand-file-name directory))
    temporary-file-directory))

(defun lsp-ltex-plus--session-root ()
  "Return the directory to root the session's server at.
The current buffer's project root when it has one, else its
`default-directory'; a remote directory falls back on the temporary
directory.  The choice matters little: the server keeps nothing per
folder, and every document is configured on its own."
  (lsp-ltex-plus--local-directory
   (or (when-let* ((project (project-current)))
         (project-root project))
       default-directory)))

(defun lsp-ltex-plus--server-executable ()
  "Return the `ltex-ls-plus' executable to run, or nil if there is none.
`lsp-ltex-plus-ls-plus-executable' is used as given when it is an
absolute file name.  Otherwise it is looked for under the `bin'
directory of `lsp-ltex-plus-ltex-ls-path' when that is set, and then on
the variable `exec-path'."
  (let* ((name lsp-ltex-plus-ls-plus-executable)
         (home (lsp-ltex-plus--str lsp-ltex-plus-ltex-ls-path))
         (bundled (and (not (string-empty-p home))
                       (expand-file-name (concat "bin/" name) home))))
    (cond ((file-name-absolute-p name)
           (and (file-executable-p name) name))
          ((and bundled (file-executable-p bundled))
           bundled)
          (t (executable-find name)))))

(defun lsp-ltex-plus--server-command ()
  "Return the command line that starts `ltex-ls-plus', as a list.
Signals a `user-error' naming the setting to fix when no executable can
be found."
  (let ((executable (lsp-ltex-plus--server-executable)))
    (unless executable
      (user-error (concat "[lsp-ltex-plus] Cannot find `%s'; install ltex-ls-plus"
                          " or set `lsp-ltex-plus-ls-plus-executable'")
                  lsp-ltex-plus-ls-plus-executable))
    (list executable)))

(defun lsp-ltex-plus--process-environment ()
  "Return the environment to start the server with.
`lsp-ltex-plus-java-path', when set, is passed as `JAVA_HOME', which is
how the `ltex-ls-plus' launcher script picks its Java."
  (let ((java (lsp-ltex-plus--str lsp-ltex-plus-java-path)))
    (if (string-empty-p java)
        process-environment
      (cons (concat "JAVA_HOME=" (directory-file-name (expand-file-name java)))
            process-environment))))

(defun lsp-ltex-plus--make-process (name command root)
  "Start COMMAND as process NAME in directory ROOT and return it.
The standard error buffer is named the way `jsonrpc' expects for a
connection called NAME, which is how the two end up coupled."
  (let ((process-environment (lsp-ltex-plus--process-environment))
        (default-directory root))
    (make-process :name name
                  :command command
                  :connection-type 'pipe
                  :noquery t
                  :stderr (get-buffer-create (format "*%s stderr*" name)))))

(defun lsp-ltex-plus--events-buffer-initargs (size)
  "Return the initargs that cap a connection's events buffer at SIZE bytes.
SIZE nil means unbounded and 0 means no events buffer at all.  jsonrpc
1.0.19, bundled from Emacs 30, configures the buffer through
`:events-buffer-config'; the jsonrpc bundled with Emacs 29 knows only
`:events-buffer-scrollback-size', and refuses the newer initarg as an
invalid slot.  The class is probed for the newer slot rather than the
library for a version, since the library does not say which it is."
  (if (memq '-events-buffer-config
            (mapcar #'eieio-slot-descriptor-name
                    (eieio-class-slots 'jsonrpc-connection)))
      (list :events-buffer-config (list :size size :format 'full))
    (list :events-buffer-scrollback-size size)))

(defun lsp-ltex-plus--events-buffer-size ()
  "Return the size to keep the events buffer at for a new connection.
The events buffer is the record of everything that went over the wire.
It is unbounded under `lsp-ltex-plus-debug' and otherwise kept to a
size that still holds a useful tail for a bug report."
  (if lsp-ltex-plus-debug nil 2000000))

(defconst lsp-ltex-plus--client-capabilities
  '(:workspace (:applyEdit :json-false
                :workspaceEdit (:documentChanges t)
                :didChangeConfiguration (:dynamicRegistration :json-false)
                :configuration t
                :workspaceFolders t)
    :textDocument (:synchronization (:dynamicRegistration :json-false
                                     :willSave :json-false
                                     :willSaveWaitUntil :json-false
                                     :didSave t)
                   :publishDiagnostics (:relatedInformation :json-false
                                        :tagSupport (:valueSet [1 2]))
                   :codeAction (:dynamicRegistration :json-false
                                :codeActionLiteralSupport
                                (:codeActionKind
                                 (:valueSet ["quickfix"
                                             "quickfix.ltex.acceptSuggestions"]))))
    :window (:workDoneProgress :json-false)
    :general (:positionEncodings ["utf-16"]))
  "What this client tells the server it can do.
`workspace.configuration' is what allows the server to pull settings
per document, and the code action kinds are the ones `ltex-ls-plus'
advertises.  Positions are UTF-16 code units, the protocol default,
stated explicitly so a future server cannot pick another encoding
without this client noticing.")

(defun lsp-ltex-plus--initialize-params (root)
  "Return the parameters of the `initialize' request for a server at ROOT.
`initializationOptions' carries the one custom capability the server
looks for, `workspaceSpecificConfiguration': without it the server
skips both of its configuration pulls and stops re-checking documents
after the first edit."
  (let ((uri (lsp-ltex-plus--path-to-uri root)))
    `(:processId ,(emacs-pid)
      :clientInfo (:name "lsp-ltex-plus")
      :rootUri ,uri
      :workspaceFolders [(:uri ,uri
                          :name ,(file-name-nondirectory (directory-file-name root)))]
      :capabilities ,lsp-ltex-plus--client-capabilities
      :initializationOptions (:customCapabilities
                              (:workspaceSpecificConfiguration t))
      :trace ,lsp-ltex-plus-trace-server)))

(defun lsp-ltex-plus--start-connection (root)
  "Start `ltex-ls-plus' rooted at ROOT and return the new connection.
The process is started at once; the `initialize' handshake completes
later, on its own, and turns the connection READY.  Sets
`lsp-ltex-plus--connection'."
  (let* ((name "ltex-ls-plus")
         (command (lsp-ltex-plus--server-command))
         (conn (apply #'make-instance
                      'lsp-ltex-plus-connection
                      :name name
                      :root root
                      :process (lambda () (lsp-ltex-plus--make-process name command root))
                      :request-dispatcher #'lsp-ltex-plus--handle-request
                      :notification-dispatcher #'lsp-ltex-plus--handle-notification
                      :on-shutdown #'lsp-ltex-plus--on-shutdown
                      (lsp-ltex-plus--events-buffer-initargs
                       (lsp-ltex-plus--events-buffer-size)))))
    (unless lsp-ltex-plus--start-time
      (setq lsp-ltex-plus--start-time (current-time)))
    (setq lsp-ltex-plus--connection conn)
    (lsp-ltex-plus--log "Started %S in %s" command root)
    (jsonrpc-async-request
     conn 'initialize (lsp-ltex-plus--initialize-params root)
     :success-fn (lambda (result) (lsp-ltex-plus--on-initialized conn result))
     :error-fn (lambda (err)
                 (lsp-ltex-plus--log "initialize failed: %S" err)
                 (message "[lsp-ltex-plus] ltex-ls-plus refused to initialize: %s"
                          (plist-get err :message))
                 (lsp-ltex-plus--shutdown-connection conn))
     :timeout-fn (lambda ()
                   (message "[lsp-ltex-plus] ltex-ls-plus did not answer within %d s; giving up"
                            lsp-ltex-plus--initialize-timeout)
                   (lsp-ltex-plus--shutdown-connection conn))
     :timeout lsp-ltex-plus--initialize-timeout)
    conn))

(defun lsp-ltex-plus--on-initialized (conn result)
  "Finish the handshake on CONN with the server's `initialize' RESULT.
Records what the server said about itself, sends `initialized', runs
`lsp-ltex-plus--after-initialize-functions' and then the thunks queued
while the server was starting, in the order they were queued."
  (setf (lsp-ltex-plus--connection-capabilities conn) (plist-get result :capabilities)
        (lsp-ltex-plus--connection-server-info conn) (plist-get result :serverInfo))
  (jsonrpc-notify conn 'initialized lsp-ltex-plus--empty-ht)
  (setf (lsp-ltex-plus--connection-ready conn) t)
  (let ((info (lsp-ltex-plus--connection-server-info conn)))
    (lsp-ltex-plus--log "Server initialized: %s %s"
                        (or (plist-get info :name) "<unnamed>")
                        (or (plist-get info :version) "<no version>")))
  (run-hook-with-args 'lsp-ltex-plus--after-initialize-functions conn)
  (let ((thunks (nreverse (lsp-ltex-plus--connection-pending conn))))
    (setf (lsp-ltex-plus--connection-pending conn) nil)
    (dolist (thunk thunks)
      (funcall thunk))))

(defun lsp-ltex-plus--when-ready (conn thunk)
  "Call THUNK once CONN has completed its handshake.
At once if it already has; otherwise THUNK waits for the `initialize'
reply and runs then, after any thunk queued before it."
  (if (lsp-ltex-plus--connection-ready conn)
      (funcall thunk)
    (push thunk (lsp-ltex-plus--connection-pending conn))))

(defun lsp-ltex-plus--live-connection ()
  "Return the session connection if its process is running, else nil."
  (and lsp-ltex-plus--connection
       (jsonrpc-running-p lsp-ltex-plus--connection)
       lsp-ltex-plus--connection))

(defun lsp-ltex-plus--ensure-connection ()
  "Return the session connection, starting the server if none is running.
A freshly started connection is not yet READY; callers that need the
handshake done go through `lsp-ltex-plus--when-ready'."
  (or (lsp-ltex-plus--live-connection)
      (lsp-ltex-plus--start-connection (lsp-ltex-plus--session-root))))

;;;; -- Stopping the server ----------------------------------------------------

(defun lsp-ltex-plus--on-shutdown (conn)
  "Forget CONN once its process has ended, and tell the layers above.
Installed as the connection's `:on-shutdown', so it runs whether the
server was asked to exit or died on its own."
  (lsp-ltex-plus--log "Connection closed")
  (when (eq conn lsp-ltex-plus--connection)
    (setq lsp-ltex-plus--connection nil))
  (run-hook-with-args 'lsp-ltex-plus--after-shutdown-functions conn))

(defun lsp-ltex-plus--shutdown-connection (&optional conn)
  "Stop the server behind CONN, or the session's connection when nil.
Follows the protocol's two steps, the `shutdown' request and the `exit'
notification, and then waits for the process to end; a server that does
not answer `shutdown' is given three seconds before the process is
ended regardless."
  (when-let* ((conn (or conn (lsp-ltex-plus--live-connection))))
    (when (jsonrpc-running-p conn)
      (ignore-errors (jsonrpc-request conn 'shutdown nil :timeout 3))
      (ignore-errors (jsonrpc-notify conn 'exit nil)))
    (jsonrpc-shutdown conn)))

;;;; -- Documents ---------------------------------------------------------------

;; The server knows a document by its URI; this table is the only place
;; that maps a URI back to the buffer holding it.  Owning the table is
;; what makes every later lookup exact: the buffer the server asks about
;; is the one that opened the document, found by the very URI it was
;; opened under, with no file name resolution in between.

(defvar lsp-ltex-plus--documents (make-hash-table :test #'equal)
  "Map from document URI to the buffer that opened it on the server.")

(defvar-local lsp-ltex-plus--document-uri nil
  "The URI this buffer is open under on the server, or nil.")

(defvar-local lsp-ltex-plus--document-version 0
  "The version of this buffer's document last sent to the server.
Incremented on every `didChange', as the protocol requires.")

(defvar-local lsp-ltex-plus--change-timer nil
  "The timer that will send this buffer's pending edits, or nil.
See the Edits section below.")

(defvar-local lsp-ltex-plus--diagnostics nil
  "The diagnostics the server last published for this buffer, as a list.
Each is the protocol's diagnostic object, a plist, untouched; see the
Diagnostics section below for reading positions out of one.")

(defun lsp-ltex-plus--language-id (&optional buffer)
  "Return the LSP language id for BUFFER (default the current buffer).
Read from `lsp-ltex-plus-major-modes'; a mode not listed there is sent
as plain text, which the server checks as prose."
  (or (cadr (assq (buffer-local-value 'major-mode (or buffer (current-buffer)))
                  lsp-ltex-plus-major-modes))
      "plaintext"))

(defun lsp-ltex-plus--buffer-uri (&optional buffer)
  "Return the URI BUFFER (default the current buffer) has or would have.
The URI it is already open under if it is; otherwise the `file://' URI
of the file it visits.  A buffer visiting no file has no URI yet."
  (with-current-buffer (or buffer (current-buffer))
    (or lsp-ltex-plus--document-uri
        (and buffer-file-name
             (lsp-ltex-plus--path-to-uri buffer-file-name)))))

(defun lsp-ltex-plus--buffer-for-uri (uri)
  "Return the live buffer open under URI, or nil.
Nil means one thing: the buffer was killed after the server last heard
of it."
  (when-let* ((buffer (and uri (gethash uri lsp-ltex-plus--documents))))
    (and (buffer-live-p buffer) buffer)))

(defun lsp-ltex-plus--document-text (&optional buffer)
  "Return the text of BUFFER (default the current buffer) as the server sees it.
The whole buffer, narrowing notwithstanding: the server holds the full
document and positions are relative to its start."
  (with-current-buffer (or buffer (current-buffer))
    (save-restriction
      (widen)
      (buffer-substring-no-properties (point-min) (point-max)))))

(defun lsp-ltex-plus--document-open-p (&optional buffer)
  "Return non-nil if BUFFER (default the current buffer) is open on the server."
  (and (buffer-local-value 'lsp-ltex-plus--document-uri (or buffer (current-buffer)))
       t))

(defun lsp-ltex-plus--open-document (&optional buffer)
  "Open BUFFER (default the current buffer) on the server, starting it if needed.
The `didOpen' goes out once the handshake is complete, which may be
later; until then the buffer is not yet in the table.  Opening a buffer
that is already open does nothing."
  (let ((buffer (or buffer (current-buffer))))
    (unless (lsp-ltex-plus--document-open-p buffer)
      (let ((conn (lsp-ltex-plus--ensure-connection)))
        (lsp-ltex-plus--when-ready
         conn
         (lambda ()
           (when (and (buffer-live-p buffer)
                      (not (lsp-ltex-plus--document-open-p buffer)))
             (lsp-ltex-plus--send-did-open conn buffer))))))))

(defun lsp-ltex-plus--send-did-open (conn buffer)
  "Register BUFFER on CONN and send its `didOpen'."
  (with-current-buffer buffer
    (let ((uri (lsp-ltex-plus--buffer-uri buffer)))
      (unless uri
        (error "[lsp-ltex-plus] Buffer %s has no file and cannot be opened yet"
               (buffer-name buffer)))
      (setq lsp-ltex-plus--document-uri uri
            lsp-ltex-plus--document-version 1)
      (puthash uri buffer lsp-ltex-plus--documents)
      (add-hook 'kill-buffer-hook #'lsp-ltex-plus--close-document nil t)
      (add-hook 'after-change-functions #'lsp-ltex-plus--after-change nil t)
      (add-hook 'after-save-hook #'lsp-ltex-plus--after-save nil t)
      (lsp-ltex-plus--log "didOpen %s as %s" (buffer-name buffer) (lsp-ltex-plus--language-id))
      (jsonrpc-notify conn 'textDocument/didOpen
                      (list :textDocument
                            (list :uri uri
                                  :languageId (lsp-ltex-plus--language-id)
                                  :version lsp-ltex-plus--document-version
                                  :text (lsp-ltex-plus--document-text)))))))

(defun lsp-ltex-plus--detach-document ()
  "Forget that the current buffer is open, without telling the server.
Clears the identity, the hooks and any edit still waiting to be sent."
  (when lsp-ltex-plus--change-timer
    (cancel-timer lsp-ltex-plus--change-timer)
    (setq lsp-ltex-plus--change-timer nil))
  (setq lsp-ltex-plus--document-uri nil
        lsp-ltex-plus--document-version 0)
  (remove-hook 'kill-buffer-hook #'lsp-ltex-plus--close-document t)
  (remove-hook 'after-change-functions #'lsp-ltex-plus--after-change t)
  (remove-hook 'after-save-hook #'lsp-ltex-plus--after-save t)
  (when lsp-ltex-plus--diagnostics
    (setq lsp-ltex-plus--diagnostics nil)
    (run-hook-with-args 'lsp-ltex-plus--diagnostics-functions (current-buffer))))

(defun lsp-ltex-plus--close-document (&optional buffer)
  "Close BUFFER (default the current buffer) on the server and forget it.
Safe to call on a buffer that is not open.  The `didClose' is sent only
while the server is still running; after it has gone there is nobody to
tell."
  (let ((buffer (or buffer (current-buffer))))
    (when-let* ((uri (buffer-local-value 'lsp-ltex-plus--document-uri buffer)))
      (with-current-buffer buffer
        (remhash uri lsp-ltex-plus--documents)
        (lsp-ltex-plus--detach-document)
        (when-let* ((conn (lsp-ltex-plus--live-connection)))
          (lsp-ltex-plus--log "didClose %s" (buffer-name buffer))
          (jsonrpc-notify conn 'textDocument/didClose
                          (list :textDocument (list :uri uri))))))))

(defun lsp-ltex-plus--forget-documents (_conn)
  "Drop every document from the table once the server is gone.
On `lsp-ltex-plus--after-shutdown-functions'.  The buffers stay as they
are; a new server will be told about them when they next need one."
  (maphash (lambda (_uri buffer)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (lsp-ltex-plus--detach-document))))
           lsp-ltex-plus--documents)
  (clrhash lsp-ltex-plus--documents))

(add-hook 'lsp-ltex-plus--after-shutdown-functions #'lsp-ltex-plus--forget-documents)

;;;; -- Edits ------------------------------------------------------------------

;; The server advertises full synchronisation: every `didChange' carries
;; the whole text, and the server re-checks the whole document.  What an
;; edit changed is therefore irrelevant; when to send is the only
;; question, and the answer is a debounce.  Each edit restarts a timer of
;; `lsp-ltex-plus-change-delay' seconds, so a burst of typing goes out
;; once, when it pauses.  A plain timer rather than an idle timer: it
;; behaves the same in a batch Emacs, where nothing is ever idle.

(defun lsp-ltex-plus--after-change (&rest _)
  "Note an edit to the current buffer; on `after-change-functions'.
The edit itself is not looked at, see the comment above."
  (when lsp-ltex-plus--document-uri
    (when lsp-ltex-plus--change-timer
      (cancel-timer lsp-ltex-plus--change-timer))
    (setq lsp-ltex-plus--change-timer
          (run-with-timer lsp-ltex-plus-change-delay nil
                          #'lsp-ltex-plus--send-changes (current-buffer)))))

(defun lsp-ltex-plus--send-changes (&optional buffer)
  "Send the text of BUFFER (default the current buffer) to the server now.
Sends nothing when nothing is pending, when the buffer is not open, or
when the server has gone."
  (let ((buffer (or buffer (current-buffer))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when lsp-ltex-plus--change-timer
          (cancel-timer lsp-ltex-plus--change-timer)
          (setq lsp-ltex-plus--change-timer nil)
          (when-let* ((uri lsp-ltex-plus--document-uri)
                      (conn (lsp-ltex-plus--live-connection)))
            (cl-incf lsp-ltex-plus--document-version)
            (lsp-ltex-plus--log "didChange %s v%d" (buffer-name) lsp-ltex-plus--document-version)
            (jsonrpc-notify conn 'textDocument/didChange
                            (list :textDocument
                                  (list :uri uri
                                        :version lsp-ltex-plus--document-version)
                                  :contentChanges
                                  (vector (list :text (lsp-ltex-plus--document-text)))))))))))

(defun lsp-ltex-plus--after-save ()
  "Tell the server the current buffer was saved; on `after-save-hook'.
Any pending edit goes first, so the server checks what was saved.  With
`lsp-ltex-plus-check-frequency' at \"save\" this is what triggers the
check."
  (when-let* ((uri lsp-ltex-plus--document-uri))
    (lsp-ltex-plus--send-changes)
    (when-let* ((conn (lsp-ltex-plus--live-connection)))
      (jsonrpc-notify conn 'textDocument/didSave
                      (list :textDocument (list :uri uri))))))

;;;; -- Diagnostics -------------------------------------------------------------

;; The server pushes diagnostics; nothing here asks for them.  They are
;; kept per buffer exactly as they arrived and handed to whoever
;; registered on the hook -- the flymake backend, later a flycheck
;; checker -- which converts them to what its front-end wants.
;;
;; Positions on the wire are a line and a character offset, the offset
;; counted in UTF-16 code units as the protocol's default and what this
;; client declared.  A character outside the Basic Multilingual Plane,
;; an emoji say, is one Emacs character but two code units; the two
;; conversions below walk the line character by character so that text
;; after such a character is still underlined in the right place.

(defvar lsp-ltex-plus--diagnostics-functions nil
  "Functions called with a buffer whenever its diagnostics change.
Called after a publish from the server has been stored, and after the
diagnostics were cleared because the buffer left the server.")

(defun lsp-ltex-plus--utf16-width (string)
  "Return the length of STRING in UTF-16 code units."
  (let ((units 0))
    (dotimes (i (length string))
      (setq units (+ units (if (> (aref string i) #xFFFF) 2 1))))
    units))

(defun lsp-ltex-plus--position-to-point (position &optional buffer)
  "Return the point in BUFFER (default the current buffer) at the LSP POSITION.
POSITION is a plist of `:line' and `:character'.  A line past the end
of the buffer gives the end of the buffer; a character past the end of
its line gives the end of that line.  Narrowing is ignored."
  (with-current-buffer (or buffer (current-buffer))
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (if (/= 0 (forward-line (plist-get position :line)))
            (point-max)
          (let ((units (plist-get position :character))
                (end (line-end-position)))
            (while (and (> units 0) (< (point) end))
              (setq units (- units (if (> (char-after) #xFFFF) 2 1)))
              (forward-char 1))
            (point)))))))

(defun lsp-ltex-plus--point-to-position (&optional point buffer)
  "Return the LSP position of POINT in BUFFER, both defaulting to the current.
The inverse of `lsp-ltex-plus--position-to-point'; narrowing is ignored."
  (with-current-buffer (or buffer (current-buffer))
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (or point (point)))
        (list :line (1- (line-number-at-pos nil t))
              :character (lsp-ltex-plus--utf16-width
                          (buffer-substring-no-properties (line-beginning-position)
                                                          (point))))))))

(defun lsp-ltex-plus--diagnostic-region (diagnostic &optional buffer)
  "Return (BEG . END), the points DIAGNOSTIC spans in BUFFER.
An empty range is widened to one character where it can be, so that
there is something to underline."
  (let* ((range (plist-get diagnostic :range))
         (beg (lsp-ltex-plus--position-to-point (plist-get range :start) buffer))
         (end (lsp-ltex-plus--position-to-point (plist-get range :end) buffer)))
    (when (= beg end)
      (with-current-buffer (or buffer (current-buffer))
        (setq end (min (1+ end) (save-restriction (widen) (point-max))))))
    (cons beg end)))

(defun lsp-ltex-plus--on-publish-diagnostics (params)
  "Store the diagnostics in PARAMS with their buffer and run the hook.
A publish for a document no buffer holds any more is dropped.  So is
one that names a version older than the buffer's, since a newer check
is already under way and its positions would be off; a publish with no
version is always taken."
  (let ((uri (plist-get params :uri))
        (version (plist-get params :version)))
    (if-let* ((buffer (lsp-ltex-plus--buffer-for-uri uri)))
        (with-current-buffer buffer
          (if (and version (< version lsp-ltex-plus--document-version))
              (lsp-ltex-plus--log "Dropping diagnostics for %s v%s, buffer is at v%d"
                                  (buffer-name) version lsp-ltex-plus--document-version)
            (setq lsp-ltex-plus--diagnostics (append (plist-get params :diagnostics) nil))
            (lsp-ltex-plus--log "%d diagnostics for %s"
                                (length lsp-ltex-plus--diagnostics) (buffer-name))
            (run-hook-with-args 'lsp-ltex-plus--diagnostics-functions buffer)))
      (lsp-ltex-plus--log "Dropping diagnostics for %s, which no buffer holds" uri))))

;;;; -- Configuration -----------------------------------------------------------

;; The server pulls settings before every check, and tags each requested
;; item with the URI of the document it is about to check.  Each item is
;; answered from that document's buffer, which is what gives a project's
;; `.dir-locals.el' its meaning for this client: two projects open at
;; once are checked in their own languages, against their own lists.

(defun lsp-ltex-plus--call-in-document-context (uri fn)
  "Call FN with no arguments, with the buffer open under URI current.
URI resolves to no buffer only when that buffer was killed between the
check starting and the pull arriving.  The server will finish that
check and publish for a document nothing displays, so the answer cannot
be observed; the reply merely has to carry one entry per item.  FN then
runs in a buffer with no file name, which is the plain global
configuration -- never the settings of whichever buffer happens to be
current, and never those of a project root."
  (if-let* ((buffer (lsp-ltex-plus--buffer-for-uri uri)))
      (with-current-buffer buffer (funcall fn))
    (with-temp-buffer (funcall fn))))

(defun lsp-ltex-plus--configuration-section (section)
  "Return the settings for SECTION, read in the current buffer.
SECTION is what the server asked for: nil for everything, which is the
`ltex' object under its key; \"ltex\" for that object itself; a dotted
name such as \"ltex.latex.commands\" for one value inside it.  A section
this client knows nothing about is answered with nil, the protocol's
null."
  (let ((object (lsp-ltex-plus--settings-object)))
    (cond
     ((null section) (list :ltex object))
     ((equal section "ltex") object)
     ((string-prefix-p "ltex." section)
      (let ((value object))
        (dolist (step (cdr (split-string section "\\.")) value)
          (setq value (and (listp value)
                           (plist-get value (intern (concat ":" step))))))))
     (t nil))))

(defun lsp-ltex-plus--answer-workspace-specific-configuration (params)
  "Answer the server's `ltex/workspaceSpecificConfiguration' request PARAMS.
The server's own request, mirroring VS Code's handler: for each item
the four language-keyed maps -- dictionary, disabled rules, enabled
rules, hidden false positives -- as `lsp-ltex-plus--workspace-specific-entry'
builds them in the document's buffer.  Once the client has advertised
the custom capability the server takes these four settings from here
alone and ignores what `workspace/configuration' said about them, so
this reply is what decides which dictionary a document is checked
against."
  (lsp-ltex-plus--log "ltex/workspaceSpecificConfiguration: %S" params)
  (vconcat
   (mapcar (lambda (item)
             (lsp-ltex-plus--call-in-document-context
              (plist-get item :scopeUri)
              #'lsp-ltex-plus--workspace-specific-entry))
           (plist-get params :items))))

(defun lsp-ltex-plus--push-configuration (&optional conn)
  "Send the server the global settings as `workspace/didChangeConfiguration'.
CONN defaults to the session connection; nothing is sent when there is
none.  The push carries the settings as read outside any buffer, which
is all one push can carry: it names no document, so no project's
`.dir-locals.el' can apply.  It is what the server checks a document
against until its first pull, and it is what tells the server to pull
again after a setting changed; the per-document values come back in
the reply to that pull."
  (when-let* ((conn (or conn (lsp-ltex-plus--live-connection))))
    (lsp-ltex-plus--log "Pushing configuration")
    (jsonrpc-notify conn 'workspace/didChangeConfiguration
                    (list :settings
                          (list :ltex (with-temp-buffer
                                        (lsp-ltex-plus--settings-object)))))))

(add-hook 'lsp-ltex-plus--after-initialize-functions #'lsp-ltex-plus--push-configuration)

(defun lsp-ltex-plus--answer-configuration (params)
  "Answer the server's `workspace/configuration' request PARAMS.
PARAMS carries `items', a vector of (scopeUri URI, section SECTION).
The reply is a vector with one entry per item, in order: the server
matches answers to items by position."
  (lsp-ltex-plus--log "workspace/configuration: %S" params)
  (vconcat
   (mapcar (lambda (item)
             (lsp-ltex-plus--call-in-document-context
              (plist-get item :scopeUri)
              (lambda () (lsp-ltex-plus--configuration-section (plist-get item :section)))))
           (plist-get params :items))))

;;;; -- What the server sends --------------------------------------------------

;; Both dispatchers receive the method as an interned symbol.  Requests the
;; server sends about configuration, and the notifications about
;; diagnostics, are answered by the layers above; they add their arms here
;; rather than installing dispatchers of their own, so that one place shows
;; what this client answers.

(defun lsp-ltex-plus--handle-request (_conn method params)
  "Answer the server's request METHOD with PARAMS, or refuse it.
The value returned is the request's result.  An unknown method is
refused with the protocol's own code for that, so the server learns it
asked for something this client does not do."
  (pcase method
    ('workspace/configuration
     (lsp-ltex-plus--answer-configuration params))
    ('ltex/workspaceSpecificConfiguration
     (lsp-ltex-plus--answer-workspace-specific-configuration params))
    ((or 'client/registerCapability 'client/unregisterCapability
         'window/workDoneProgress/create)
     nil)
    ('window/showMessageRequest
     (message "[ltex-ls-plus] %s" (plist-get params :message))
     nil)
    (_
     (lsp-ltex-plus--log "Refusing unknown request %s" method)
     (jsonrpc-error :code -32601
                    :message (format "Method not found: %s" method)))))

(defun lsp-ltex-plus--handle-notification (_conn method params)
  "Act on the server's notification METHOD with PARAMS."
  (pcase method
    ('textDocument/publishDiagnostics
     (lsp-ltex-plus--on-publish-diagnostics params))
    ('window/logMessage
     (lsp-ltex-plus--log "server: %s" (plist-get params :message)))
    ('window/showMessage
     (message "[ltex-ls-plus] %s" (plist-get params :message)))
    ((or '$/progress 'telemetry/event)
     nil)
    (_
     (lsp-ltex-plus--log "Ignoring unknown notification %s" method))))

(provide 'lsp-ltex-plus-conn)
;;; lsp-ltex-plus-conn.el ends here
