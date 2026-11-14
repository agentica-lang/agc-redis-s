## One client connection, the handler dock runs in a task of its own: read
## bytes, cut them into requests, hand them to the store actor. The replies come
## back through `Dock.send` from the store actor.

import Actor from "std/actor"
import Dock from "pkg/dock/dock"
import Writer from "../resp/writer"
import {Ending} from "../resp/stream"
import {Fed} from "../resp/stream"
import Stream from "../resp/stream"
import {Message} from "message"

## Serves the client until it leaves.
def serve(conn: Dock.Conn, store: Address[Message]) -> Void
  case Actor.cast(store, Message.Open(conn), INBOX_SEND_MS)
    error(_) -> return
    ok(_) -> nil
  end

  case read_loop(conn, store)
    none -> return
    some(farewell) -> hand_over_to_store(conn, store, farewell)
  end
end

## dock calls this when the connection ended. The store actor must learn of it,
## or the session stays for good: retry until the message is in or nobody will
## read it.
def gone(store: Address[Message], id: Int) -> Void
  while true
    case Actor.cast(store, Message.Gone(id), INBOX_SEND_MS)
      ok(_) -> return
      error(e) -> return if e.is_a?("channel.gone")
    end
  end
end

private

READ_BYTES = 65_536

# How long a request waits for room in the inbox of the store actor.
INBOX_SEND_MS = 1000

enum Drained
  More(Stream.Stream)
  Broken(Bytes)
end

# The store actor sends the farewell after the replies that are still in the
# inbox, then closes the connection. Were this handler to return without the
# hand-over, dock would close the socket before them: a client that sent its
# requests and shut its side down would lose the replies. The hand-over keeps
# the connection open after the handler returned; `Dock.close` in the store
# actor ends it.
def hand_over_to_store(conn: Dock.Conn, store: Address[Message], farewell: Bytes) -> Void
  Dock.hand_over(conn)
  case Actor.cast(store, Message.Close(conn, farewell), INBOX_SEND_MS)
    ok(_) -> nil
    # Nobody will close it for us.
    error(_) -> Dock.close(conn)
  end
end

# `none` when the connection failed; the bytes to send before closing (empty
# when the client just sent EOF or the server drops it) otherwise.
def read_loop(conn: Dock.Conn, store: Address[Message]) -> Optional[Bytes]
  stream = Stream.start()
  while true
    case Dock.recv(conn, READ_BYTES)
      error(_) -> return none
      ok(chunk) ->
        return some("".bytes) if chunk.empty?

        case drain(conn, store, Stream.feed(stream, chunk))
          Drained.More(next) -> stream = next
          Drained.Broken(farewell) -> return some(farewell)
        end
    end
  end

  none
end

# Sends every whole request the chunk completed, in order, as one message.
def drain(conn: Dock.Conn, store: Address[Message], fed: Fed) -> Drained
  if not fed.requests.empty?
    # Requests that are lost would shift every later reply: end instead.
    case Actor.cast(store, Message.Exec(conn, fed.requests), INBOX_SEND_MS)
      error(_) -> return Drained.Broken("".bytes)
      ok(_) -> nil
    end
  end

  case fed.ending
    Ending.Open -> Drained.More(fed.stream)
    Ending.Invalid(text) -> Drained.Broken(Writer.protocol_error(text))
    Ending.Overflow -> Drained.Broken("".bytes)
  end
end
