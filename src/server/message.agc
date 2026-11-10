## What connection tasks tell the store task. One channel carries all of them,
## so the store task sees one order, and a client's `Close` comes after the
## requests it sent.

export enum Message
  ## A new client; replies go to the outbox. The table holds under key 0 the
  ## bytes put in the outbox and not yet sent: the writer subtracts, the store
  ## task adds and checks the cap.
  Open(Int, Channel[Bytes], ATS[Int, Int])
  ## A request: the client id and the name and arguments as the client sent them.
  Exec(Int, List[Bytes])
  ## The client is gone or broke the protocol: send the last bytes, close.
  Close(Int, Bytes)
end
