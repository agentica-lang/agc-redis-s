## The task that owns the data. It takes one message at a time, so a command
## never sees a half-done one, as with the single thread of Redis.

import Dock from "pkg/dock/dock"
import {Command} from "../commands/command"
import Requests from "../commands/session"
import {Store} from "../commands/session"
import {fresh} from "../store/databases"
import Table from "../commands/table"
import Clock from "clock"
import {Message} from "message"

struct State
  store: Store
  table: Map[String, Command]
  swept_at: Int = 0
end

## Runs until `inbox` is closed.
export def run(inbox: Channel[Message]) -> Void
  _ = take_all(inbox, State(store: Requests.start(fresh()), table: Table.build()))
end

def take_all(inbox: Channel[Message], first: State) -> State
  state = first
  while true
    case inbox.recv(Requests.SWEEP_MS)
      ok(message) ->
        now = Clock.now_ms()
        state = handle(swept(state, now), message, now)
      error(_) ->
        state = swept(state, Clock.now_ms())
        if inbox.closed? and inbox.empty?
          break
        end
    end
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
    Message.Close(conn, farewell, done) -> return hang_up(state, conn, farewell, done)
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

def hang_up(state: State, conn: Dock.Conn, farewell: Bytes, done: Channel[Bool]) -> State
  next_state = close(state, conn, farewell)
  _ = done.send(true, 0)
  return next_state
end

# `Dock.close` writes what is queued first, so the replies and the farewell go
# out in order. The session goes now: the requests behind a QUIT must not run.
def close(state: State, conn: Dock.Conn, farewell: Bytes) -> State
  send(conn, farewell)
  Dock.close(conn)
  return state.with(store: Requests.leave(state.store, conn.id))
end
