;;; lsp-ltex-plus-actions.el --- Code actions: asking, choosing, applying -*- lexical-binding: t; -*-

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Keywords: lsp, grammar, spelling, convenience
;; URL: https://github.com/ltex-plus/emacs-ltex-plus

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.

;;; Commentary:
;;
;; What happens when the user asks what can be done about an underline.
;; The server is asked for the code actions at point, or over the region,
;; with the diagnostics found there as context; the titles are offered in
;; a `completing-read'; and the chosen action is carried out here.
;;
;; `ltex-ls-plus' returns two shapes of action.  A suggestion to replace
;; text carries a `WorkspaceEdit', applied to the buffer.  The other three
;; -- add a word to the dictionary, disable a rule, hide a false positive
;; -- carry a command the server never expects to receive back: they are
;; handled entirely on this side, by writing to one of the four lists and
;; telling the server its configuration changed.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'jsonrpc)
(require 'lsp-ltex-plus-settings)
(require 'lsp-ltex-plus-conn)

;;;; -- Asking the server -------------------------------------------------------

(defun lsp-ltex-plus--diagnostics-in (beg end &optional buffer)
  "Return the stored diagnostics of BUFFER that touch the region BEG..END.
BUFFER defaults to the current buffer.  When BEG and END are the same
position, the diagnostics whose text contains it, the end of the text
included -- point just after a flagged word still counts as being on
it.  These are what the server is given as the context of a code action
request, and what decides which suggestions it makes."
  (with-current-buffer (or buffer (current-buffer))
    (seq-filter (lambda (diagnostic)
                  (pcase-let ((`(,dbeg . ,dend)
                               (lsp-ltex-plus--diagnostic-region diagnostic)))
                    (if (= beg end)
                        (and (<= dbeg beg) (<= beg dend))
                      (and (< dbeg end) (< beg dend)))))
                lsp-ltex-plus--diagnostics)))

(defun lsp-ltex-plus--request-code-actions (beg end)
  "Return the code actions the server offers for BEG..END in the current buffer.
A list of the protocol's code action objects, possibly empty.  Waits
for the reply: the server answers from the check it has already done,
so this is quick.  Signals a `user-error' in a buffer that is not open
on a running server."
  (let ((conn (lsp-ltex-plus--live-connection))
        (uri lsp-ltex-plus--document-uri))
    (unless (and conn uri)
      (user-error "[lsp-ltex-plus] This buffer is not being checked"))
    (append (jsonrpc-request
             conn 'textDocument/codeAction
             (list :textDocument (list :uri uri)
                   :range (list :start (lsp-ltex-plus--point-to-position beg)
                                :end (lsp-ltex-plus--point-to-position end))
                   :context (list :diagnostics
                                  (vconcat (lsp-ltex-plus--diagnostics-in beg end))))
             :timeout 10)
            nil)))

;;;; -- Applying an edit ---------------------------------------------------------

;; A replacement suggestion is a `WorkspaceEdit'.  The positions in it are
;; relative to the text the server checked, so every edit is resolved to
;; points before any is applied, and they are applied from the end of the
;; buffer backwards so that no edit moves the text of one still to come.
;; The version the server names must be the version the buffer is at,
;; and nothing may be waiting to be sent: either would mean the positions
;; describe a text the buffer no longer holds.

(defun lsp-ltex-plus--edit-buffer (uri)
  "Return the buffer open under URI, which an edit for URI applies to.
Signals a `user-error' when there is none: the buffer was killed since
the server looked at it, and any other buffer on the same file holds a
text the server never saw."
  (or (lsp-ltex-plus--buffer-for-uri uri)
      (user-error "[lsp-ltex-plus] The edit is for %s, which no buffer holds" uri)))

(defun lsp-ltex-plus--text-edits-by-document (edit)
  "Return the text edits in the `WorkspaceEdit' EDIT, grouped by document.
A list of (URI VERSION . EDITS), one per document, in the order given.
VERSION is the document version the server based the edits on, or nil
where it named none.  Only the `documentChanges' form is read, which is
the one the client asks for and the one `ltex-ls-plus' sends; and only
text edits are accepted: an operation on a file itself -- create,
rename, delete -- is refused with a `user-error', since a grammar
checker has no business sending one."
  (let ((result nil))
    (seq-doseq (change (plist-get edit :documentChanges))
      (if-let* ((document (plist-get change :textDocument)))
          (push (cons (plist-get document :uri)
                      (cons (plist-get document :version)
                            (append (plist-get change :edits) nil)))
                result)
        (user-error "[lsp-ltex-plus] The edit wants to %s a file, which this client does not do"
                    (plist-get change :kind))))
    (nreverse result)))

(defun lsp-ltex-plus--apply-text-edits (buffer edits)
  "Apply the protocol text EDITS to BUFFER as one change.
All positions are resolved first, against the text as it is; the edits
are then applied from the end backwards, and two edits at the same
position keep the order the server gave them, as the protocol requires."
  (with-current-buffer buffer
    (let* ((index -1)
           (resolved
            (mapcar (lambda (edit)
                      (let ((range (plist-get edit :range)))
                        (list (lsp-ltex-plus--position-to-point (plist-get range :start))
                              (lsp-ltex-plus--position-to-point (plist-get range :end))
                              (plist-get edit :newText)
                              (cl-incf index))))
                    edits))
           (ordered (sort resolved
                          (lambda (a b)
                            (or (> (car a) (car b))
                                (and (= (car a) (car b))
                                     (> (nth 3 a) (nth 3 b))))))))
      (atomic-change-group
        (save-excursion
          (pcase-dolist (`(,beg ,end ,text ,_) ordered)
            (goto-char beg)
            (delete-region beg end)
            (insert text)))))))

