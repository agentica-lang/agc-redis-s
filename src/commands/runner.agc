## What the server does with one parsed request, as pure functions. The store
## task and the functional tests both call them, so a test cannot pass while the
## server does something else: the task only keeps the `Store` they return.

import {Call, Change, Command, Effect} from "command"
import Dispatch from "dispatch"
import {Client, Store} from "engine"
import Generator from "../store/generator"
import {Reply} from "../resp/reply"
import Writer from "../resp/writer"
import {Databases, space_at, with_space} from "../store/databases"

## The store and the client after the request, the bytes to send, whether to
## close the connection after them, and whether the data changed.
struct Ran
  store: Store
  client: Client
  reply: Bytes
  close: Bool
  changed: Bool = false
end

## `argv` is the name and the arguments as the client sent them. The handler
## sees the keyspace of the selected database; when it wrote, its new keyspace
## goes back to that database, even if the command selects another one.
def run(table: Map[String, Command], store: Store, client: Client, argv: List[Bytes], now_ms: Int) -> Ran
  first = Generator.advance(store.seed, now_ms)
  session = client.session
  call = Call(
    keyspace: space_at(store.databases, session.db),
    databases: store.databases,
    session: session,
    args: argv.drop(1),
    now_ms: now_ms,
    random: store.seed * Generator.MODULUS + first,
    client_id: client.id,
    clients: client.clients,
    table: table,
  )

  outcome = Dispatch.execute(table, argv[0], call)
  next_store = apply(store, session.db, outcome.change).with(seed: Generator.advance(first, now_ms))
  Ran(
    store: next_store,
    client: client.with(session: outcome.session),
    reply: encoded(outcome.replies),
    close: outcome.effects.include?(Effect.Close),
    changed: changed?(outcome.change),
  )
end

## `run` for the requests of one receive, in order: one reply with all of
## theirs, so the task sends once. A request that closes the connection ends the
## run: the ones behind it do nothing.
def run_all(table: Map[String, Command], store: Store, client: Client, requests: List[List[Bytes]], now_ms: Int) -> Ran
  current = store
  who = client
  replies: List[Bytes] = []
  closing = false
  for argv in requests
    done = run(table, current, who, argv, now_ms)
    current = done.store
    who = done.client
    replies = replies.push(done.reply)
    if done.close
      closing = true
      break
    end
  end

  return Ran(store: current, client: who, reply: replies[0], close: closing) if replies.size == 1

  Ran(store: current, client: who, reply: Bytes.concat(replies), close: closing)
end

private

# Almost every command makes one reply: it is not copied into a concat of one.
def encoded(replies: List[Reply]) -> Bytes
  return Writer.encode(replies[0]) if replies.size == 1

  Bytes.concat(replies.map do |r| Writer.encode(r) end)
end

def changed?(change: Change) -> Bool
  case change
    Change.Nothing -> false
    _ -> true
  end
end

def apply(store: Store, db: Int, change: Change) -> Store
  case change
    Change.Nothing -> store
    Change.Keyspace(keyspace) -> store.with(databases: with_space(store.databases, db, keyspace))
    Change.All(databases) -> store.with(databases: databases)
  end
end
