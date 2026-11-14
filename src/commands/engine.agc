## The data a shard owns, the client a request runs for, and the timed sweep of
## expired keys. Pure, so the shards and the functional tests call the same
## functions.

import {Session} from "../session/session"
import {Databases, sweep} from "../store/databases"

## How often a shard sweeps; Redis runs its active expiry 10 times a
## second (hz 10).
SWEEP_MS = 100

## All the data a shard owns: its keys in the 16 databases.
struct Store
  databases: Databases
  ## The state of a small generator, 0 to 2^31 - 1; every request advances it.
  seed: Int = 1
end

## Who sends a request: its id, its session and how many clients are connected,
## this one included. The connection keeps it; a request may change the session.
struct Client
  id: Int
  session: Session
  clients: Int = 1
end

## The store of a server that just started.
def start(databases: Databases) -> Store = Store(databases: databases)

## A client that just connected: database 0, no name.
def client(id: Int) -> Client = Client(id: id, session: Session())

## Whether a sweep is due: `SWEEP_MS` passed since the last one, or the clock
## went back (a negative gap would stop the sweeps until it caught up).
def sweep_due?(last_ms: Int, now_ms: Int) -> Bool = now_ms < last_ms or now_ms - last_ms >= SWEEP_MS

## The active expiry: the keys that are past their deadline are dropped. The
## shard calls it on a timer; no reply depends on it, as an expired key
## already counts as missing.
def expire_keys(store: Store, now_ms: Int) -> Store = store.with(databases: sweep(store.databases, now_ms))
