# agc-redis-s

A Redis-compatible in-memory server written in Agentica. A subset of Redis,
memory only: no persistence, no Lua, no cluster, no replication. Planned work
is in the GitHub issues, one milestone per release.

## Map

```text
agc_redis_s.agc      main: options, start the server (next PR of issue #1)
src/
  resp/              PURE. The RESP2 wire format: reply.agc (the reply
                     types), writer.agc (reply to bytes); the reader (bytes
                     to a request) joins them in the next PR
  store/             PURE. The data: value.agc (one variant per data type),
                     keyspace.agc (key to value); one file per data type
                     (hash.agc, list.agc, set.agc, zset.agc) when it lands
  commands/          PURE. command.agc (Command, Call, Outcome), table.agc
                     (all rows), dispatch.agc (name, arity, call the
                     handler), one file per command family
  server/            I/O SHELL (next PR). The only folder that opens
                     sockets, spawns tasks or reads the clock
test/                unit tests (`*_test.agc`), the same path as the source
integration/         Python peer, standard library only (next PR)
```

## Rules

- Pure core. `resp/`, `store/` and `commands/` never call `File`, `Dir`,
  `Path`, `System`, `Process`, `IO`, `TCP`, `TLS`, `Time`, `Random`, `Task`,
  `Channel`, `ATS`, `puts` and never import `server/`. Time and the client
  arrive as arguments (`Call.now_ms`, `Call.client_id`). `make purity`
  enforces it.
- Error texts are those of Redis, letter by letter. Keys and values are
  `Bytes`, never `String`.
- Tests: unit tests and integration tests only, no BDD. Add few, on the
  important behavior. Network tests use localhost and port 0, clean up every
  process, and use no external service.
- One concern per file. A file that grows past about 300 lines is split by
  topic.
- Pull requests are small and iterative: at most 800 changed lines (added
  plus removed, tests and docs counted). If a change would pass 800, split it
  into PRs that each build, pass CI and stand on their own.
- Style: `agentica fmt`, `agentica lint --strict`. Comments say why.

## Commands

- `make check` (purity, `agentica check`, lint), `make fmt-check`,
  `make test` (unit tests). `agentica fmt src test` fixes formatting.
- `make integration` starts the server and runs `integration/` (next PR).
- The Agentica version is pinned in `.github/workflows/ci.yml`.

## How a command travels

```text
socket -> connection task -> RESP reader -> request (name, args)
  -> store task (owns the keyspace; one message at a time, like Redis)
  -> commands/dispatch (table lookup, arity check) -> handler
  -> Outcome (new keyspace, reply) -> RESP writer -> connection outbox
  -> writer task -> socket
```

One task owns the data and takes messages from a channel, so no command needs
a lock. Each connection has a reader task and a writer task; the writer drains
an outbox channel of bytes. Replies and later pushes (pub/sub) both go through
the outbox, so their order is the order the store task decided.

## How to add a command

1. Pick the family file in `commands/` (`strings.agc`, `keys.agc`,
   `hashes.agc`, ...). A new family is a new file with `commands()` and one
   line in `commands/table.agc`.
2. Add one `Command` row (lowercase name, arity as Redis counts it with the
   name, flags, handler) and one handler `def name(call: Call) -> Outcome`.
   Answer with `reply(call, ...)`, or build an `Outcome` with a new keyspace.
3. A new data type: a variant in `store/value.agc` and its operations in
   `store/<type>.agc`. Handlers call those; they never reach into `Value`.
4. A unit test in `test/commands/<family>_test.agc` (the same name).
5. One case in `integration/` when the wire behavior matters.
6. A row in the status table of `README.md`.

## Where later features go

The reasoning behind the layout: each feature changes one place, not all.

- Hashes, lists, sets, sorted sets: `store/<type>.agc` and
  `commands/<type>s.agc`. A handler that mixes types checks the variant of the
  `Value` and answers `WRONGTYPE`.
- Expiry: `store/keyspace.agc` takes `now_ms`; the clock lives in `server/`
  only, so tests do not sleep.
- Transactions: per-client state (queued commands, watched keys) is a
  `Session` struct in a new pure folder `session/`. It becomes a field of
  `Call` and `Outcome` (a new field, no handler changes).
- Pub/sub: a pure registry (channel to client ids) in `pubsub/`. A handler
  returns an effect (`Publish`), a new field of `Outcome`; the store task
  turns effects into pushes on the outboxes. A slow subscriber is dropped
  when its outbox is full, so the store task never waits for it.
- Blocking commands: the handler returns a `Park` effect with keys and a
  deadline; the store task keeps the parked clients in order and retries them
  after each write, and a timer message wakes the expired ones.
