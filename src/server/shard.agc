## An actor that owns the keys of a range of hash slots. It handles one message
## at a time, so a command never sees a half-done one, as with the single
## thread of Redis; a request on the keys of several shards locks them all
## while it runs (`Lend`).

import Actor from "std/actor"
import Cluster from "../shards/cluster"
import Engine from "../commands/engine"
import Runner from "../commands/runner"
import {Command} from "../commands/command"
import {Store} from "../commands/engine"
import Databases from "../store/databases"
import {Loan, Message, Payback} from "message"

## How long a shard waits for what it lent, by default. A connection gives the
## keys back well before (it checks `Loan.until`) or not at all; a connection
## that was cancelled while it held them makes the shard wait that long.
LEND_MS = 30_000

## What a shard works with; `main` builds it and the shard builds nothing. The
## clock is the only way it learns the time, so a test passes its own.
struct Setup
  store: Store
  table: Map[String, Command]
  now_ms: Fn[Int]
  ## How long the shard waits for what it lent.
  lend_ms: Int = LEND_MS
end

## What a shard keeps between messages.
struct State
  store: Store
  table: Map[String, Command]
  now_ms: Fn[Int]
  lend_ms: Int
  swept_at: Int = 0
end

## Starts the shard and the ticker that wakes its sweep when no request comes.
def start(setup: Setup, capacity: Int) -> Actor.Ref[State, Message]
  behaviour: Actor.Behaviour[State, Message] = Actor.Behaviour(init: -> { first(setup) }, handle: &step)
  shard = Actor.start(behaviour, Actor.Options(capacity: capacity))
  _ticker = Task.spawn(&tick, shard.address)
  shard
end

## The state before the first message.
def first(setup: Setup) -> State
  State(store: setup.store, table: setup.table, now_ms: setup.now_ms, lend_ms: setup.lend_ms)
end

## One message, with one clock reading: the active expiry runs first when it is
## due, so it is not starved under a load that never lets the inbox go empty.
def handle(state: State, message: Message) -> State
  now = state.now_ms.call()
  current = swept(state, now)
  case message
    Message.Tick -> current
    Message.Run(requests, client, answer) -> run(current, requests, client, answer, now)
    Message.Sizes(answer) ->
      _ = Actor.reply(answer, Databases.sizes(current.store.databases))
      current
    Message.Lend(keys, out, back) -> lend(current, keys, out, back)
  end
end

private

def step(state: State, message: Message) -> Actor.Step[State] = Actor.continue(handle(state, message))

# A full inbox means requests are coming, and each one sweeps when it is due:
# the tick is only for an idle server, so it never waits for room.
def tick(address: Address[Message]) -> Void
  while true
    Task.sleep(Engine.SWEEP_MS)
    case Actor.cast(address, Message.Tick, 0)
      ok(_) -> nil
      error(e) -> return if e.is_a?("channel.gone")
    end
  end
end

def swept(state: State, now: Int) -> State
  return state if not Engine.sweep_due?(state.swept_at, now)

  state.with(store: Engine.expire_keys(state.store, now), swept_at: now)
end

# A connection that gave up closed its channel: the answer has nobody to go to.
def run(state: State, requests: List[List[Bytes]], client: Engine.Client, answer: Channel[Bytes], now: Int) -> State
  done = Runner.run_all(state.table, state.store, client, requests, now)
  _ = Actor.reply(answer, done.reply)
  state.with(store: done.store)
end

# The shard handles nothing else until the keys come back. A connection that
# gave up closes `back` (or never got the loan): the shard keeps its data.
def lend(state: State, keys: Optional[List[Bytes]], out: Channel[Loan], back: Channel[Payback]) -> State
  until = Time.monotonic_ms + state.lend_ms
  loan = Loan(databases: Cluster.lent(state.store, keys), seed: state.store.seed, until: until)
  return state if not Actor.reply(out, loan)

  case back.recv([until - Time.monotonic_ms, 0].max.unwrap!)
    ok(returned) -> state.with(store: Cluster.taken_back(state.store, keys, returned.databases, returned.seed))
    error(_) ->
      back.close
      case back.recv(0)
        ok(returned) -> state.with(store: Cluster.taken_back(state.store, keys, returned.databases, returned.seed))
        error(_) -> state
      end
  end
end
