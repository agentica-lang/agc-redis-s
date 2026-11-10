## One client connection, the handler dock runs in a task of its own: read
## bytes, cut them into requests, hand them to the store task. The replies come
## back through `Dock.send` from the store task.

import Dock from "pkg/dock/dock"
import Requests from "../commands/session"
import {Ending} from "../resp/stream"
import {Fed} from "../resp/stream"
import Stream from "../resp/stream"
import {Message} from "message"

READ_BYTES = 65_536
# How long a request waits for room in the inbox of the store task.
INBOX_SEND_MS = 1000

enum Drained
  More(Stream.Stream)
  Broken(Bytes)
end

## Serves the client until it leaves.
export def serve(conn: Dock.Conn, inbox: Channel[Message]) -> Void
  case inbox.send(Message.Open(conn), INBOX_SEND_MS)
    error(_) -> return
    ok(_) -> nil
  end

  case read_loop(conn, inbox)
    none -> return
    some(farewell) ->
      # The store task sends the farewell after the replies that are still in
      # the inbox and closes the connection, which ends the receive below. Were
      # this handler to return first, dock would close the socket before them.
      case inbox.send(Message.Close(conn, farewell), INBOX_SEND_MS)
        ok(_) -> wait_for_close(conn)
        error(_) -> nil
      end
  end
end

## dock calls this when the connection ended. The store task must learn of it,
## or the session stays for good: retry until the message is in or nobody will
## read it.
export def gone(inbox: Channel[Message], id: Int) -> Void
  while true
    case inbox.send(Message.Gone(id), INBOX_SEND_MS)
      ok(_) -> return
      error(_) ->
        if inbox.closed?
          return
        end
    end
  end
end

# `none` when the client left or the connection failed; the bytes to send
# before closing (empty for none) when the server ends it.
def read_loop(conn: Dock.Conn, inbox: Channel[Message]) -> Optional[Bytes]
  stream = Stream.start()
  while true
    case Dock.recv(conn, READ_BYTES)
      error(_) -> return none
      ok(chunk) ->
        if chunk.empty?
          return none
        end

        case drain(conn, inbox, Stream.feed(stream, chunk))
          Drained.More(next) -> stream = next
          Drained.Broken(farewell) -> return some(farewell)
        end
    end
  end

  return none
end

def wait_for_close(conn: Dock.Conn) -> Void
  while true
    case Dock.recv(conn, READ_BYTES)
      error(_) -> return
      ok(chunk) ->
        if chunk.empty?
          return
        end
    end
  end
end

# Sends every whole request the chunk completed, in order.
def drain(conn: Dock.Conn, inbox: Channel[Message], fed: Fed) -> Drained
  for argv in fed.requests
    # A request that is lost would shift every later reply: end instead.
    case inbox.send(Message.Exec(conn, argv), INBOX_SEND_MS)
      error(_) -> return Drained.Broken("".bytes)
      ok(_) -> nil
    end
  end

  case fed.ending
    Ending.Open -> return Drained.More(fed.stream)
    Ending.Invalid(text) -> return Drained.Broken(Requests.protocol_error_reply(text))
    Ending.Overflow -> return Drained.Broken("".bytes)
  end
end
