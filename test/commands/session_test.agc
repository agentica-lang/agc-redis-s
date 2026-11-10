import {Call, Command, Outcome} from "../../src/commands/command"
import Requests from "../../src/commands/session"
import {Executed} from "../../src/commands/session"
import Table from "../../src/commands/table"
import {Reply} from "../../src/resp/reply"
import {Session} from "../../src/session/session"
import {fresh, space_at} from "../../src/store/databases"
import {put, size} from "../../src/store/keyspace"
import {Value} from "../../src/store/value"

# A handler that writes, so the keyspace that comes back can be checked. There
# is no data command yet.
def store_key(call: Call) -> Outcome
  keyspace = put(call.keyspace, call.args[0], Value.Str(call.args[0]))
  return Outcome(keyspace: keyspace, session: call.session, replies: [Reply.Simple("OK")])
end

def run(table: Map[String, Command], state: Executed, line: List[String]) -> Executed
  return Requests.execute_request(table, state.databases, state.session, line.map do |w| w.bytes end, 0, 1)
end

# The new keyspace of a command goes back to the database it ran in, also for
# SELECT, which changes the session in the same request.
def test_a_write_lands_in_the_selected_database() -> Result[Void]
  table = Table.build().put("store", Command(name: "store", arity: 2, handler: &store_key))
  state = Executed(databases: fresh(), session: Session(), reply: "".bytes, close: false)
  for line in [["store", "a"], ["select", "5"], ["store", "b"], ["store", "c"], ["select", "0"]]
    state = run(table, state, line)
  end

  try Test.eq(size(space_at(state.databases, 0)), 1)
  try Test.eq(size(space_at(state.databases, 5)), 2)
  return Test.eq(size(space_at(state.databases, 1)), 0)
end
