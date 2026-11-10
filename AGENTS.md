# agc-redis-s

A Redis-compatible in-memory server written in Agentica. A subset of Redis,
memory only: no persistence, no Lua, no cluster, no replication. Planned work
is in the GitHub issues, one milestone per release.

## Map

```text
src/
  resp/              PURE. The RESP2 wire format: reply.agc (the reply
                     types), writer.agc (reply to bytes)
  store/             PURE. The data: value.agc (one variant per data type),
                     keyspace.agc (key to value); one file per data type
                     (hash.agc, list.agc, set.agc, zset.agc) when it lands
  commands/          PURE. command.agc (Command, Call, Outcome and the
                     helpers that build an Outcome), table.agc (all rows),
                     dispatch.agc (name, arity, call the handler), one file
                     per command family
test/                unit tests (`*_test.agc`), the same path as the source;
                     support.agc holds the helpers they share
tools/               check_purity.py and its tests (Python, standard library)
```

The I/O shell (`src/server/`: sockets, tasks, the clock) and `integration/`
(a Python peer over a raw socket) join in the next PR of issue #1.

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
- Tests: unit and integration tests only, no BDD; few, on the important
  behavior. Network tests use localhost and port 0 and clean up every process.
- One concern per file. A family past 300 lines becomes a folder
  `commands/<family>/`. Server-wide commands (`INFO`, `CLIENT`, `CONFIG`,
  `DBSIZE`, `FLUSHALL`) get their own file, not `connection.agc`.
- Pull requests are small and iterative: at most 800 changed lines (added
  plus removed, tests and docs counted). If a change would pass 800, split it
  into PRs that each build, pass CI and stand on their own.
- Style: `agentica fmt`, `lint --strict`; imports sorted by path.

## Commands

- `make check` (purity, `agentica check`, lint), `make fmt-check`,
  `make test` (unit tests of `test/` and `tools/`). `agentica fmt src test`
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
4. A unit test in `test/commands/<family>_test.agc` (the same name).
5. One case in `integration/` when the wire behavior matters.
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
