PREFIX  ?= /usr/local
BINDIR  ?= $(PREFIX)/bin
LIBDIR  ?= $(PREFIX)/lib
ZSHDIR  ?= $(PREFIX)/share/zsh/site-functions
BASHDIR ?= $(PREFIX)/share/bash-completion/completions

.PHONY: install uninstall test clean

install:
	@echo "Installing pbak..."
	install -d $(BINDIR)
	install -d $(LIBDIR)/pbak
	install -d $(ZSHDIR)
	install -d $(BASHDIR)
	install -m 755 bin/pbak $(BINDIR)/pbak
	install -m 644 lib/pbak/*.sh $(LIBDIR)/pbak/
	install -m 644 lib/pbak/*.py $(LIBDIR)/pbak/
	install -m 644 completions/pbak.zsh $(ZSHDIR)/_pbak
	install -m 644 completions/pbak.bash $(BASHDIR)/pbak
	@echo "Done. Run 'pbak setup' to get started."

uninstall:
	@echo "Uninstalling pbak..."
	rm -f $(BINDIR)/pbak
	rm -rf $(LIBDIR)/pbak
	rm -f $(ZSHDIR)/_pbak
	rm -f $(BASHDIR)/pbak
	@echo "Done."

test:
	@echo "Running basic checks..."
	@bash -n bin/pbak && echo "  bin/pbak — syntax OK"
	@for f in lib/pbak/*.sh; do bash -n "$$f" && echo "  $$f — syntax OK"; done
	@for f in lib/pbak/*.py; do python3 -m py_compile "$$f" && echo "  $$f — syntax OK"; done
	@echo "All checks passed."

clean:
	@rm -rf lib/pbak/__pycache__
	@echo "Clean."
