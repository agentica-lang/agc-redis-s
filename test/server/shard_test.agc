## A shard with a clock of the test's own: it never reads the real time.

import Actor from "std/actor"
import Databases from "../../src/store/databases"
import Engine from "../../src/commands/engine"
import Runner from "../../src/commands/runner"
import {Store} from "../../src/commands/engine"
import Shard from "../../src/server/shard"
import Table from "../../src/commands/table"
import {fresh} from "../../src/store/databases"
import {Message} from "../../src/server/message"

CLOCK: ATS[String, Int] = ATS.new()

def ran(store: Store, words: List[String]) -> Store
  table = Table.build()
  argv = words.map do |w| w.bytes end
  Runner.run(table, store, Engine.client(1), argv, 0).store
end

def dbsize(store: Store, now: Int) -> Bytes
  Runner.run(Table.build(), store, Engine.client(1), ["DBSIZE".bytes], now).reply
end

# The receive timeout sweeps an idle shard. The clock jumps to 1000, where the
# key of deadline 50 is past, and only the timeout can see that time: it is back
# at 0 before the next message, whose own sweep would keep the key.
def test_an_idle_shard_sweeps_on_its_timeout() -> Result[Void]
  CLOCK.put("now", 1000)
  seeded = ran(Engine.start(fresh()), ["SET", "a", "1", "PX", "50"])
  shard = Shard.start(Shard.Setup(store: seeded, table: Table.build(), now_ms: &shared_clock), 16)
  Task.sleep(3 * Engine.SWEEP_MS)
  CLOCK.put("now", 0)
  answer: Channel[List[Databases.Size]] = Channel.new(1)
  try shard.address.send(Message.Sizes(answer), 1000)
  sizes = try answer.recv(1000)
  try Test.eq(sizes[0].keys, 0)
  Actor.stop(shard, 1000)
end

def shared_clock() -> Int = CLOCK.get("now").unwrap_or(0)

# A shard reads the time only through the clock it is given: an idle wake sweeps,
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
  setup = Shard.Setup(store: store, table: Table.build(), now_ms: clock)
  Shard.idle(Shard.first(setup)).store
end

def fixed_early() -> Int = Engine.SWEEP_MS - 1

def fixed_late() -> Int = 1000