(defun lsp-ltex-plus--apply-workspace-edit (edit)
  "Apply the `WorkspaceEdit' EDIT to the buffers it names.
Every document is checked before any is touched: each must have a
buffer, be at the version the server named, and have no edit waiting to
be sent.  Returns the number of documents edited."
  (let ((documents (lsp-ltex-plus--text-edits-by-document edit)))
    (pcase-dolist (`(,uri ,version . ,_) documents)
      (let ((buffer (lsp-ltex-plus--edit-buffer uri)))
        (when (or (buffer-local-value 'lsp-ltex-plus--change-timer buffer)
                  (and version
                       (/= version (buffer-local-value 'lsp-ltex-plus--document-version
                                                       buffer))))
          (user-error "[lsp-ltex-plus] %s has changed since the server looked at it; wait for the next check"
                      (buffer-name buffer)))))
    (pcase-dolist (`(,uri ,_ . ,edits) documents)
      (lsp-ltex-plus--apply-text-edits (lsp-ltex-plus--edit-buffer uri) edits))
    (length documents)))

;;;; -- The three commands handled here ------------------------------------------

;; Adding a word, disabling a rule and hiding a false positive arrive as
;; commands, but the server never expects to receive them back: they are
;; the client's to carry out, by writing to one of the four lists and
;; telling the server its configuration changed so that it pulls the lists
;; again.  The three differ only in which list they write to and which key
;; the server used to carry the entries, and the kinds table knows both,
;; so one function handles them all.  Each entry is routed by
;; `lsp-ltex-plus--save-addition', which decides between the global and
;; the project file; the command is passed along because a suggestion
;; split in two by `either-allowing-user-choice' carries the answer on
;; itself.

(defun lsp-ltex-plus--handle-addition-action (command kind)
  "Add the entries COMMAND carries to KIND's list.
COMMAND is the protocol's command object; its first argument holds a
map from language code to entries, under the key the kinds table names
for KIND.  Malformed arguments are reported, not raised: they come from
the server, and a shape change upstream should produce a message rather
than a backtrace mid-edit."
  (let* ((name (plist-get command :command))
         (args (plist-get command :arguments))
         (arg0 (and (vectorp args) (> (length args) 0) (aref args 0)))
         (by-language (and arg0 (plist-get arg0 (lsp-ltex-plus--kind-get kind :argument-key)))))
    (lsp-ltex-plus--log "Action: %s (saving to the %s file)"
                        name (lsp-ltex-plus--addition-target kind command))
    (if (null by-language)
        (message "[lsp-ltex-plus] %s: Malformed arguments %S" name args)
      (while by-language
        (let ((language (substring (symbol-name (pop by-language)) 1))
              (entries (append (pop by-language) nil)))
          (lsp-ltex-plus--save-addition kind language entries command)))))
  (lsp-ltex-plus--push-configuration))

(defun lsp-ltex-plus--execute-command (command)
  "Carry out the protocol COMMAND object, if it is one of ours.
Ours are the three that write to a list; the kinds table says which
list.  Any other command is reported: the server advertises none the
client could send back, so there is nothing else to do with it."
  (let ((name (plist-get command :command)))
    (if-let* ((kind (lsp-ltex-plus--kind-for-command name)))
        (lsp-ltex-plus--handle-addition-action command kind)
      (message "[lsp-ltex-plus] Cannot carry out the command %S" name))))

(defun lsp-ltex-plus--run-action (action)
  "Carry out the code ACTION the user chose.
An action carrying an edit has it applied; one carrying a command has
the command carried out; one carrying both, which the protocol allows,
has the edit applied first."
  (when-let* ((edit (plist-get action :edit)))
    (lsp-ltex-plus--apply-workspace-edit edit))
  (when-let* ((command (plist-get action :command)))
    (lsp-ltex-plus--execute-command command))
  (when (and (null (plist-get action :edit)) (null (plist-get action :command)))
    (message "[lsp-ltex-plus] The action %S does nothing" (plist-get action :title))))

