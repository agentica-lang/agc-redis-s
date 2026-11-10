## The accept loop: one task per client, and the supervision of the tasks.

import Connection from "connection"
import {Message} from "message"

ACCEPT_MS = 1000
## The id that `Task.monitor` reports for the store task; clients start at 1.
export STORE_ID = 0

## Runs until the store task stops. The listener belongs to the caller. A task
## that ends puts its id in `downs`; the loop then closes the client's socket
## (a crashed task never did) and tells the store task. The sockets stay owned
## here: `Task.spawn_owning` would also close the inbox with the connection.
export def accept_loop(listener: Listener, inbox: Channel[Message], downs: Channel[Int]) -> Void
  next_id = 1
  sockets: Map[Int, Socket] = {}
  while true
    case TCP.accept(listener, ACCEPT_MS)
      ok(socket) ->
        sockets = sockets.put(next_id, socket)
        start(socket, inbox, downs, next_id)
        next_id += 1
      error(_) -> nil
    end

    case reap(sockets, inbox, downs)
      none -> return
      some(left) -> sockets = left
    end
  end
end

def start(socket: Socket, inbox: Channel[Message], downs: Channel[Int], id: Int) -> Void
  task = Task.spawn(&Connection.serve, Connection.Link(socket: socket, inbox: inbox, id: id))
  Task.monitor(task, downs) do |_| id end
end

# Handles the tasks that ended; none when the store task is one of them.
def reap(sockets: Map[Int, Socket], inbox: Channel[Message], downs: Channel[Int]) -> Optional[Map[Int, Socket]]
  left = sockets
  while true
    case downs.recv(0)
      error(_) -> return some(left)
      ok(id) ->
        if id == STORE_ID
          return none
        end

        left = release(left, inbox, id)
    end
  end

  return some(left)
end

def release(sockets: Map[Int, Socket], inbox: Channel[Message], id: Int) -> Map[Int, Socket]
  case sockets.get(id)
    none -> return sockets
    some(socket) ->
      TCP.close(socket)
      Connection.send_close(inbox, id, "".bytes)
      return sockets.delete(id)
  end
end
