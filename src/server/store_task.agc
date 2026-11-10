## The task that owns the data. It takes one message at a time, so a command
## never sees a half-done one, as with the single thread of Redis.

import {Command} from "../commands/command"
import Requests from "../commands/session"
import Table from "../commands/table"
import Clock from "clock"
import {MAX_PENDING_BYTES, REPLY_OVERHEAD, Message} from "message"
import {Session} from "../session/session"
import {Databases, fresh} from "../store/databases"

POLL_MS = 1000

struct Client
  outbox: Channel[Bytes]
  pending: ATS[Int, Int]
  session: Session
end

struct State
  databases: Databases
  table: Map[String, Command]
  clients: Map[Int, Client]
end

## Runs until `inbox` is closed.
export def run(inbox: Channel[Message]) -> Void
  state = State(databases: fresh(), table: Table.build(), clients: {})
  while true
    case inbox.recv(POLL_MS)
      ok(message) -> state = handle(state, message)
      error(_) ->
        if inbox.closed? and inbox.empty?
          break
        end
    end
  end

  # No writer task is left waiting on an outbox that nothing will fill.
  for id in state.clients.keys
    _ = drop(state, id)
  end
end

def handle(state: State, message: Message) -> State
  case message
    Message.Open(id, outbox, pending) ->
      return state.with(clients: state.clients.put(id, Client(outbox: outbox, pending: pending, session: Session())))
    Message.Exec(id, argv) -> return exec(state, id, argv)
    Message.Close(id, farewell) -> return close(state, id, farewell)
  end
end

# A client that was dropped (its outbox was full) may still have requests in
# the inbox: they must not run.
def exec(state: State, id: Int, argv: List[Bytes]) -> State
  case state.clients.get(id)
    none -> return state
    some(client) ->
      done = Requests.execute_request(state.table, state.databases, client.session, argv, Clock.now_ms(), id)
      known = client.with(session: done.session)
      moved = state.with(databases: done.databases, clients: state.clients.put(id, known))
      sent = send(moved, id, done.reply)
      if done.close
        return drop(sent, id)
      end

      return sent
  end
end

# The store task never waits for a client: a full outbox or too many unread
# bytes drops the client at once. `pending` is the bytes queued and not yet
# sent, so it covers the outbox and the send in progress; it is exact because
# only this task adds and only the writer subtracts, after each send.
def send(state: State, id: Int, bytes: Bytes) -> State
  if bytes.empty?
    return state
  end

  case state.clients.get(id)
    none -> return state
    some(client) ->
      cost = bytes.size + REPLY_OVERHEAD
      total = client.pending.add(0, cost)
      backlog = total > cost
      if backlog and total > MAX_PENDING_BYTES
        return drop(state, id)
      end

      case client.outbox.send(bytes, 0)
        ok(_) -> return state
        error(_) -> return drop(state, id)
      end
  end
end

def close(state: State, id: Int, farewell: Bytes) -> State
  return drop(send(state, id, farewell), id)
end

# Closing the outbox ends the writer task after it drained what is in it, and
# the writer closes the socket, which ends the reader.
def drop(state: State, id: Int) -> State
  case state.clients.get(id)
    none -> return state
    some(client) ->
      client.outbox.close
      return state.with(clients: state.clients.delete(id))
  end
end