;;;; -- Offering both destinations as separate suggestions ---------------------

;; Under `either-allowing-user-choice', a suggestion that could be saved
;; either way is shown twice -- once saving to this project only, once
;; saving everywhere -- so the choice is made by picking a suggestion
;; rather than by answering a question after picking one.  The two copies
;; differ in their title and in a marker naming the file they save to;
;; the handler reads that marker back.  The menu is this package's own,
;; so there is no second place that could count the suggestions
;; differently, and nothing to advise.

(defun lsp-ltex-plus--suggestion-command (action)
  "Return the command object of code ACTION, or nil when it carries none."
  (let ((command (plist-get action :command)))
    (and (consp command) (keywordp (car command)) command)))

(defun lsp-ltex-plus--command-entries (command key)
  "Return every entry COMMAND carries under KEY, across all languages.
The server groups them by language code; for a title we only care how
many there are and, when there is one, what it says."
  (let* ((args (plist-get command :arguments))
         (arg0 (and (vectorp args) (> (length args) 0) (aref args 0)))
         (by-language (and arg0 (plist-get arg0 key)))
         (entries nil))
    (while by-language
      (pop by-language)
      (setq entries (append entries (append (pop by-language) nil))))
    entries))

(defun lsp-ltex-plus--suggestion-title (kind command target)
  "Title for the TARGET variant of a KIND suggestion carried by COMMAND.
TARGET is the string \"global\" or \"project\".

The title is composed here rather than derived from the one the server
sent, because that one is localised -- \"Add \\='x\\=' to dictionary\" in
English, \"\\='x\\=' zum Wörterbuch hinzufügen\" in German -- and there is
no reliable place to insert the scope into it.  The cost is that these
two entries read in English whatever locale the server is speaking;
every other suggestion in the list, this one included when it is not
split, still comes through in the server\\='s own words."
  (let ((where (if (equal target "project") "project" "global")))
    (pcase kind
      ('dictionary
       (let ((words (lsp-ltex-plus--command-entries command :words)))
         (if (= (length words) 1)
             (format "Add '%s' to %s dictionary" (car words) where)
           (format "Add %d words to %s dictionary" (length words) where))))
      ('disabled-rules
       (if (equal where "project")
           "Disable rule for this project"
         "Disable rule globally"))
      ('hidden-false-positives
       (if (equal where "project")
           "Hide false positive for this project"
         "Hide false positive globally"))
      (_ (plist-get command :title)))))

(defun lsp-ltex-plus--suggestion-variant (action command kind target)
  "Return a copy of ACTION for KIND that saves to TARGET.
TARGET is the string \"global\" or \"project\"; COMMAND is ACTION\\='s
command object.  Both plists are copied before being changed, so the
suggestion the server sent is left alone."
  (let* ((tagged (plist-put (copy-sequence command) lsp-ltex-plus--target-marker target))
         (copy (copy-sequence action)))
    (setq copy (plist-put copy :title (lsp-ltex-plus--suggestion-title kind command target)))
    (plist-put copy :command tagged)))

(defun lsp-ltex-plus--split-suggestion (action)
  "Return ACTION as a list of two suggestions, or nil to leave it alone.
Splits only when the user asked to choose each time and this project
actually keeps its own file for the kind of entry ACTION would add --
otherwise there is nothing to choose between."
  (when (eq lsp-ltex-plus-save-additions-to 'either-allowing-user-choice)
    (when-let* ((command (lsp-ltex-plus--suggestion-command action))
                (kind (lsp-ltex-plus--kind-for-command (plist-get command :command))))
      (when (lsp-ltex-plus--project-file-for kind)
        (list (lsp-ltex-plus--suggestion-variant action command kind "project")
              (lsp-ltex-plus--suggestion-variant action command kind "global"))))))

(defun lsp-ltex-plus--expand-suggestions (actions)
  "Return ACTIONS with this package\\='s suggestions split in two where asked.
Anything else passes through as the same object, and the sequence type
is kept."
  (let ((expanded (seq-mapcat (lambda (action)
                                (or (lsp-ltex-plus--split-suggestion action)
                                    (list action)))
                              (append actions nil))))
    (if (vectorp actions) (vconcat expanded) expanded)))

;;;; -- The menu -----------------------------------------------------------------

;; The menu lists the narrowest remedy first and the broadest last: a
;; replacement changes one word; adding it to the dictionary accepts it
;; everywhere; hiding a false positive silences one finding; disabling a
;; rule silences a whole class of them.  The server sends its actions in
;; an order of its own, and completion frameworks sort candidates unless
;; told not to, so both are overridden: the actions are sorted here, and
;; the completion table declares that its order is the order to show.

(defconst lsp-ltex-plus--action-order
  '(nil "_ltex.addToDictionary" "_ltex.hideFalsePositives" "_ltex.disableRules")
  "The order actions are offered in, by the command each carries.
Nil stands for an action with no command, a replacement.  A command not
listed comes after all of these.")

(defun lsp-ltex-plus--action-rank (action)
  "Return ACTION's place in `lsp-ltex-plus--action-order', lower first."
  (let ((command (plist-get (lsp-ltex-plus--suggestion-command action) :command)))
    (or (seq-position lsp-ltex-plus--action-order command #'equal)
        (length lsp-ltex-plus--action-order))))

