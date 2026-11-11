## What the server does with one parsed request, as pure functions. The store
## task and the functional tests both call them, so a test cannot pass while the
## server does something else: the task only keeps the `Store` they return.

import {Call, Change, Command, Effect} from "command"
import Dispatch from "dispatch"
import {Store} from "engine"
import Generator from "../store/generator"
import {Reply} from "../resp/reply"
import Writer from "../resp/writer"
import {Session} from "../session/session"
import {Databases, space_at, with_space} from "../store/databases"

## The store after the request, the bytes to send, and whether to close the
## connection after them.
export struct Ran
  store: Store
  reply: Bytes
  close: Bool
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

## `run` for the requests of one receive, in order: one reply with all of
## theirs, so the task sends once. A request that closes the connection ends the
## run: the ones behind it do nothing.
export def run_all(
  table: Map[String, Command],
  store: Store,
  client_id: Int,
  requests: List[List[Bytes]],
  now_ms: Int,
) -> Ran
  current = store
  replies: List[Bytes] = []
  closing = false
  for argv in requests
    done = run(table, current, client_id, argv, now_ms)
    current = done.store
    replies = replies.push(done.reply)
    if done.close
      closing = true
      break
    end
  end

  if replies.size == 1
    return Ran(store: current, reply: replies[0], close: closing)
  end

  return Ran(store: current, reply: Bytes.concat(replies), close: closing)
end

def run_for(
  table: Map[String, Command],
  store: Store,
  client_id: Int,
  session: Session,
  argv: List[Bytes],
  now_ms: Int,
) -> Ran
  first = Generator.advance(store.seed, now_ms)
  call = Call(
    keyspace: space_at(store.databases, session.db),
    databases: store.databases,
    session: session,
    args: argv.drop(1),
    now_ms: now_ms,
    random: store.seed * Generator.MODULUS + first,
    client_id: client_id,
    clients: store.sessions.size,
    table: table,
  )

  outcome = Dispatch.execute(table, argv[0], call)
  next_store = apply(store, session.db, outcome.change).with(seed: Generator.advance(first, now_ms))
  if outcome.session != session
    next_store = next_store.with(sessions: store.sessions.put(client_id, outcome.session))
  end

  return Ran(store: next_store, reply: encoded(outcome.replies), close: outcome.effects.include?(Effect.Close))
end

# Almost every command makes one reply: it is not copied into a concat of one.
def encoded(replies: List[Reply]) -> Bytes
  if replies.size == 1
    return Writer.encode(replies[0])
  end

  return Bytes.concat(replies.map do |r| Writer.encode(r) end)
end

def apply(store: Store, db: Int, change: Change) -> Store
  case change
    Change.Nothing -> return store
    Change.Keyspace(keyspace) -> return store.with(databases: with_space(store.databases, db, keyspace))
    Change.All(databases) -> return store.with(databases: databases)
  end
end
