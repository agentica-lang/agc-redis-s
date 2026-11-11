## The task that owns the data. It takes one message at a time, so a command
## never sees a half-done one, as with the single thread of Redis.

import Dock from "pkg/dock/dock"
import Engine from "../commands/engine"
import Runner from "../commands/runner"
import {Command} from "../commands/command"
import {Store} from "../commands/engine"
import {Message} from "message"

BATCH = 32

## What the task works with; `main` builds it and the task builds nothing
## (`Task.spawn` passes one argument, so the inbox is in it). The
## clock is the only way the task learns the time, so a test passes its own.
export struct Setup
  inbox: Channel[Message]
  store: Store
  table: Map[String, Command]
  now_ms: Fn[Int]
end

struct State
  store: Store
  table: Map[String, Command]
  swept_at: Int = 0
end

## Runs until `inbox` is closed.
export def run(setup: Setup) -> Void
  _ = serve(setup)
end

## `run`, and the store it ends with.
export def serve(setup: Setup) -> Store
  take_all(setup.inbox, setup.now_ms, State(store: setup.store, table: setup.table)).store
end

def take_all(inbox: Channel[Message], clock: Fn[Int], first: State) -> State
  state = first
  while true
    case inbox.recv(Engine.SWEEP_MS)
      ok(message) ->
        now = clock.call()
        state = drained(inbox, handle(swept(state, now), message, now), now)
      error(_) ->
        state = swept(state, clock.call())
        break if inbox.closed? and inbox.empty?
    end
  end

  state
end

# The messages that already wait in the inbox run with the same clock reading
# (at most `BATCH`, so the reading is never more than a few milliseconds old
# and the sweep is not starved): one clock read per batch, not per message.
def drained(inbox: Channel[Message], first: State, now: Int) -> State
  state = first
  taken = 0
  while taken < BATCH and not inbox.empty?
    case inbox.recv(Engine.SWEEP_MS)
      ok(message) -> state = handle(state, message, now)
      error(_) -> break
    end

    taken += 1
  end

  state
end

# The active expiry runs between messages, at most every `SWEEP_MS`, also under
# a load that never lets the receive time out.
def swept(state: State, now: Int) -> State
  return state if not Engine.sweep_due?(state.swept_at, now)

  state.with(store: Engine.expire_keys(state.store, now), swept_at: now)
end

def handle(state: State, message: Message, now: Int) -> State
  case message
    Message.Open(conn) -> state.with(store: Engine.join(state.store, conn.id))
    Message.Exec(conn, requests) -> exec(state, conn, requests, now)
    Message.Close(conn, farewell) -> hang_up(state, conn, farewell)
    Message.Gone(id) -> state.with(store: Engine.leave(state.store, id))
  end
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
