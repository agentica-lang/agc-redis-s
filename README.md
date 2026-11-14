# agc-redis-s

A Redis-compatible in-memory server, written in
[Agentica](https://github.com/agentica-lang/agentica).

## What it is

- A subset of Redis that speaks RESP2, so `redis-cli` and client libraries
  work with it.
- Memory only. One actor owns the data, as the single thread of Redis does;
  `--shards N` splits the keys across N actors by hash slot.
- Error texts are those of Redis.

## What it is not

No persistence (no RDB, no AOF), no Lua scripting, no cluster, no
replication. Persistence and Lua may come later through a native module.

## Run

```text
agentica agc_redis_s.agc --port 6379   # 0 picks a free port
agentica agc_redis_s.agc --shards 4    # actors that split the keys by hash slot
```

With more than one shard:

- A command on the keys of several shards (MSET, RENAME, SUNIONSTORE, ...) or
  on all keys (SCAN, KEYS, RANDOMKEY, FLUSHALL, SWAPDB) locks those shards
  while it runs. A write must finish in about 25 s (the 30 s a shard waits for
  its keys, less a 5 s margin); a later one changes nothing and the server
  closes the connection with no reply. A read that late still answers.
- SCAN, KEYS, RANDOMKEY, FLUSHALL and SWAPDB join every shard's keys on each
  call, which costs time in proportion to the number of keys. DBSIZE and INFO
  only add up the counts.

## Develop

Needs Agentica 0.31.1.

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
| 5 | Hashes, lists, sets, sorted sets | in progress (hashes, lists and sets done) |
| 6 | Transactions, pub/sub | planned |
| 7 | Blocking list commands | planned |
| 8 | Compatibility and speed | planned |

## License

MIT.
