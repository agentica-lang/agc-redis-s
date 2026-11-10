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

## Develop

Needs Agentica 0.28.0.

```text
make check fmt-check test
```

Read `AGENTS.md` for the layout and how to add a command.

## Status

The server does not start yet: only the pure core exists.

| Phase | Scope | State |
|---|---|---|
| 0 | Layout, CI, PING and ECHO | in progress |
| 1 | RESP2 reader and writer | planned |
| 2 | Connection and server commands | planned |
| 3 | Strings | planned |
| 4 | Keys and expiry | planned |
| 5 | Hashes, lists, sets, sorted sets | planned |
| 6 | Transactions, pub/sub | planned |
| 7 | Blocking list commands | planned |
| 8 | Compatibility and speed | planned |

## License

MIT.
