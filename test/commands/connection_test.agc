import {Effect} from "../../src/commands/command"
import {Reply} from "../../src/resp/reply"
import {run} from "../support"

def test_ping() -> Result[Void]
  try Test.eq(run("PING", []).replies, [Reply.Simple("PONG")])
  try Test.eq(run("ping", []).replies, [Reply.Simple("PONG")])
  return Test.eq(run("PiNg", ["hello"]).replies, [Reply.Bulk("hello".bytes)])
end

def test_ping_with_two_arguments() -> Result[Void]
  expected = [Reply.Error("ERR wrong number of arguments for 'ping' command".bytes)]
  return Test.eq(run("PING", ["a", "b"]).replies, expected)
end

def test_echo() -> Result[Void]
  try Test.eq(run("ECHO", ["a b"]).replies, [Reply.Bulk("a b".bytes)])
  return Test.eq(run("echo", []).replies, [Reply.Error("ERR wrong number of arguments for 'echo' command".bytes)])
end

def test_quit_replies_then_closes() -> Result[Void]
  outcome = run("QUIT", [])
  try Test.eq(outcome.replies, [Reply.Simple("OK")])
  return Test.eq(outcome.effects, [Effect.Close])
end
