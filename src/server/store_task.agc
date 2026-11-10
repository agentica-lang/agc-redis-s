## The task that owns the data. It takes one message at a time, so a command
## never sees a half-done one, as with the single thread of Redis.

import Dock from "pkg/dock/dock"
import {Command} from "../commands/command"
import Requests from "../commands/session"
import {Store} from "../commands/session"
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
  return take_all(setup.inbox, setup.now_ms, State(store: setup.store, table: setup.table)).store
end

def take_all(inbox: Channel[Message], clock: Fn[Int], first: State) -> State
  state = first
  while true
    case inbox.recv(Requests.SWEEP_MS)
      ok(message) ->
        now = clock.call()
        state = drained(inbox, handle(swept(state, now), message, now), now)
      error(_) ->
        state = swept(state, clock.call())
        if inbox.closed? and inbox.empty?
          break
        end
    end
  end

  return state
end

# The messages that already wait in the inbox run with the same clock reading
# (at most `BATCH`, so the reading is never more than a few milliseconds old
# and the sweep is not starved): one clock read per batch, not per message.
def drained(inbox: Channel[Message], first: State, now: Int) -> State
  state = first
  taken = 0
  while taken < BATCH and not inbox.empty?
    case inbox.recv(Requests.SWEEP_MS)
      ok(message) -> state = handle(state, message, now)
      error(_) -> break
    end

    taken += 1
  end

  return state
end

# The active expiry runs between messages, at most every `SWEEP_MS`, also under
# a load that never lets the receive time out.
def swept(state: State, now: Int) -> State
  if not Requests.sweep_due?(state.swept_at, now)
    return state
  end

  return state.with(store: Requests.expire_keys(state.store, now), swept_at: now)
end

def handle(state: State, message: Message, now: Int) -> State
  case message
    Message.Open(conn) -> return state.with(store: Requests.join(state.store, conn.id))
    Message.Exec(conn, argv) -> return exec(state, conn, argv, now)
    Message.Close(conn, farewell) -> return hang_up(state, conn, farewell)
    Message.Gone(id) -> return state.with(store: Requests.leave(state.store, id))
  end
end

# A client that was dropped or already quit has no session, so the requests it
# left in the inbox do nothing.
def exec(state: State, conn: Dock.Conn, argv: List[Bytes], now: Int) -> State
  done = Requests.run(state.table, state.store, conn.id, argv, now)
  send(conn, done.reply)
  next_state = state.with(store: done.store)
  if done.close
    return close(next_state, conn, "".bytes)
  end

  return next_state
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
  if not Requests.joined?(state.store, conn.id)
    return state
  end

  return close(state, conn, farewell)
end

# `Dock.close` writes what is queued first, so the replies and the farewell go
# out in order. The session goes now: the requests behind a QUIT must not run.
def close(state: State, conn: Dock.Conn, farewell: Bytes) -> State
  send(conn, farewell)
  Dock.close(conn)
  return state.with(store: Requests.leave(state.store, conn.id))
end
