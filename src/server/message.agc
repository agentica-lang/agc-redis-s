## What connection tasks tell the store task. One channel carries all of them,
## so the store task sees one order, and a client's `Close` comes after the
## requests it sent.

# Phase 0 cap on the replies a client has not read yet. Over it the client is
# dropped, so a client that never reads cannot make the server grow. Redis has
# no cap for normal clients by default; this is a stricter choice.
export MAX_PENDING_BYTES = 8_388_608
# Each queued reply counts this much more than its size, so many tiny replies
# also reach the cap.
export REPLY_OVERHEAD = 64
# Room for every reply that fits under the cap, so only the cap drops a client
# and a full outbox cannot happen first.
export OUTBOX_SLOTS = 131_072

export enum Message
  ## A new client; replies go to the outbox. The table holds under key 0 the
  ## bytes (plus `REPLY_OVERHEAD` each) put in the outbox and not yet sent: the writer subtracts, the store
  ## task adds and checks the cap.
  Open(Int, Channel[Bytes], ATS[Int, Int])
  ## A request: the client id and the name and arguments as the client sent them.
  Exec(Int, List[Bytes])
  ## The client is gone or broke the protocol: send the last bytes, close.
  Close(Int, Bytes)
end
