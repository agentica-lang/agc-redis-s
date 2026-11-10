# The checks of CI, one target each. They need `agentica` on PATH (the release
# pinned in .github/workflows/ci.yml).

JOBS ?= 4

# Named so that nothing else under the root is read.
SOURCES = src test

# The folders of the pure core: no I/O, no clock, no tasks (AGENTS.md).
PURE = src/resp src/store src/commands
IMPURE = \b(File|Dir|Path|System|Process|IO|TCP|TLS|Socket|Time|Random|Task|Channel|ATS|Profile|puts|print)\b|from "[./]*/?server/

.PHONY: check fmt-check lint purity test

check: purity
	@agentica check $(SOURCES)
	@$(MAKE) --no-print-directory lint

lint:
	@agentica lint --strict $(SOURCES)

fmt-check:
	@agentica fmt --check $(SOURCES)

# A match is a violation of the pure core.
purity:
	@! grep -rnE '$(IMPURE)' $(PURE) || { echo "purity: the core must not do I/O (AGENTS.md)" >&2; exit 1; }

test:
	@agentica test --jobs $(JOBS) test
