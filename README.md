# agc-redis-s

A Redis-compatible in-memory server, written in
[Agentica](https://github.com/agentica-lang/agentica).

## What it is

- A subset of Redis that speaks RESP2, so `redis-cli` and client libraries
  work with it.
- Memory only. One task owns the data, as the single thread of Redis does.
- Error texts are those of Redis.

## What it is not

No persistence (no RDB, no AOF), no Lua scripting, no cluster, no
replication. Persistence and Lua may come later through a native module.

## Run

```text
agentica agc_redis_s.agc --port 6379   # 0 picks a free port
```

## Develop

Needs Agentica 0.28.0.

```text
make check fmt-check test integration
```

Read `AGENTS.md` for the layout and how to add a command.

## Status

| Phase | Scope | State |
|---|---|---|
| 0 | Layout, CI, PING and ECHO | done |
| 1 | RESP2 reader and writer | done |
| 2 | Connection and server commands | done |
| 3 | Strings | done |
| 4 | Keys and expiry | done |
| 5 | Hashes, lists, sets, sorted sets | in progress (hashes done) |
| 6 | Transactions, pub/sub | planned |
| 7 | Blocking list commands | planned |
| 8 | Compatibility and speed | planned |

## License

MIT.
