# The checks of CI, one target each. They need `agentica` on PATH (the release
# pinned in .github/workflows/ci.yml) and python3.

JOBS ?= 4

# Named so that nothing else under the root is read.
SOURCES = agc_redis_s.agc src test

.PHONY: install check fmt-check lint purity test integration

# Fetches the packages of agentica.lock into deps/.
install:
	@agentica install

check: purity install
	@agentica check $(SOURCES)
	@$(MAKE) --no-print-directory lint

lint:
	@agentica lint --strict $(SOURCES)

fmt-check:
	@agentica fmt --check $(SOURCES)

# Every folder of src/ except src/server is pure (tools/check_purity.py).
purity:
	@python3 tools/check_purity.py

test: install
	@agentica test --jobs $(JOBS) test
	@cd tools && python3 -m unittest -q

# The tests start and stop their own server processes.
integration:
	@cd integration && python3 -m unittest discover -s . -v
