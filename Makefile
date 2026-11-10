# The checks of CI, one target each. They need `agentica` on PATH (the release
# pinned in .github/workflows/ci.yml).

JOBS ?= 4

# Named so that nothing else under the root is read.
SOURCES = agc_redis_s.agc src test

# The folders of the pure core: no I/O, no clock, no tasks (AGENTS.md).
PURE = src/resp src/store src/commands
IMPURE = \b(File|Dir|Path|System|Process|IO|TCP|TLS|Socket|Time|Random|Task|Channel|ATS|Profile|puts|print)\b|from "[./]*/?server/

.PHONY: check fmt-check lint purity test integration

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

# Starts the server on a free port (`--port 0`) and talks to it over a raw
# socket. The tests start and stop their own server processes.
integration:
	@cd integration && python3 -m unittest discover -s . -v
