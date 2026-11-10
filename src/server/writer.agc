## The writer task of a connection: it sends what the store task puts in the
## outbox, in order. It ends when the outbox is closed and empty.

# `TCP.send_bytes` takes at most 1 MiB.
MAX_SEND = 1_048_576
POLL_MS = 1000
SEND_TIMEOUT_MS = 30_000

export struct Pipe
  socket: Socket
  outbox: Channel[Bytes]
end

export def run(pipe: Pipe) -> Void
  while true
    case pipe.outbox.recv(POLL_MS)
      ok(bytes) ->
        if not send_all(pipe, bytes)
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

# A failed send means the client is gone: closing the outbox makes the store
# task drop the client, and the loop above then closes the socket.
def send_all(pipe: Pipe, bytes: Bytes) -> Bool
  rest = bytes
  while not rest.empty?
    case TCP.send_bytes(pipe.socket, rest.take(MAX_SEND), SEND_TIMEOUT_MS)
      ok(_) -> rest = rest.drop(MAX_SEND)
      error(_) ->
        pipe.outbox.close
        return false
    end
  end

  return true
end
