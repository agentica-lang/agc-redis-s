import {Call} from "../../src/commands/command"
import Dispatch from "../../src/commands/dispatch"
import {Reply} from "../../src/resp/reply"
import {Keyspace} from "../../src/store/keyspace"
import Table from "../../src/commands/table"

def run(name: String, args: List[String]) -> Reply
  call = Call(keyspace: Keyspace(), args: args.map do |a| a.bytes end, now_ms: 0, client_id: 1)
  return Dispatch.execute(Table.build(), name.bytes, call).reply
end

def test_wrong_arity() -> Result[Void]
  return Test.eq(run("PING", ["a", "b", "c"]), Reply.Error("ERR wrong number of arguments for 'ping' command"))
end

def test_unknown_command() -> Result[Void]
  expected = "ERR unknown command 'FOO', with args beginning with: 'x' 'y z' "
  try Test.eq(run("FOO", ["x", "y z"]), Reply.Error(expected))
  return Test.eq(run("FOO", []), Reply.Error("ERR unknown command 'FOO', with args beginning with: "))
end
