## Helpers shared by the tests of the commands.

import {Call, Command, Outcome} from "../src/commands/command"
import Dispatch from "../src/commands/dispatch"
import {Keyspace} from "../src/store/keyspace"
import Table from "../src/commands/table"

export def run_raw(name: Bytes, args: List[Bytes]) -> Outcome
  return Dispatch.execute(Table.build(), name, Call(keyspace: Keyspace(), args: args))
end

export def run_in(table: Map[String, Command], name: String, args: List[String]) -> Outcome
  call = Call(keyspace: Keyspace(), args: args.map do |a| a.bytes end)
  return Dispatch.execute(table, name.bytes, call)
end

export def run(name: String, args: List[String]) -> Outcome
  return run_in(Table.build(), name, args)
end
