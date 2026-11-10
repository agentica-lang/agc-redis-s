## The task that owns the data. It takes one message at a time, so a command
## never sees a half-done one, as with the single thread of Redis.

import {Call, Command} from "../commands/command"
import Dispatch from "../commands/dispatch"
import Table from "../commands/table"
import Clock from "clock"
import {Message} from "message"
import Writer from "../resp/writer"
import {Keyspace} from "../store/keyspace"

# The reply of a client that does not drain its outbox in this time is lost
# and the client dropped, so one slow client cannot stall the others.
SEND_TIMEOUT_MS = 1000
POLL_MS = 1000

struct State
  keyspace: Keyspace
  table: Map[String, Command]
  clients: Map[Int, Channel[Bytes]]
end

## Runs until `inbox` is closed.
export def run(inbox: Channel[Message]) -> Void
  state = State(keyspace: Keyspace(), table: Table.build(), clients: {})
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
    Message.Open(id, outbox) -> return state.with(clients: state.clients.put(id, outbox))
    Message.Exec(id, argv) -> return exec(state, id, argv)
    Message.Close(id, farewell) -> return close(state, id, farewell)
  end
end

def exec(state: State, id: Int, argv: List[Bytes]) -> State
  call = Call(keyspace: state.keyspace, args: argv.drop(1), now_ms: Clock.now_ms(), client_id: id)
  outcome = Dispatch.execute(state.table, argv[0], call)
  return send(state.with(keyspace: outcome.keyspace), id, Writer.encode(outcome.reply))
end

def send(state: State, id: Int, bytes: Bytes) -> State
  case state.clients.get(id)
    none -> return state
    some(outbox) ->
      case outbox.send(bytes, SEND_TIMEOUT_MS)
        ok(_) -> return state
        error(_) -> return drop(state, id)
      end
  end
end

def close(state: State, id: Int, farewell: Bytes) -> State
  next = state
  if not farewell.empty?
    next = send(state, id, farewell)
  end

  return drop(next, id)
end

# Closing the outbox ends the writer task after it drained what is in it.
def drop(state: State, id: Int) -> State
  case state.clients.get(id)
    none -> return state
    some(outbox) ->
      outbox.close
      return state.with(clients: state.clients.delete(id))
  end
end
