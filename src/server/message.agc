## What the connections tell a shard. A connection waits for the answers of one
## chunk before it reads the next, so a shard sees a client's requests in order.

import {Client} from "../commands/engine"
import {Databases, Size} from "../store/databases"

## What a shard lends: its data, its seed, and until when (`Time.monotonic_ms`)
## it waits for them to come back; after that it keeps what it has.
struct Loan
  databases: Databases
  seed: Int
  until: Int
end

## What a shard gets back: its new data (none: nothing changed) and seed.
struct Payback
  databases: Optional[Databases]
  seed: Int
end

enum Message
  ## Requests of one client on keys of this shard, in order; the replies go
  ## back on the channel. Only requests that run at the connection change the
  ## session or close it, so the reply bytes are all it needs.
  Run(List[List[Bytes]], Client, Channel[Bytes])
  ## The size of each database, for DBSIZE and INFO.
  Sizes(Channel[List[Size]])
  ## Lend these keys (none: all of them) on the first channel, then handle
  ## nothing until they come back on the second.
  Lend(Optional[List[Bytes]], Channel[Loan], Channel[Payback])
end
