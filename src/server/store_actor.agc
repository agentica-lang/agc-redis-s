## The actor that owns the data. It handles one message at a time, so a command
## never sees a half-done one, as with the single thread of Redis.

import Actor from "std/actor"
import Dock from "pkg/dock/dock"
import Engine from "../commands/engine"
import Runner from "../commands/runner"
import {Command} from "../commands/command"
import {Store} from "../commands/engine"
import {Message} from "message"

## What the actor works with; `main` builds it and the actor builds nothing. The
## clock is the only way the actor learns the time, so a test passes its own.
struct Setup
  store: Store
  table: Map[String, Command]
  now_ms: Fn[Int]
end

## What the actor keeps between messages.
struct State
  store: Store
  table: Map[String, Command]
  now_ms: Fn[Int]
  swept_at: Int = 0
end

## Starts the actor and the ticker that wakes its sweep when no request comes.
def start(setup: Setup, capacity: Int) -> Actor.Ref[State, Message]
  behaviour: Actor.Behaviour[State, Message] = Actor.Behaviour(init: -> { first(setup) }, handle: &step)
  actor = Actor.start(behaviour, Actor.Options(capacity: capacity))
  _ticker = Task.spawn(&tick, actor.address)
  actor
end

## The state before the first message.
def first(setup: Setup) -> State = State(store: setup.store, table: setup.table, now_ms: setup.now_ms)

## One message, with one clock reading: the active expiry runs first when it is
## due, so it is not starved under a load that never lets the inbox go empty.
def handle(state: State, message: Message) -> State
  now = state.now_ms.call()
  current = swept(state, now)
  case message
    Message.Tick -> current
    Message.Open(conn) -> current.with(store: Engine.join(current.store, conn.id))
    Message.Exec(conn, requests) -> exec(current, conn, requests, now)
    Message.Close(conn, farewell) -> hang_up(current, conn, farewell)
    Message.Gone(id) -> current.with(store: Engine.leave(current.store, id))
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

# A client that was dropped or already quit has no session, so the requests it
# left in the inbox do nothing.
def exec(state: State, conn: Dock.Conn, requests: List[List[Bytes]], now: Int) -> State
  done = Runner.run_all(state.table, state.store, conn.id, requests, now)
  send(conn, done.reply)
  next_state = state.with(store: done.store)
  return close(next_state, conn, "".bytes) if done.close

  next_state
end

# `Dock.send` never waits for the client. It fails once the client is gone or
# was dropped for passing the outbox cap; the session then ends with `Gone`.
def send(conn: Dock.Conn, bytes: Bytes) -> Void
  if not bytes.empty?
    _ = Dock.send(conn, bytes)
  end
end

# A client that quit already has no session and its connection is closed: the
# close that its handler sends after the end it saw does nothing.
def hang_up(state: State, conn: Dock.Conn, farewell: Bytes) -> State
  return state if not Engine.joined?(state.store, conn.id)

  close(state, conn, farewell)
end

# `Dock.close` writes what is queued first, so the replies and the farewell go
# out in order. The session goes now: the requests behind a QUIT must not run.
def close(state: State, conn: Dock.Conn, farewell: Bytes) -> State
  send(conn, farewell)
  Dock.close(conn)
  state.with(store: Engine.leave(state.store, conn.id))
end
