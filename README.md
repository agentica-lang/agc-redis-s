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

Needs Agentica 0.28.0.

```text
agentica agc_redis_s.agc --port 6379
redis-cli ping
```

`--port 0` picks a free port and prints it on the first line.

## Develop

```text
make check fmt-check test integration
```

Read `AGENTS.md` for the layout and how to add a command.

## Status

| Phase | Scope | State |
|---|---|---|
| 0 | Layout, CI, PING and ECHO | done |
| 1 | RESP2 reader and writer | planned |
| 2 | Connection and server commands | planned |
| 3 | Strings | planned |
| 4 | Keys and expiry | planned |
| 5 | Hashes | planned |
| 6 | Lists | planned |
| 7 | Sets | planned |
| 8 | Sorted sets | planned |
| 9 | Transactions | planned |
| 10 | Pub/sub | planned |
| 11 | Blocking list commands | planned |
| 12 | Compatibility and speed | planned |

## License

MIT.
