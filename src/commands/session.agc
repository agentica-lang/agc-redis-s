## What the server does with one parsed request, as pure functions. The store
## task and the functional tests both call them, so a test cannot pass while the
## server does something else: the task only keeps the `Store` they return.

import {Call, Change, Command, Effect} from "command"
import Dispatch from "dispatch"
import Writer from "../resp/writer"
import {Session} from "../session/session"
import {Databases, space_at, sweep, with_space} from "../store/databases"

## How often the store task sweeps; Redis runs its active expiry 10 times a
## second (hz 10).
export SWEEP_MS = 100

## All the data the store task owns: the databases and the session of each
## connected client, by client id.
export struct Store
  databases: Databases
  sessions: Map[Int, Session]
end

## The store after the request, the bytes to send, and whether to close the
## connection after them.
export struct Ran
  store: Store
  reply: Bytes
  close: Bool
end

## The store of a server that just started.
export def start(databases: Databases) -> Store
  return Store(databases: databases, sessions: {})
end

## A client connected: it starts in database 0 with no name.
export def join(store: Store, client_id: Int) -> Store
  return store.with(sessions: store.sessions.put(client_id, Session()))
end

## A client left: its session goes.
export def leave(store: Store, client_id: Int) -> Store
  return store.with(sessions: store.sessions.delete(client_id))
end

## Whether a sweep is due: `SWEEP_MS` passed since the last one, or the clock
## went back (a negative gap would stop the sweeps until it caught up).
export def sweep_due?(last_ms: Int, now_ms: Int) -> Bool
  return now_ms < last_ms or now_ms - last_ms >= SWEEP_MS
end

## The active expiry: the keys that are past their deadline are dropped. The
## store task calls it on a timer; no reply depends on it, as an expired key
## already counts as missing.
export def expire_keys(store: Store, now_ms: Int) -> Store
  return store.with(databases: sweep(store.databases, now_ms))
end

## The last bytes before a connection closes on a protocol error.
export def protocol_error_reply(text: String) -> Bytes
  return "-ERR #{text}\r\n".bytes
end

## `argv` is the name and the arguments as the client sent them. The handler
## sees the keyspace of the selected database; when it wrote, its new keyspace
## goes back to that database, even if the command selects another one. A client
## that did not `join` gets no reply and changes nothing.
export def run(table: Map[String, Command], store: Store, client_id: Int, argv: List[Bytes], now_ms: Int) -> Ran
  case store.sessions.get(client_id)
    none -> return Ran(store: store, reply: "".bytes, close: false)
    some(session) -> return run_for(table, store, client_id, session, argv, now_ms)
  end
end

def run_for(
  table: Map[String, Command],
  store: Store,
  client_id: Int,
  session: Session,
  argv: List[Bytes],
  now_ms: Int,
) -> Ran
  call = Call(
    keyspace: space_at(store.databases, session.db),
    databases: store.databases,
    session: session,
    args: argv.drop(1),
    now_ms: now_ms,
    client_id: client_id,
    clients: store.sessions.size,
    table: table,
  )

  outcome = Dispatch.execute(table, argv[0], call)
  next_store = apply(store, session.db, outcome.change)
  if outcome.session != session
    next_store = next_store.with(sessions: store.sessions.put(client_id, outcome.session))
  end

  reply = Bytes.concat(outcome.replies.map do |r| Writer.encode(r) end)
  return Ran(store: next_store, reply: reply, close: outcome.effects.include?(Effect.Close))
end

def apply(store: Store, db: Int, change: Change) -> Store
  case change
    Change.Nothing -> return store
    Change.Keyspace(keyspace) -> return store.with(databases: with_space(store.databases, db, keyspace))
    Change.All(databases) -> return store.with(databases: databases)
  end
end
