## The data the store task owns and the two things it does between requests:
## clients joining and leaving, and the timed sweep of expired keys. Pure, so
## the store task and the functional tests call the same functions.

import {Session} from "../session/session"
import {Databases, sweep} from "../store/databases"

## How often the store task sweeps; Redis runs its active expiry 10 times a
## second (hz 10).
export SWEEP_MS = 100

## All the data the store task owns: the databases and the session of each
## connected client, by client id.
export struct Store
  databases: Databases
  sessions: Map[Int, Session]
  ## The state of a small generator, 0 to 2^31 - 1; every request advances it.
  seed: Int = 1
end

## The store of a server that just started.
export def start(databases: Databases) -> Store = Store(databases: databases, sessions: {})

## A client connected: it starts in database 0 with no name.
export def join(store: Store, client_id: Int) -> Store = store.with(sessions: store.sessions.put(client_id, Session()))

## Whether the client still has a session (it did not quit or leave).
export def joined?(store: Store, client_id: Int) -> Bool = store.sessions.has_key?(client_id)

## A client left: its session goes.
export def leave(store: Store, client_id: Int) -> Store = store.with(sessions: store.sessions.delete(client_id))

## Whether a sweep is due: `SWEEP_MS` passed since the last one, or the clock
## went back (a negative gap would stop the sweeps until it caught up).
export def sweep_due?(last_ms: Int, now_ms: Int) -> Bool = now_ms < last_ms or now_ms - last_ms >= SWEEP_MS

## The active expiry: the keys that are past their deadline are dropped. The
## store task calls it on a timer; no reply depends on it, as an expired key
## already counts as missing.
export def expire_keys(store: Store, now_ms: Int) -> Store = store.with(databases: sweep(store.databases, now_ms))
