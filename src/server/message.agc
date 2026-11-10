## What connection tasks tell the store task. One channel carries all of them,
## so the store task sees one order, and a client's `Close` comes after the
## requests it sent.

export enum Message
  ## A new client; replies for it go to the outbox.
  Open(Int, Channel[Bytes])
  ## A request: the client id and the name and arguments as the client sent them.
  Exec(Int, List[Bytes])
  ## The client is gone or broke the protocol: send the last bytes, close.
  Close(Int, Bytes)
end
