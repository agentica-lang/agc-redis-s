## One client connection: read bytes, cut them into requests, hand them to the
## store task. Replies do not come back here; the writer task sends them.

import {Read} from "../resp/reader"
import Reader from "../resp/reader"
import {Message} from "message"
import Writer from "writer"

# A client may stay quiet for as long as it likes. A receive timeout closes the
# socket, so the wait is a year.
IDLE_MS = 31_536_000_000
READ_BYTES = 65_536
SEND_TIMEOUT_MS = 1000
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
  outbox: Channel[Bytes] = Channel.new(1024)
  case link.inbox.send(Message.Open(link.id, outbox), SEND_TIMEOUT_MS)
    error(_) ->
      TCP.close(link.socket)
      return
    ok(_) -> nil
  end

  writer = Task.spawn(&Writer.run, Writer.Pipe(socket: link.socket, outbox: outbox))
  farewell = read_loop(link)
  _ = link.inbox.send(Message.Close(link.id, farewell), SEND_TIMEOUT_MS)
  case Task.await(writer, WRITER_WAIT_MS)
    Await.Done(_) -> nil
    Await.TimedOut -> Task.cancel(writer)
  end

  TCP.close(link.socket)
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
      Read.Invalid(text) -> return Drained.Broken("-ERR #{text}\r\n".bytes)
      Read.Skip(next) -> pos = next
      Read.Request(argv, next) ->
        _ = link.inbox.send(Message.Exec(link.id, argv), SEND_TIMEOUT_MS)
        pos = next
    end
  end

  return Drained.More(buffer)
end
