## The writer task of a connection: it sends what the store task puts in the
## outbox, in order. It ends when the outbox is closed and empty.

import {REPLY_OVERHEAD} from "message"

# `TCP.send_bytes` takes at most 1 MiB.
MAX_SEND = 1_048_576
POLL_MS = 1000
BATCH = 256
# A client that takes nothing for this long is gone; its socket is closed.
WRITE_TIMEOUT_MS = 5000

export struct Pipe
  socket: Socket
  outbox: Channel[Bytes]
  pending: ATS[Int, Int]
end

export def run(pipe: Pipe) -> Void
  while true
    case pipe.outbox.recv(POLL_MS)
      ok(first) ->
        parts = more_replies([first], pipe)
        sent = send_all(pipe, Bytes.concat(parts))
        _ = pipe.pending.add(0, -parts.reduce(0) do |sum, part| sum + part.size + REPLY_OVERHEAD end)
        if not sent
          break
        end

      error(_) ->
        if pipe.outbox.closed? and pipe.outbox.empty?
          break
        end
    end
  end

  # Whatever ended the loop, the client is done: this wakes the reader too.
  TCP.close(pipe.socket)
end

# Replies that are already waiting go out in one send: a pipelined client costs
# one system call per batch, not one per reply.
def more_replies(parts: List[Bytes], pipe: Pipe) -> List[Bytes]
  batch = parts
  while batch.size < BATCH
    case pipe.outbox.recv(0)
      ok(more) -> batch = batch.push(more)
      error(_) -> return batch
    end
  end

  return batch
end

# A failed send means the client is gone: closing the outbox makes the store
# task drop the client, and the loop above then closes the socket.
def send_all(pipe: Pipe, bytes: Bytes) -> Bool
  rest = bytes
  while not rest.empty?
    case TCP.send_bytes(pipe.socket, rest.take(MAX_SEND), WRITE_TIMEOUT_MS)
      ok(_) -> rest = rest.drop(MAX_SEND)
      error(_) ->
        pipe.outbox.close
        return false
    end
  end

  return true
end