(defun lsp-ltex-plus--order-actions (actions)
  "Return ACTIONS as a list, sorted by `lsp-ltex-plus--action-rank'.
The sort is stable, so actions of one rank keep the server's order:
the replacements come as the server ranked them, the likeliest first."
  (sort (append actions nil)
        (lambda (a b) (< (lsp-ltex-plus--action-rank a) (lsp-ltex-plus--action-rank b)))))

(defun lsp-ltex-plus--actions-here ()
  "Return the code actions for the region, or for point, split and ordered.
The region when it is active, else the diagnostic at point; either way
what the server offers, with this package's own suggestions expanded
by `lsp-ltex-plus--expand-suggestions' and the whole put in the order
of `lsp-ltex-plus--action-order'."
  (let ((beg (if (use-region-p) (region-beginning) (point)))
        (end (if (use-region-p) (region-end) (point))))
    (lsp-ltex-plus--order-actions
     (lsp-ltex-plus--expand-suggestions (lsp-ltex-plus--request-code-actions beg end)))))

(defun lsp-ltex-plus--completion-table (labels)
  "Return a completion table offering LABELS in the order given.
Its metadata tells the completion framework not to sort them, which
the default `completing-read' and vertico alike would otherwise do,
alphabetically or by history."
  (lambda (string predicate action)
    (if (eq action 'metadata)
        '(metadata (category . lsp-ltex-plus-action)
                   (display-sort-function . identity)
                   (cycle-sort-function . identity))
      (complete-with-action action labels string predicate))))

(defun lsp-ltex-plus--choose-action (actions)
  "Ask the user to pick one of ACTIONS by title, and return it.
Offered in the order given.  Two actions with the same title are told
apart by a number, so the choice is never ambiguous and every action
stays reachable."
  (let ((seen (make-hash-table :test #'equal))
        (candidates nil))
    (dolist (action actions)
      (let* ((title (or (plist-get action :title) "Untitled"))
             (count (cl-incf (gethash title seen 0)))
             (label (if (= count 1) title (format "%s (%d)" title count))))
        (push (cons label action) candidates)))
    (setq candidates (nreverse candidates))
    (cdr (assoc (completing-read "LTeX+ suggestion: "
                                 (lsp-ltex-plus--completion-table (mapcar #'car candidates))
                                 nil t)
                candidates))))

;;;###autoload
(defun lsp-ltex-plus-actions ()
  "Offer what LTeX+ suggests for the region, or for the diagnostic at point.
Pick a replacement to apply it; pick \"Add ... to dictionary\", \"Disable
rule\" or \"Hide false positive\" to have the entry written to the
list -- the project's or the global one, as `lsp-ltex-plus-save-additions-to'
decides or as the two entries offered for it let you choose.  The
protocol calls these code actions; here they are simply actions, since
they act on the server's suggestions and have nothing to do with code."
  (interactive)
  (let ((actions (lsp-ltex-plus--actions-here)))
    (if (null actions)
        (message "[lsp-ltex-plus] Nothing to suggest here")
      (lsp-ltex-plus--run-action (lsp-ltex-plus--choose-action actions)))))

;;;###autoload
(defun lsp-ltex-plus-add-to-dictionary ()
  "Accept the word under point into the dictionary.
The shortest path for the commonest suggestion: the add-to-dictionary
action for the diagnostic at point is carried out without a menu.  When
both the project's and the global dictionary are on offer, the choice
between them is still asked."
  (interactive)
  (let ((offers (seq-filter (lambda (action)
                              (equal (plist-get (plist-get action :command) :command)
                                     "_ltex.addToDictionary"))
                            (lsp-ltex-plus--actions-here))))
    (pcase (length offers)
      (0 (message "[lsp-ltex-plus] No word to add here"))
      (1 (lsp-ltex-plus--run-action (car offers)))
      (_ (lsp-ltex-plus--run-action (lsp-ltex-plus--choose-action offers))))))

(provide 'lsp-ltex-plus-actions)
;;; lsp-ltex-plus-actions.el ends here
