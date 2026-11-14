## What the connections tell a shard. A connection waits for the answers of one
## chunk before it reads the next, so a shard sees a client's requests in order.

import {Client} from "../commands/engine"
import {Databases} from "../store/databases"

## The answer to `Run`: what `Runner.run_all` gives, without the store.
struct Answer
  client: Client
  reply: Bytes
  close: Bool
end

## What a shard lends: its data and its seed.
struct Loan
  databases: Databases
  seed: Int
end

## What a shard gets back: its new data (none: nothing changed) and seed.
struct Payback
  databases: Optional[Databases]
  seed: Int
end

enum Message
  ## Requests of one client on keys of this shard, in order; the answer goes
  ## back on the channel.
  Run(List[List[Bytes]], Client, Channel[Answer])
  ## Lend these keys (none: all of them) on the first channel, then handle
  ## nothing until they come back on the second.
  Lend(Optional[List[Bytes]], Channel[Loan], Channel[Payback])
  ## No request came for a while: time for the active expiry.
  Tick
end
