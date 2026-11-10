## The accept loop: one task per client, and the supervision of the tasks.

import Connection from "connection"
import {Message} from "message"

ACCEPT_MS = 1000

## Runs until the store task stops, which closes `inbox` (see main). A task
## that ends puts a code in `downs`: its id when it crashed, the negative id
## when it ended on its own. For a crashed one the loop closes the socket
## (a crashed task never did) and tells the store task. The sockets stay owned
## here: `Task.spawn_owning` would also close the inbox with the connection.
export def accept_loop(listener: Listener, inbox: Channel[Message], downs: Channel[Int]) -> Void
  next_id = 1
  sockets: Map[Int, Socket] = {}
  while not inbox.closed?
    case TCP.accept(listener, ACCEPT_MS)
      ok(socket) ->
        sockets = sockets.put(next_id, socket)
        start(socket, inbox, downs, next_id)
        next_id += 1
      error(_) -> nil
    end

    sockets = reap(sockets, inbox, downs)
  end

  for socket in sockets.values
    TCP.close(socket)
  end
end

def start(socket: Socket, inbox: Channel[Message], downs: Channel[Int], id: Int) -> Void
  task = Task.spawn(&Connection.serve, Connection.Link(socket: socket, inbox: inbox, id: id))
  Task.monitor(task, downs) do |down| down_code(id, down) end
end

def down_code(id: Int, down: TaskDown) -> Int
  case down.reason
    TaskExit.Ok -> return -id
    TaskExit.Crashed -> return id
    TaskExit.Cancelled -> return id
  end
end

def reap(sockets: Map[Int, Socket], inbox: Channel[Message], downs: Channel[Int]) -> Map[Int, Socket]
  left = sockets
  while true
    case downs.recv(0)
      error(_) -> return left
      ok(code) -> left = release(left, inbox, code)
    end
  end

  return left
end

def release(sockets: Map[Int, Socket], inbox: Channel[Message], code: Int) -> Map[Int, Socket]
  id = code.abs
  case sockets.get(id)
    none -> return sockets
    some(socket) ->
      if code > 0
        TCP.close(socket)
        Connection.send_close(inbox, id, "".bytes)
      end

      return sockets.delete(id)
  end
end
