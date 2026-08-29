# Development targets for lsp-ltex-plus.  None of this is needed to *use*
# the package; it is what a maintainer runs before tagging a release.
#
#   make test       run the ERT suite (test/); live tests skip
#   make test-live  the same, with the tests that need a real ltex-ls-plus
#   make live-repl  a daemon with the live fixture loaded, for debugging
#   make compile    byte-compile the two package files, warnings and all
#   make checkdoc   docstring conventions
#   make lint       package-lint, as MELPA runs it
#   make check      all of the above
#   make clean      remove build output
#
# Finding lsp-mode: every target below discovers it the same way the test
# helper does -- a straight.el build tree or a package.el archive under the
# usual directories.  Override with LTEX_PLUS_LOAD_PATH (colon-separated,
# used verbatim) or LTEX_PLUS_STRAIGHT_BUILD (one directory holding a
# package per subdirectory).  EMACS selects the binary.
#
# Running one file, or one test:
#   test/run-tests.sh project
#   test/run-tests.sh -s "\"project-file\""

EMACS ?= emacs
PACKAGE_FILES := lsp-ltex-plus-bootstrap.el lsp-ltex-plus.el

# Puts lsp-mode on `load-path' by reusing the test helper's own search, so
# there is one place that knows where dependencies live.
LOAD_DEPENDENCIES := --eval '(progn \
  (add-to-list (quote load-path) (expand-file-name "test")) \
  (load "ltex-plus-test-helper" nil t))'

.PHONY: all check test test-live live-repl compile checkdoc lint clean

all: check

check: compile checkdoc test

test:
	@test/run-tests.sh

# Starts a real server, so it needs `ltex-ls-plus' on PATH; the live
# tests report as skipped without it, and without this target's opt-in.
# One JVM serves the whole file -- about 20 seconds in total.
test-live:
	@LTEX_PLUS_LIVE=1 test/run-tests.sh

# For working on a live test that fails: a daemon with the fixture
# already loaded, so the session can be poked at from `emacsclient'
# instead of being reconstructed from a batch backtrace.  Kill it with
# `emacsclient -s ltex-test -e "(kill-emacs)"'.
live-repl:
	@LTEX_PLUS_LIVE=1 $(EMACS) --daemon=ltex-test \
	  --eval '(progn \
	            (add-to-list (quote load-path) "$(CURDIR)") \
	            (add-to-list (quote load-path) "$(CURDIR)/test") \
	            (require (quote ltex-plus-live-helper)) \
	            (ltex-plus-live-configure))'
	@echo 'Daemon "ltex-test" is up. Try:'
	@echo '  emacsclient -s ltex-test -e "(ltex-plus-live-open (ltex-plus-live-write \"x.md\" \"He go home.\\n\"))"'
	@echo '  emacsclient -s ltex-test -e "(ltex-plus-live-messages)"'
	@echo '  emacsclient -s ltex-test -e "(kill-emacs)"'

# Byte-compilation is a check in its own right: it is what catches a free
# variable, a call with the wrong number of arguments, or a docstring that
# has drifted from its argument list.  The output goes to a temporary
# directory rather than next to the sources: a stale `.elc' left in the
# tree would shadow the `.el' on the next `make test' and quietly test the
# previous version of the code.
compile:
	@$(EMACS) --batch -Q -L . $(LOAD_DEPENDENCIES) \
	  --eval '(progn \
	            (setq byte-compile-error-on-warn t) \
	            (defvar ltex-out (make-temp-file "ltex-plus-compile-" t)) \
	            (setq byte-compile-dest-file-function \
	                  (lambda (source) \
	                    (expand-file-name \
	                     (concat (file-name-nondirectory source) "c") \
	                     ltex-out))))' \
	  -f batch-byte-compile $(PACKAGE_FILES)

# `checkdoc-file' only reports -- it warns and returns 0.  In batch the
# warnings have already gone to stderr by then; what decides the exit
# status is whether *Warnings* exists at all.  A target that prints its
# findings and then succeeds is one whose findings come back.
checkdoc:
	@$(EMACS) --batch -Q -L . $(LOAD_DEPENDENCIES) \
	  --eval '(progn \
	            (require (quote checkdoc)) \
	            (setq checkdoc-force-docstrings-flag nil) \
	            (dolist (file (list $(foreach f,$(PACKAGE_FILES),"$(f)"))) \
	              (checkdoc-file file)) \
	            (if (get-buffer "*Warnings*") \
	                (kill-emacs 1) \
	              (message "checkdoc: clean")))'

lint:
	@dev/package-lint.sh

# Only ever needed after compiling by hand: `make compile' writes nowhere
# near the source tree.
clean:
	@rm -f $(PACKAGE_FILES:.el=.elc) test/*.elc
