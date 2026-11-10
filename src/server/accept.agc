## The accept loop: one task per client.

import Connection from "connection"
import {Message} from "message"

ACCEPT_MS = 1000

## Never returns. The listener belongs to the caller.
export def accept_loop(listener: Listener, inbox: Channel[Message]) -> Void
  next_id = 1
  while true
    case TCP.accept(listener, ACCEPT_MS)
      ok(socket) ->
        _ = Task.spawn(&Connection.serve, Connection.Link(socket: socket, inbox: inbox, id: next_id))
        next_id += 1
      error(_) -> nil
    end
  end
end
