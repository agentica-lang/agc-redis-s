# agc-redis-s

A Redis-compatible in-memory server written in Agentica. A subset of Redis,
memory only: no persistence, no Lua, no cluster, no replication. Planned work
is in the GitHub issues, one milestone per release.

## Map

```text
agc_redis_s.agc      main: options, start the store task, run the accept loop
src/
  resp/              PURE. The RESP2 wire format: reply.agc (the reply
                     types), writer.agc (reply to bytes), reader.agc (bytes
                     to a request, resumable from a `Partial`), stream.agc
                     (the chunks of one connection to requests)
  store/             PURE. The data: value.agc (one variant per data type),
                     keyspace.agc (key to value); one file per data type
                     (hash.agc, list.agc, set.agc, zset.agc) when it lands
  commands/          PURE. command.agc (Command, Call, Outcome and the
                     helpers that build an Outcome), table.agc (all rows),
                     dispatch.agc (name, arity, call the handler), one file
                     per command family
  server/            I/O SHELL: sockets, tasks, the clock. config, accept,
                     connection (reader task), writer (writer task),
                     store_task (owns the data), message, clock
test/functional/     one `<domain>_test.agc` per domain
test/                unit tests of pure logic, the same path as the source;
                     support.agc: `exchange` (request bytes -> reader ->
                     dispatch -> store -> writer -> reply bytes), `request`
integration/         one smoke test of the real binary (Python, standard
                     library only)
tools/               check_purity.py and its tests (Python, standard library)
```

## Rules

- Pure core. Every folder of `src/` except `src/server/` is pure: its files
  never use `File`, `Dir`, `Path`, `System`, `Process`, `IO`, `TCP`, `TLS`,
  `Socket`, `Listener`, `Time`, `Random`, `Task`, `Channel`, `ATS`, `Profile`,
  `LogRegistry`, `HTTP`, `HttpClient`, `HttpServer`, `puts`, `print` (the
  list is in `tools/check_purity.py`, and a test keeps the two the same), and
  never import `src/server/`, a path outside `src/` or an impure `std/`
  module. The time and the client arrive as arguments (`Call.now_ms`,
  `Call.client_id`). `make purity` enforces it; a new folder is checked
  without a change to the tool.
- Error texts are those of Redis, letter by letter. Keys and values are
  `Bytes`, never `String`. A reply built from client bytes (an echoed
  argument) is a `Reply.Error(Bytes)`, never decoded and re-encoded.
- A handler builds its `Outcome` only with the helpers of
  `commands/command.agc` (`reply`, `replies`, `reply_and_close`, `fail`,
  `wrong_arity`), never with the constructor. A later feature adds a field to
  `Outcome` (or `Call`) with a default and a helper in the PR that needs it,
  and no handler changes.
- Tests: as few as needed that still cover the software well; before adding
  one ask what bug it catches that no other test catches. No BDD, no test per
  function, no near-duplicates.
  - Functional tests by domain, in Agentica, in process, no socket:
    `test/functional/<domain>_test.agc` feeds request bytes to `exchange` and
    compares the reply bytes and the keyspace. Plain paths, error texts and
    arity are tested here. The helper calls `commands/session.agc`, the same
    code as the store task; only its read loop mirrors the server's, and the
    smoke test is the check of the real loop.
  - Unit tests only where a pure function has real logic (RESP reader and
    writer, glob, ranges, score formatting).
  - Property tests with `prop` (agentica-lang/packages), from the strings
    issue on, inside the domain they belong to: laws over generated inputs and
    model tests against a plain `Map` or `List`.
  - TCP is tested in the Agentica repo. Here one smoke test (`integration/`)
    proves the binary starts, answers PING, QUIT closes, and SIGTERM frees the
    port. Tests of the server shell will move to the `dock` package (issue
    #17).
- One concern per file. A family past 300 lines becomes a folder
  `commands/<family>/`. Server-wide commands (`INFO`, `CLIENT`, `CONFIG`,
  `DBSIZE`, `FLUSHALL`) get their own file, not `connection.agc`.
- Pull requests are small and iterative: at most 800 changed lines (added
  plus removed, tests and docs counted). If a change would pass 800, split it
  into PRs that each build, pass CI and stand on their own.
- Style: `agentica fmt`, `lint --strict`; imports sorted by path.

## Commands

- `make check` (purity, `agentica check`, lint), `make fmt-check`,
  `make test` (the tests of `test/` and `tools/`), `make integration`
  (the smoke test). `agentica fmt src test`
  fixes formatting.

## How a command travels

```text
request (name, args) -> store task (owns the keyspace; one message at a time,
like Redis) -> commands/dispatch (table lookup, arity check) -> handler
-> Outcome (new keyspace, replies, effects) -> RESP writer -> the client
```

One task owns the data and takes messages from a channel, so no command needs
a lock. Each connection has a reader task and a writer task; the writer drains
an outbox channel of bytes. Replies and later pushes (pub/sub) go through the
outbox, in the order the store task decided. An `Effect` (today only `Close`,
used by `QUIT`) is what the server does after the replies.

## How to add a command

1. Pick the family file in `commands/` (`strings.agc`, `keys.agc`,
   `hashes.agc`, ...). A new family is a new file with `commands()` and one
   line in `commands/table.agc`.
2. Add one `Command` row (lowercase name, arity as Redis counts it with the
   name, handler) and one handler `def name(call: Call) -> Outcome`. Answer
   with the helpers of `command.agc`; the keyspace of the reply is the one
   you pass in the `Call`, or build the new one first.
3. A new data type: a variant in `store/value.agc` and its operations in
   `store/<type>.agc`. Handlers call those; they never reach into `Value`.
4. A case in the functional test of its domain, `test/functional/`.
5. A unit test only if you wrote a pure function with real logic.
6. Mark it in the table of its phase in `README.md`.

## Where later features go

Each feature changes one place, not all. Nothing below exists yet; a PR adds
the field or the folder when it needs it.

- Hashes, lists, sets, sorted sets: `store/<type>.agc` and
  `commands/<type>s.agc`. A handler that mixes types checks the variant of the
  `Value` and answers `WRONGTYPE`.
- Expiry: `Keyspace.get` already takes `now_ms`; a key past its deadline will
  count as missing there, so no caller changes. The clock is read in
  `server/` only, so tests do not sleep.
- Session (transactions, client name, subscribed mode): a pure `Session`
  struct in a new folder `session/`. It is an input (a field of `Call`) and an
  output (a field of `Outcome`): `MULTI` queues in it, and `EXEC` reads it.
- Touched keys: `WATCH` and the blocking commands need the keys a command
  changed. The keyspace tracks dirty keys, or `Outcome.touched` lists them.
- Databases: `MOVE`, `SWAPDB`, `FLUSHALL` and `COPY ... DB` need all 16.
  Issue #3 decides between a `Databases` value with `.current` in `Call`, and
  an effect.
- Blocking commands (`BLPOP`, ...): a "blocking allowed" input in `Call`,
  because `MULTI` runs them without blocking. A handler that cannot answer
  returns a park effect (keys, deadline); the store task keeps the parked
  clients in order, retries them after each write, and a timer wakes the
  expired ones.
- Pub/sub: a pure registry (channel to client ids) in `pubsub/`. A handler
  returns a publish effect; the store task pushes to the outboxes and drops a
  subscriber whose outbox is full.
- Server-wide state for `INFO` and `CLIENT`: a pure struct built by `server/`
  and passed in `Call`.
