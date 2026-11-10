## The store task with a clock of the test's own: it never sleeps and never
## reads the real time.

import Requests from "../../src/commands/session"
import {Store} from "../../src/commands/session"
import StoreTask from "../../src/server/store_task"
import Table from "../../src/commands/table"
import {request} from "../support"
import {fresh} from "../../src/store/databases"
import {Message} from "../../src/server/message"

def ran(store: Store, words: List[String]) -> Store
  table = Table.build()
  argv = words.map do |w| w.bytes end
  return Requests.run(table, Requests.join(store, 1), 1, argv, 0).store
end

def dbsize(store: Store, now: Int) -> Bytes
  return Requests.run(Table.build(), Requests.join(store, 1), 1, ["DBSIZE".bytes], now).reply
end

# The task reads the time only through the clock it is given: with a closed
# inbox it sweeps once, and a key past its deadline is dropped only when the
# fake time has passed SWEEP_MS since the last sweep (which starts at 0).
def test_the_sweep_follows_the_given_clock() -> Result[Void]
  empty = Requests.start(fresh())
  with_a = ran(empty, ["SET", "a", "1", "PX", "5"])
  seeded = ran(with_a, ["SET", "b", "1"])
  inbox: Channel[Message] = Channel.new(4)
  inbox.close
  early = StoreTask.serve(StoreTask.Setup(inbox: inbox, store: seeded, table: Table.build(), now_ms: &fixed_early))
  late = StoreTask.serve(StoreTask.Setup(inbox: inbox, store: seeded, table: Table.build(), now_ms: &fixed_late))
  try Test.eq(dbsize(early, 99).to_a, ":2\r\n".bytes.to_a)
  return Test.eq(dbsize(late, 1000).to_a, ":1\r\n".bytes.to_a)
end

def fixed_early() -> Int
  return Requests.SWEEP_MS - 1
end

def fixed_late() -> Int
  return 1000
end
