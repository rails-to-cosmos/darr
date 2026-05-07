EMACS   ?= emacs
PACKAGE := darr.el
TESTS   := darr-tests.el

.PHONY: all check test lint compile clean help

all: lint compile test

check: all

help:
	@echo "Targets:"
	@echo "  test     Run ERT tests"
	@echo "  lint     Run package-lint (auto-installs from MELPA if missing)"
	@echo "  compile  Byte-compile with warnings as errors"
	@echo "  clean    Remove .elc files"
	@echo "  all      lint + compile + test (mirrors CI; alias: check)"
	@echo "  help     This message"
	@echo ""
	@echo "Override Emacs with EMACS=...; e.g. make test EMACS=/usr/bin/emacs29"

test:
	$(EMACS) --batch -L . -l $(PACKAGE) -l $(TESTS) -f ert-run-tests-batch-and-exit

lint:
	$(EMACS) --batch \
	  --eval "(require 'package)" \
	  --eval "(add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\"))" \
	  --eval "(package-initialize)" \
	  --eval "(unless (package-installed-p 'package-lint) (package-refresh-contents) (package-install 'package-lint))" \
	  -l package-lint \
	  -f package-lint-batch-and-exit \
	  $(PACKAGE)

compile: clean
	$(EMACS) --batch \
	  --eval "(setq byte-compile-error-on-warn t)" \
	  -L . \
	  -f batch-byte-compile $(PACKAGE)

clean:
	rm -f *.elc
