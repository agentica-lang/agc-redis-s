import Engine from "../../src/commands/engine"
import Runner from "../../src/commands/runner"
import {Call, Command, Outcome, write} from "../../src/commands/command"
import {Store} from "../../src/commands/engine"
import Table from "../../src/commands/table"
import {Reply} from "../../src/resp/reply"
import {fresh, space_at} from "../../src/store/databases"
import Generator from "../../src/store/generator"
import {put, size} from "../../src/store/keyspace"
import {Value} from "../../src/store/value"

# A handler that writes, so the keyspace that comes back can be checked. There
# is no data command yet.
def store_key(call: Call) -> Outcome
  keyspace = put(call.keyspace, call.args[0], Value.Str(call.args[0]), 0)
  return write(call, keyspace, Reply.Simple("OK"))
end

def run(table: Map[String, Command], store: Store, line: List[String]) -> Store
  return Runner.run(table, store, 1, line.map do |w| w.bytes end, 0).store
end

# The new keyspace of a command goes back to the database it ran in, also for
# SELECT, which changes the session in the same request.
def test_a_write_lands_in_the_selected_database() -> Result[Void]
  row = Command(name: "store", arity: 2, handler: &store_key)
  table = Table.build().put("store", row)
  start = Engine.start(fresh())
  state = Engine.join(start, 1)
  for line in [["store", "a"], ["select", "5"], ["store", "b"], ["store", "c"], ["select", "0"]]
    state = run(table, state, line)
  end

  try Test.eq(size(space_at(state.databases, 0)), 1)
  try Test.eq(size(space_at(state.databases, 5)), 2)
  return Test.eq(size(space_at(state.databases, 1)), 0)
end

# A sweep is due every 100 ms, and when the clock went back (a negative gap).
def test_sweep_is_due_by_time_and_after_a_clock_step_back() -> Result[Void]
  try Test.eq(Engine.sweep_due?(1000, 1099), false)
  try Test.eq(Engine.sweep_due?(1000, 1100), true)
  try Test.eq(Engine.sweep_due?(1000, 999), true)
  return Test.eq(Engine.sweep_due?(1000, 1000), false)
end

# A request takes two steps of the generator, `Call.random` having both: the
# next request does not see the numbers of the one before.
def test_a_request_advances_the_seed_by_two_steps() -> Result[Void]
  started = Engine.start(fresh())
  state = Engine.join(started, 1)
  done = Runner.run(Table.build(), state, 1, ["PING".bytes], 7)
  first = Generator.advance(state.seed, 7)
  return Test.eq(done.store.seed, Generator.advance(first, 7))
end
