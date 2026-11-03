;;; ltex-plus-doctor-test.el --- The doctor buffer -*- lexical-binding: t; -*-

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:

;; The doctor is a buffer the package checks like any other, so most of
;; what it does is already covered elsewhere.  What is asserted here is
;; what is particular to it: that the report is disabled and the samples
;; are not, that a finding is counted against the section it lands in
;; and no other, and -- the point of the whole design -- that a section
;; with nothing in it never reads as a section with nothing wrong.
;;
;; The real server is not needed for any of that; the one test that
;; wants a document opened uses the fake.

;;; Code:

(require 'ltex-plus-test-helper)
(require 'ltex-plus-fake-server)
(require 'lsp-ltex-plus-doctor)

(defmacro ltex-plus-doctor-test--with-report (&rest body)
  "Run BODY in a filled doctor buffer, with no server and no checking."
  (declare (indent 0) (debug t))
  `(let ((buffer (generate-new-buffer "*ltex-plus-doctor-test*")))
     (unwind-protect
         (with-current-buffer buffer
           (lsp-ltex-plus-doctor-mode)
           (lsp-ltex-plus-doctor--fill)
           ,@body)
       (with-current-buffer buffer
         (lsp-ltex-plus-doctor--cancel-timer))
       (kill-buffer buffer))))

(defun ltex-plus-doctor-test--pretend-checked ()
  "Say the buffer is being checked, without a server to check it.
The status of a section depends on it: with the mode off the honest
answer is that nothing was sent, which is a different test."
  (setq-local lsp-ltex-plus-mode t)
  (lsp-ltex-plus-doctor--show-status))

(defun ltex-plus-doctor-test--status-string (label)
  "Return the status of the section called LABEL, faces and all."
  (let ((section (seq-find (lambda (s) (equal (plist-get s :label) label))
                           lsp-ltex-plus-doctor--sections)))
    (or (overlay-get (plist-get section :overlay) 'after-string) "")))

(defun ltex-plus-doctor-test--status (label)
  "Return the status shown for the section called LABEL."
  (let ((section (seq-find (lambda (s) (equal (plist-get s :label) label))
                           lsp-ltex-plus-doctor--sections)))
    (substring-no-properties
     (or (overlay-get (plist-get section :overlay) 'after-string) ""))))

(defun ltex-plus-doctor-test--diagnostic-on (text)
  "Return a diagnostic covering the first occurrence of TEXT in the buffer."
  (save-excursion
    (goto-char (point-min))
    (search-forward text)
    (list :message (format "%s is wrong" text)
          :severity 1
          :range (list :start (lsp-ltex-plus--point-to-position (match-beginning 0))
                       :end (lsp-ltex-plus--point-to-position (match-end 0))))))

;;;; -- What the server is and is not asked to check ----------------------------

(ert-deftest ltex-plus-doctor-test-the-report-is-not-checked ()
  "The report sits under a magic comment that disables checking.
It is paths, symbols and version strings; offering it as prose would
flag the package's own name and teach the user nothing."
  (ltex-plus-doctor-test--with-report
    (goto-char (point-min))
    (should (looking-at-p "# LTeX: enabled=false$"))
    ;; And exactly one comment turns it back on, on the first sample.
    (should (= 1 (count-matches "^# LTeX: enabled=true")))
    (should (< (save-excursion (goto-char (point-min))
                               (search-forward "* Environment"))
               (save-excursion (goto-char (point-min))
                               (search-forward "# LTeX: enabled=true"))))))

(ert-deftest ltex-plus-doctor-test-each-sample-names-its-language ()
  "Every sample is preceded by a magic comment naming its language."
  (ltex-plus-doctor-test--with-report
    (dolist (section lsp-ltex-plus-doctor--sections)
      (goto-char (point-min))
      (should (search-forward (format "language=%s" (plist-get section :language))
                              nil t)))))

;;;; -- Reporting what came back ------------------------------------------------

(ert-deftest ltex-plus-doctor-test-a-finding-counts-for-its-own-section ()
  "A finding is counted against the section it falls in, and no other.
The sections are inserted one after another, so an end marker that
moved with later insertions would let the first section swallow every
finding in the buffer."
  (ltex-plus-doctor-test--with-report
    (ltex-plus-doctor-test--pretend-checked)
    (setq lsp-ltex-plus--diagnostics
          (list (ltex-plus-doctor-test--diagnostic-on "spellling")
                (ltex-plus-doctor-test--diagnostic-on "Rechtschreibfelern")))
    (lsp-ltex-plus-doctor--on-diagnostics (current-buffer))
    (should (equal (ltex-plus-doctor-test--status "English")
                   "\n  Success: spelling mistakes were detected in this \
paragraph.\n"))
    (should (string-match-p "Success" (ltex-plus-doctor-test--status "German")))
    (should (string-match-p "waiting"
                            (ltex-plus-doctor-test--status "French")))))

(ert-deftest ltex-plus-doctor-test-nothing-yet-never-reads-as-nothing-wrong ()
  "A section with no findings says why, and never that it is clean.
Every sample is wrong on purpose, so an empty section means the answer
has not come -- or is not coming.  Saying nothing would read as a pass
and send the user looking for a problem that is not there."
  (ltex-plus-doctor-test--with-report
    (ltex-plus-doctor-test--pretend-checked)
    (should (string-match-p "Waiting" (ltex-plus-doctor-test--status "German")))
    (lsp-ltex-plus-doctor--give-up (current-buffer))
    (let ((status (ltex-plus-doctor-test--status "German")))
      (should (string-match-p "No answer" status))
      (should (string-match-p "lsp-ltex-plus-java-max-heap" status)))))

(ert-deftest ltex-plus-doctor-test-an-unchecked-buffer-says-so ()
  "With the mode off, the sections say nothing was sent.
The mode declines when no server can be found; a buffer that then said
it was waiting would be waiting for something nobody sent."
  (ltex-plus-doctor-test--with-report
    (should-not lsp-ltex-plus-mode)
    (should (string-match-p "nothing was sent to the server"
                            (substring-no-properties
                             (overlay-get lsp-ltex-plus-doctor--overall
                                          'after-string))))
    (should (string-match-p "Not checked"
                            (ltex-plus-doctor-test--status "French")))))

(ert-deftest ltex-plus-doctor-test-the-timing-is-for-the-whole-check ()
  "One timing, on the samples' heading, not one per section.
The server checks the whole document and publishes once, so a
per-section time would be the same number repeated.  No count anywhere:
how many mistakes LanguageTool reports depends on the account behind
the server."
  (ltex-plus-doctor-test--with-report
    (ltex-plus-doctor-test--pretend-checked)
    (setq lsp-ltex-plus--diagnostics
          (list (ltex-plus-doctor-test--diagnostic-on "spellling")))
    (lsp-ltex-plus-doctor--on-diagnostics (current-buffer))
    (should (string-match-p
             "checked in [0-9.]+ s"
             (substring-no-properties
              (overlay-get lsp-ltex-plus-doctor--overall 'after-string))))
    (should (string-match-p "Success" (ltex-plus-doctor-test--status
                                      "English")))))

(ert-deftest ltex-plus-doctor-test-a-refresh-leaves-other-overlays-alone ()
  "Writing the report again deletes the doctor's overlays and no others.
The buffer is an org buffer with a diagnostics front-end on it and
whatever else the user runs in org.  `org-num-mode' stands for all of
them here: it keeps a list of the overlays it made, and a blanket
`remove-overlays' leaves that list full of dead ones, after which the
next change to the buffer fails with a nil position -- in a backtrace
that names nothing of ours."
  (require 'org-num)
  (ltex-plus-doctor-test--with-report
    (org-num-mode 1)
    (should (> (length org-num--overlays) 0))
    (cl-flet ((ours ()
                (seq-count (lambda (overlay)
                             (overlay-get overlay 'lsp-ltex-plus-doctor))
                           (overlays-in (point-min) (point-max)))))
      (let ((theirs (length org-num--overlays))
            (mine (ours)))
        (should (> mine (length lsp-ltex-plus-doctor--sections)))
        (lsp-ltex-plus-doctor--fill)
        (should (= theirs (seq-count #'overlay-start
                                     (append org-num--overlays nil))))
        ;; And ours are replaced, not accumulated.
        (should (= mine (ours)))))))

(ert-deftest ltex-plus-doctor-test-the-states-are-a-traffic-light ()
  "Answered is `success\=', still waiting is `warning\=', failed is `error\='.
Named faces, so a theme decides the colours; what is pinned here is
which of the three a state belongs to -- a failed check must not be
painted the same as one that is merely slow."
  (cl-flet ((face-of (label)
              ;; The status opens with an unpropertized blank line, so
              ;; the face starts where the sentence does.
              (let ((status (ltex-plus-doctor-test--status-string label)))
                (get-text-property
                 (or (next-single-property-change 0 'face status) 0)
                 'face status))))
    (ltex-plus-doctor-test--with-report
      ;; Never sent: red.
      (should (eq (face-of "German") 'error))
      (ltex-plus-doctor-test--pretend-checked)
      ;; Sent, no answer yet: amber, and the normal state of a cold
      ;; server for a few seconds.
      (should (eq (face-of "German") 'warning))
      ;; Given up on: red, because the heap it names needs raising.
      (lsp-ltex-plus-doctor--give-up (current-buffer))
      (should (eq (face-of "German") 'error))
      ;; Answered: green.
      (setq lsp-ltex-plus--diagnostics
            (list (ltex-plus-doctor-test--diagnostic-on "Rechtschreibfelern")))
      (lsp-ltex-plus-doctor--on-diagnostics (current-buffer))
      (should (eq (face-of "German") 'success)))))

(ert-deftest ltex-plus-doctor-test-the-version-verdict-is-coloured ()
  "The minimum-version row says whether the requirement is satisfied.
Green when it is, red when it is not and the server was stopped for it,
amber when it is not and the user waived the check -- a server kept in
spite of the warning is a decision, not a fault."
  (cl-flet ((verdict (version enforced)
              (cl-letf (((symbol-function 'lsp-ltex-plus--live-connection)
                         (lambda () 'connection))
                        ((symbol-function 'lsp-ltex-plus--connection-server-info)
                         (lambda (_) (list :name "ltex-ls-plus" :version version)))
                        (lsp-ltex-plus-require-minimum-server-version enforced))
                (let ((row (cdr (assoc "Minimum version"
                                       (lsp-ltex-plus-doctor--server-line)))))
                  (cons (get-text-property 10 'face row) row)))))
    (pcase-let ((`(,face . ,text) (verdict "19.0.0" t)))
      (should (eq face 'success))
      (should (string-match-p "requirement satisfied" text)))
    (pcase-let ((`(,face . ,text) (verdict "18.0.0" t)))
      (should (eq face 'error))
      (should (string-match-p "stopped" text)))
    (pcase-let ((`(,face . ,text) (verdict "18.0.0" nil)))
      (should (eq face 'warning))
      (should (string-match-p "used anyway" text)))))

(ert-deftest ltex-plus-doctor-test-the-open-documents-are-named-and-capped ()
  "The row names the documents on the server, five, and counts the rest.
A reader comes to this row asking whether the file they are writing is
being checked; a bare number cannot answer that, and fifty names would
bury the rest of the report."
  (let ((lsp-ltex-plus--documents (make-hash-table :test #'equal))
        (buffers nil))
    (unwind-protect
        (progn
          (dotimes (i 7)
            (let ((buffer (generate-new-buffer (format "doc-%d" i))))
              (push buffer buffers)
              (puthash (format "uri-%d" i) buffer lsp-ltex-plus--documents)))
          (let* ((value (lsp-ltex-plus-doctor--documents-value))
                 (lines (split-string value "\n")))
            (should (equal (car lines) "7"))
            (should (= 5 (seq-count (lambda (line)
                                      (string-prefix-p "    - [[ltex-buffer:doc-"
                                                       line))
                                    lines)))
            ;; Sorted, so writing the report again keeps the order.
            (should (equal (nth 1 lines) "    - [[ltex-buffer:doc-0][doc-0]]"))
            (should (string-match-p "and 2 more" value))))
      (mapc #'kill-buffer buffers))))

(ert-deftest ltex-plus-doctor-test-the-settings-are-hidden-until-asked-for ()
  "Each value names the setting behind it, and `v\=' shows or hides it.
Hidden by default: a reader wants to know what the client found, and
only sometimes which variable to change.  The text is there either way,
so copying a row copies the setting's name with it."
  (ltex-plus-doctor-test--with-report
    (should lsp-ltex-plus-doctor--options-hidden)
    (should (memq 'lsp-ltex-plus-doctor-options buffer-invisibility-spec))
    ;; The name is in the buffer, under an overlay that hides it.
    (goto-char (point-min))
    (should (search-forward "~lsp-ltex-plus-language~" nil t))
    (should (seq-some (lambda (overlay)
                        (eq (overlay-get overlay 'invisible)
                            'lsp-ltex-plus-doctor-options))
                      (overlays-in (point-min) (point-max))))
    (lsp-ltex-plus-doctor-toggle-options)
    (should-not lsp-ltex-plus-doctor--options-hidden)
    (should-not (memq 'lsp-ltex-plus-doctor-options buffer-invisibility-spec))
    (lsp-ltex-plus-doctor-toggle-options)
    (should (memq 'lsp-ltex-plus-doctor-options buffer-invisibility-spec))))

(ert-deftest ltex-plus-doctor-test-a-letter-is-a-command-only-in-the-report ()
  "`g\=' acts in the report and types itself in an example.
The mode derives from `org-mode\=', so the buffer is editable; binding
plain letters would otherwise take three keys away from anyone trying
the checker on the samples."
  (ltex-plus-doctor-test--with-report
    (goto-char (point-min))
    (should (get-text-property (point) 'lsp-ltex-plus-doctor-report))
    (goto-char (marker-position
                (plist-get (car lsp-ltex-plus-doctor--sections) :beg)))
    (should-not (get-text-property (point) 'lsp-ltex-plus-doctor-report))
    ;; The example takes an edit -- that is the point of it ...
    (insert "x")
    (should (looking-back "x" 1))
    (delete-char -1)
    ;; ... and the report refuses one.  Not at `point-min': Emacs always
    ;; allows an insertion there, since no character precedes it.
    (goto-char (point-min))
    (search-forward "Executable")
    (should-error (insert "x") :type 'text-read-only)))

(ert-deftest ltex-plus-doctor-test-a-project-s-settings-reach-the-report ()
  "Called inside a project, the doctor reports that project's settings.
The buffer visits no file, so Emacs applies no directory-local values
to it by itself -- but a reader who runs the doctor inside a project is
asking about that project, and the report then shows the settings the
project's own buffers are checked with."
  (let* ((directory (file-name-as-directory (make-temp-file "ltex-doctor-" t)))
         (buffer (generate-new-buffer "*ltex-plus-doctor-project*"))
         (enable-local-variables :all))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name ".dir-locals.el" directory)
            (insert "((nil . ((lsp-ltex-plus-language . \"de-DE\"))))\n"))
          (with-current-buffer buffer
            (setq default-directory directory)
            (lsp-ltex-plus-doctor-mode)
            (lsp-ltex-plus-doctor--fill)
            (should (equal lsp-ltex-plus-language "de-DE"))
            ;; Called again from a directory with no settings of its
            ;; own, the report is about that directory: the buffer is
            ;; reused, so the values of the last one have to go.
            (setq default-directory temporary-file-directory)
            (lsp-ltex-plus-doctor--fill)
            (should (equal lsp-ltex-plus-language
                           (default-value 'lsp-ltex-plus-language)))
            (should-not (local-variable-p 'lsp-ltex-plus-language))
            (lsp-ltex-plus-doctor--cancel-timer)))
      (kill-buffer buffer)
      (delete-directory directory t))))

(ert-deftest ltex-plus-doctor-test-java-home-says-where-it-came-from ()
  "JAVA_HOME is reported whether Emacs set it or merely inherited it.
The client exports JAVA_HOME only for its own setting; everything else
in the environment reaches the server untouched, so a reader with
JAVA_HOME in their shell would be told \"not set\" about a variable
that is very much set."
  (let ((process-environment (copy-sequence process-environment)))
    (setenv "JAVA_HOME" "/opt/from-the-shell")
    (let ((lsp-ltex-plus-java-home nil))
      (should (equal (lsp-ltex-plus-doctor--java-home)
                     '("/opt/from-the-shell" . environment))))
    (let ((lsp-ltex-plus-java-home "/opt/from-the-setting/"))
      (should (equal (lsp-ltex-plus-doctor--java-home)
                     '("/opt/from-the-setting" . setting))))
    (setenv "JAVA_HOME" nil)
    (let ((lsp-ltex-plus-java-home nil))
      (should-not (lsp-ltex-plus-doctor--java-home)))))

(ert-deftest ltex-plus-doctor-test-undo-cannot-unmake-the-report ()
  "Undo reaches a reader's own edit and stops there.
Writing the report is an edit like any other as far as Emacs is
concerned, so without this the first `undo\=' in an example takes the
page apart instead of the word just typed."
  (ltex-plus-doctor-test--with-report
    (should (null buffer-undo-list))
    (ltex-plus-doctor-test--pretend-checked)
    (goto-char (marker-position
                (plist-get (car lsp-ltex-plus-doctor--sections) :beg)))
    (insert "typo ")
    (should (string-match-p "typo " (buffer-string)))
    (primitive-undo 1 buffer-undo-list)
    (should-not (string-match-p "typo " (buffer-string)))
    ;; And the report is still there to be read.
    (should (string-match-p "\\* Examples" (buffer-string)))
    (should (string-match-p "Minimum version" (buffer-string)))))

(ert-deftest ltex-plus-doctor-test-the-account-is-reported-without-being-shown ()
  "The report says an account is configured, never what it is.
The buffer is written to be pasted into a bug report, so an API key or
an address printed here is a key or an address published.  Whether the
checking is done by the bundled LanguageTool or over the network does
belong in it: the same document comes back with different mistakes."
  (let ((lsp-ltex-plus-lt-server-uri "https://api.languagetoolplus.com")
        (lsp-ltex-plus-lt-username "someone@example.org")
        (lsp-ltex-plus-lt-api-key "s3cret"))
    (let ((rows (lsp-ltex-plus-doctor--languagetool-line)))
      (should (string-match-p "api.languagetoolplus.com"
                              (cdr (assoc "Checker" rows))))
      (should (string-match-p "username and an API key"
                              (cdr (assoc "Account" rows))))
      (dolist (row rows)
        (should-not (string-match-p "s3cret" (cdr row)))
        (should-not (string-match-p "someone@example.org" (cdr row))))))
  ;; Credentials that cannot be used say so; none at all says nothing.
  (let ((lsp-ltex-plus-lt-server-uri nil)
        (lsp-ltex-plus-lt-username "someone@example.org")
        (lsp-ltex-plus-lt-api-key nil))
    (should (string-match-p
             "unused" (cdr (assoc "Account"
                                  (lsp-ltex-plus-doctor--languagetool-line))))))
  (let ((lsp-ltex-plus-lt-server-uri nil)
        (lsp-ltex-plus-lt-username nil)
        (lsp-ltex-plus-lt-api-key nil))
    (should-not (string-match-p
                 "unused" (cdr (assoc "Account"
                                      (lsp-ltex-plus-doctor--languagetool-line)))))))

(ert-deftest ltex-plus-doctor-test-the-offline-fallback-is-reported ()
  "The report says whether the offline fallback is on.
It is unused without a server URI, and the report says so."
  (let ((lsp-ltex-plus-lt-server-uri "https://api.languagetoolplus.com")
        (lsp-ltex-plus-lt-offline-fallback t))
    (let ((row (cdr (assoc "Offline fallback"
                           (lsp-ltex-plus-doctor--languagetool-line)))))
      (should (string-prefix-p "on" row))
      (should-not (string-match-p "unused" row))))
  (let ((lsp-ltex-plus-lt-server-uri nil)
        (lsp-ltex-plus-lt-offline-fallback t))
    (should (string-match-p
             "unused" (cdr (assoc "Offline fallback"
                                  (lsp-ltex-plus-doctor--languagetool-line))))))
  (let ((lsp-ltex-plus-lt-offline-fallback nil))
    (should (string-prefix-p
             "off" (cdr (assoc "Offline fallback"
                               (lsp-ltex-plus-doctor--languagetool-line)))))))

(ert-deftest ltex-plus-doctor-test-the-log-file-is-the-one-being-written ()
  "The report resolves the log file the running server actually writes.
`${PID}\=' and a directory name are both filled in by the server, so
neither can be resolved before there is one -- and once there is, the
reader wants the file, not the pattern."
  (let* ((process (start-process "ltex-plus-doctor-test" nil "sleep" "30"))
         (pid (process-id process))
         (directory (file-name-as-directory (make-temp-file "ltex-log-" t))))
    (unwind-protect
        (cl-letf (((symbol-function 'lsp-ltex-plus--live-connection)
                   (lambda () 'connection))
                  ((symbol-function 'jsonrpc--process) (lambda (_) process)))
          (let ((lsp-ltex-plus-server-log-file
                 (expand-file-name "ltex-${PID}.log" directory)))
            (should (equal (lsp-ltex-plus-doctor--server-log-file)
                           (expand-file-name (format "ltex-%d.log" pid)
                                             directory))))
          ;; A directory: the server names the file after itself inside it.
          (let ((lsp-ltex-plus-server-log-file directory))
            (should (equal (lsp-ltex-plus-doctor--server-log-file)
                           (expand-file-name (format "ltex-ls-%d.log" pid)
                                             directory)))))
      (delete-process process)
      (delete-directory directory t))
    ;; With no server there is no process id, so nothing to resolve.
    (let ((lsp-ltex-plus-server-log-file "/tmp/ltex-${PID}.log"))
      (should-not (lsp-ltex-plus-doctor--server-log-file)))))

;;;; -- On a server -------------------------------------------------------------

(ert-deftest ltex-plus-doctor-test-the-document-is-opened-as-org ()
  "The doctor buffer is opened on the server, once, as an org document.
The mode derives from `org-mode' and is not in the mode table, so this
is also the end-to-end check that the id is inherited rather than
registered as plain text."
  (ltex-plus-fake-with-connection
    (let ((inhibit-message t)
          (lsp-ltex-plus-idle-delay 0.1)
          (table (copy-sequence lsp-ltex-plus-major-modes)))
      (unwind-protect
          (progn
            (lsp-ltex-plus-doctor)
            (ltex-plus-fake-wait-for
             (lambda () (ltex-plus-fake-received 'textDocument/didOpen)))
            (let ((params (car (ltex-plus-fake-received 'textDocument/didOpen))))
              (should (equal (plist-get (plist-get params :textDocument) :languageId)
                             "org")))
            (should (equal table lsp-ltex-plus-major-modes))
            (with-current-buffer lsp-ltex-plus-doctor-buffer-name
              (should lsp-ltex-plus-mode)
              (should lsp-ltex-plus-check-fileless-buffers)
              (should (local-variable-p 'lsp-ltex-plus-check-fileless-buffers))
              ;; Writing the report again is an edit, not a second
              ;; document: the server is told the text changed.
              (lsp-ltex-plus-doctor-refresh)
              (should (= 1 (hash-table-count lsp-ltex-plus--documents)))))
        (when (get-buffer lsp-ltex-plus-doctor-buffer-name)
          (kill-buffer lsp-ltex-plus-doctor-buffer-name))))))

(provide 'ltex-plus-doctor-test)
;;; ltex-plus-doctor-test.el ends here
