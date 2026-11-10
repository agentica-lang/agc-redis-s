## What the connection handlers and dock's `on_close` tell the store task. One
## channel carries all of them, so the store task sees one order, and a
## client's `Close` comes after the requests it sent. Replies go out through
## `Dock.send` with the `Conn` a message carries.

import Dock from "pkg/dock/dock"

export enum Message
  ## A new client: it gets a session.
  Open(Dock.Conn)
  ## A request: the client and the name and arguments as the client sent them.
  Exec(Dock.Conn, List[Bytes])
  ## The client sent EOF, broke the protocol or sent too much: send the last
  ## bytes, if any, then close, then tell the handler (the channel), which
  ## waits so that dock does not close the socket before the replies.
  Close(Dock.Conn, Bytes, Channel[Bool])
  ## The connection ended, whichever way (dock's `on_close`): the session goes.
  Gone(Int)
end
