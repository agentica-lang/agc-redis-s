## The writer task of a connection: it sends what the store task puts in the
## outbox, in order. It ends when the outbox is closed and empty.

# `TCP.send_bytes` takes at most 1 MiB.
MAX_SEND = 1_048_576
BATCH = 64
POLL_MS = 1000
SEND_TIMEOUT_MS = 30_000

export struct Pipe
  socket: Socket
  outbox: Channel[Bytes]
end

export def run(pipe: Pipe) -> Void
  while true
    case pipe.outbox.recv(POLL_MS)
      ok(first) ->
        if not flush(pipe, first)
          break
        end

      error(_) ->
        if pipe.outbox.closed? and pipe.outbox.empty?
          break
        end
    end
  end
end

# Replies that are already waiting go out in one send: a pipelined client costs
# one system call, not one per reply.
def flush(pipe: Pipe, first: Bytes) -> Bool
  parts = [first]
  while parts.size < BATCH
    case pipe.outbox.recv(0)
      ok(more) -> parts = parts.push(more)
      error(_) -> break
    end
  end

  return send_all(pipe, Bytes.concat(parts))
end

# A failed send means the client is gone: closing the socket wakes the reader,
# and closing the outbox makes the store task drop the client.
def send_all(pipe: Pipe, bytes: Bytes) -> Bool
  rest = bytes
  while not rest.empty?
    case TCP.send_bytes(pipe.socket, rest.take(MAX_SEND), SEND_TIMEOUT_MS)
      ok(_) -> rest = rest.drop(MAX_SEND)
      error(_) ->
        TCP.close(pipe.socket)
        pipe.outbox.close
        return false
    end
  end

  return true
end
