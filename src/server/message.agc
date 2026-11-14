## What the connection handlers and dock's `on_close` tell the store actor. One
## inbox carries all of them, so the store actor sees one order, and a
## client's `Close` comes after the requests it sent. Replies go out through
## `Dock.send` with the `Conn` a message carries.

import Dock from "pkg/dock/dock"

enum Message
  ## A new client: it gets a session.
  Open(Dock.Conn)
  ## The requests one receive completed, in order: the client and, for each,
  ## the name and arguments as the client sent them. One message per chunk, so
  ## the store actor answers them with one `Dock.send`.
  Exec(Dock.Conn, List[List[Bytes]])
  ## The client sent EOF, broke the protocol or sent too much: send the last
  ## bytes, if any, then close. The handler handed the connection over, so it
  ## stays open until the store actor closes it, after the queued replies.
  Close(Dock.Conn, Bytes)
  ## The connection ended, whichever way (dock's `on_close`): the session goes.
  Gone(Int)
  ## No request came for a while: time for the active expiry.
  Tick
end
