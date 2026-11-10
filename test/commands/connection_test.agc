import {Call} from "../../src/commands/command"
import Dispatch from "../../src/commands/dispatch"
import {Reply} from "../../src/resp/reply"
import {Keyspace} from "../../src/store/keyspace"
import Table from "../../src/commands/table"

def run(name: String, args: List[String]) -> Reply
  call = Call(keyspace: Keyspace(), args: args.map do |a| a.bytes end, now_ms: 0, client_id: 1)
  return Dispatch.execute(Table.build(), name.bytes, call).reply
end

def test_ping() -> Result[Void]
  try Test.eq(run("PING", []), Reply.Simple("PONG"))
  try Test.eq(run("ping", []), Reply.Simple("PONG"))
  return Test.eq(run("PiNg", ["hello"]), Reply.Bulk("hello".bytes))
end

def test_echo() -> Result[Void]
  try Test.eq(run("ECHO", ["a b"]), Reply.Bulk("a b".bytes))
  return Test.eq(run("echo", []), Reply.Error("ERR wrong number of arguments for 'echo' command"))
end

def test_ping_with_two_arguments() -> Result[Void]
  return Test.eq(run("PING", ["a", "b"]), Reply.Error("ERR wrong number of arguments for 'ping' command"))
end
