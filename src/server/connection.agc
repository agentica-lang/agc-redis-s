## One client connection: read bytes, cut them into requests, hand them to the
## store task. The writer task sends the replies.

import Session from "../commands/session"
import {Read} from "../resp/reader"
import Reader from "../resp/reader"
import {OUTBOX_SLOTS, Message} from "message"
import Writer from "writer"

# A receive timeout closes the socket and there is no wait-forever form: a year.
IDLE_MS = 31_536_000_000
READ_BYTES = 65_536
# How long a request waits for room in the inbox of the store task.
INBOX_SEND_MS = 1000
WRITER_WAIT_MS = 5000

export struct Link
  socket: Socket
  inbox: Channel[Message]
  id: Int
end

enum Drained
  More(Bytes)
  Broken(Bytes)
end

## Serves the client until it leaves; runs as the client's own task.
export def serve(link: Link) -> Void
  outbox: Channel[Bytes] = Channel.new(OUTBOX_SLOTS)
  pending: ATS[Int, Int] = ATS.new()
  case link.inbox.send(Message.Open(link.id, outbox, pending), INBOX_SEND_MS)
    error(_) ->
      TCP.close(link.socket)
      return
    ok(_) -> nil
  end

  writer = Task.spawn(&Writer.run, Writer.Pipe(socket: link.socket, outbox: outbox, pending: pending))
  farewell = read_loop(link)
  send_close(link.inbox, link.id, farewell)
  case Task.await(writer, WRITER_WAIT_MS)
    Await.Done(_) -> nil
    Await.TimedOut -> Task.cancel(writer)
  end

  TCP.close(link.socket)
end

## The store task must learn that the client left, or its outbox stays in the
## table for good: retry until the message is in or nobody will read it.
export def send_close(inbox: Channel[Message], id: Int, farewell: Bytes) -> Void
  while true
    case inbox.send(Message.Close(id, farewell), INBOX_SEND_MS)
      ok(_) -> return
      error(_) ->
        if inbox.closed?
          return
        end
    end
  end
end

# Returns the bytes to send before closing: empty when the client just left.
def read_loop(link: Link) -> Bytes
  buffer = "".bytes
  while true
    case TCP.recv_bytes(link.socket, READ_BYTES, IDLE_MS)
      error(_) -> return "".bytes
      ok(chunk) ->
        if chunk.empty?
          return "".bytes
        end

        case drain(link, buffer + chunk)
          Drained.More(rest) -> buffer = rest
          Drained.Broken(farewell) -> return farewell
        end
    end
  end

  return "".bytes
end

# Sends every whole request in the buffer; keeps the unfinished tail.
def drain(link: Link, buffer: Bytes) -> Drained
  pos = 0
  while true
    case Reader.read_request(buffer, pos)
      Read.Incomplete -> return Drained.More(buffer.drop(pos))
      Read.Invalid(text) -> return Drained.Broken(Session.protocol_error_reply(text))
      Read.Skip(next) -> pos = next
      Read.Request(argv, next) ->
        # A request that is lost would shift every later reply: end instead.
        case link.inbox.send(Message.Exec(link.id, argv), INBOX_SEND_MS)
          error(_) -> return Drained.Broken("".bytes)
          ok(_) -> pos = next
        end
    end
  end

  return Drained.More(buffer)
end
