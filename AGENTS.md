# agc-redis-s

A Redis-compatible in-memory server written in Agentica. A subset of Redis,
memory only: no persistence, no Lua, no cluster, no replication. Planned work
is in the GitHub issues, one milestone per release.

## Map

```text
agc_redis_s.agc      main: options, start the store task, start dock
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
  server/            I/O SHELL: tasks, the clock; the sockets are the
                     package `dock`. config, connection (the handler dock
                     runs per client), store_task (owns the data), message,
                     clock
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
  `commands/command.agc` (`reply`, `reply_and_close`, `fail`, `wrong_arity`,
  and `write` or `write_all` to change data), never with the constructor:
  `make purity` fails on `Outcome(` anywhere else in `src/`. `Outcome` has no
  keyspace field, only `change`: only `write` and `write_all` carry a change,
  and the store applies every change. The type does not stop a handler that
  computes new data and answers with `reply`, which drops it, so review checks
  that every handler that changes data answers with `write` or `write_all`. A
  later feature adds a field to `Outcome` (or `Call`) with a default and a
  helper in the PR that needs it, and no handler changes.
- Build at the edge: `main` (`agc_redis_s.agc`) builds the collaborators (the
  store, the command table, the clock) and passes them in; a function does not
  build what it uses while it calls it, and only `src/server/` reads the clock.
- Tests: as few as needed that still cover the software well; before adding
  one ask what bug it catches that no other test catches. No BDD, no test per
  function, no near-duplicates.
  - Functional tests by domain, in Agentica, in process, no socket:
    `test/functional/<domain>_test.agc` feeds request bytes to `exchange` and
    compares the reply bytes and the keyspace. Plain paths, error texts and
    arity are tested here. The helper calls `commands/runner.agc`, the same
    code as the store task; only its read loop mirrors the server's, and the
    smoke test is the check of the real loop.
  - Unit tests only where a pure function has real logic (RESP reader and
    writer, glob, ranges, score formatting).
  - Property tests with `prop` (agentica-lang/packages, pinned in
    `agentica.toml`; `make install` fetches it into `deps/`, and `make check`
    and `make test` run it). A law is one `test_` function with one
    `Prop.check(gen, Prop.Config(runs: N))`, in the file of its domain. The
    generated value must be JSON (`prop` prints a counterexample as JSON), so
    generate `List[Int]` for bytes (`byte_list`, `to_bytes` in
    `test/support.agc`) and compare with `Prop.eq` on text or on `.to_a`:
    interpolating `Bytes` prints `<Bytes N>`, only the length, so compare
    `.to_a`. A test has a budget of about 2.5 million steps. Raise `runs` until the test fails with
    `RUNTIME-STEP-LIMIT`, then use a third of that number (at most a few
    hundred, so a test stays under a second), and write both numbers in the
    comment above the test. Laws over models (a `Map` or a `List`) are
    for the data types.
  - TCP is tested in the Agentica repo. Here one smoke test (`integration/`)
    proves the binary starts, answers PING, QUIT closes, and SIGTERM frees the
    port; it also checks that nothing runs behind a QUIT and that a client
    that left is not counted. The sockets, the accept loop and the outboxes are
    the package `dock`, tested there.
- One concern per file. A family past 300 lines becomes a folder
  `commands/<family>/`. Server-wide commands (`INFO`, `CLIENT`, `CONFIG`,
  `DBSIZE`, `FLUSHALL`) get their own file, not `connection.agc`.
- Pull requests are small and iterative: at most about 2,000 changed lines of
  real code, tests and docs (added plus removed); regenerated or generated data
  does not count. Split a larger change into PRs that each build, pass CI and
  stand on their own; go over only when a change cannot be split.
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
a lock. `dock` runs one handler task per connection, which reads and sends the
requests to the store task. The store task answers with `Dock.send` and the
`Conn` the message carries: dock queues the bytes in the outbox of the client
and never waits, so replies and later pushes (pub/sub) go out in the order the
store task decided, and a client that does not read is dropped at the cap
(`max_outbox_bytes`, 8 MiB). An `Effect` (today only `Close`,
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
- Session (transactions, subscribed mode): `session/session.agc` holds the
  pure `Session` struct (selected database, client name, library info). It is
  an input (`Call.session`) and an output (`Outcome.session`), and the store
  task keeps one per client: `MULTI` queues in it, and `EXEC` reads it.
- Touched keys: `WATCH` and the blocking commands need the keys a command
  changed. The keyspace tracks dirty keys, or `Outcome.touched` lists them.
- Databases: `store/databases.agc` holds the 16 keyspaces. A handler sees the
  selected one as `Call.keyspace` and returns its new one; `commands/runner.agc`
  puts it back (`write`). `Call.databases` is all 16 to read, and `write_all`
  returns all 16 (`FLUSHALL`; `MOVE`, `SWAPDB` and `COPY ... DB` later).
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
