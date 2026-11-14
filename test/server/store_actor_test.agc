## The store actor with a clock of the test's own: it never sleeps and never
## reads the real time.

import Engine from "../../src/commands/engine"
import Runner from "../../src/commands/runner"
import {Store} from "../../src/commands/engine"
import StoreActor from "../../src/server/store_actor"
import Table from "../../src/commands/table"
import {request} from "../support"
import {fresh} from "../../src/store/databases"
import {Message} from "../../src/server/message"

def ran(store: Store, words: List[String]) -> Store
  table = Table.build()
  argv = words.map do |w| w.bytes end
  Runner.run(table, Engine.join(store, 1), 1, argv, 0).store
end

def dbsize(store: Store, now: Int) -> Bytes
  Runner.run(Table.build(), Engine.join(store, 1), 1, ["DBSIZE".bytes], now).reply
end

# The actor reads the time only through the clock it is given: a tick sweeps,
# and a key past its deadline is dropped only when the fake time has passed
# SWEEP_MS since the last sweep (which starts at 0).
def test_the_sweep_follows_the_given_clock() -> Result[Void]
  empty = Engine.start(fresh())
  with_a = ran(empty, ["SET", "a", "1", "PX", "5"])
  seeded = ran(with_a, ["SET", "b", "1"])
  early = ticked(seeded, &fixed_early)
  late = ticked(seeded, &fixed_late)
  try Test.eq(dbsize(early, 99).to_a, ":2\r\n".bytes.to_a)
  Test.eq(dbsize(late, 1000).to_a, ":1\r\n".bytes.to_a)
end

def ticked(store: Store, clock: Fn[Int]) -> Store
  setup = StoreActor.Setup(store: store, table: Table.build(), now_ms: clock)
  StoreActor.handle(StoreActor.first(setup), Message.Tick).store
end

def fixed_early() -> Int = Engine.SWEEP_MS - 1

def fixed_late() -> Int = 1000
