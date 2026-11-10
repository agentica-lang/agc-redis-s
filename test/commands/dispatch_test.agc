import {Call, Command, Outcome, reply} from "../../src/commands/command"
import {Reply} from "../../src/resp/reply"
import {run, run_in, run_raw} from "../support"

def count_args(call: Call) -> Outcome
  return reply(call, Reply.Integer(call.args.size))
end

# One command of fixed arity (name and one argument) and one of variable arity
# (name and at least one argument), to test the arity rule on its own.
def table() -> Map[String, Command]
  return {
    "fixed": Command(name: "fixed", arity: 2, handler: &count_args),
    "atleast": Command(name: "atleast", arity: -2, handler: &count_args),
  }
end

def error_text(text: String) -> List[Reply]
  return [Reply.Error(text.bytes)]
end

def test_fixed_arity() -> Result[Void]
  try Test.eq(run_in(table(), "fixed", ["a"]).replies, [Reply.Integer(1)])
  try Test.eq(run_in(table(), "fixed", []).replies, error_text("ERR wrong number of arguments for 'fixed' command"))
  return Test.eq(
    run_in(table(), "FIXED", ["a", "b"]).replies,
    error_text("ERR wrong number of arguments for 'fixed' command"),
  )
end

def test_variable_arity() -> Result[Void]
  try Test.eq(run_in(table(), "atleast", ["a", "b", "c"]).replies, [Reply.Integer(3)])
  return Test.eq(
    run_in(table(), "atleast", []).replies,
    error_text("ERR wrong number of arguments for 'atleast' command"),
  )
end

def test_unknown_command() -> Result[Void]
  try Test.eq(
    run("FOO", ["x", "y z"]).replies,
    error_text("ERR unknown command 'FOO', with args beginning with: 'x' 'y z' "),
  )

  return Test.eq(run("FOO", []).replies, error_text("ERR unknown command 'FOO', with args beginning with: "))
end

def letters(n: Int) -> String
  return (1..n).to_a.map do |_| "x" end.join("")
end

def test_unknown_command_keeps_bytes_and_cuts_long_text() -> Result[Void]
  raw = Bytes.from_list([255, 13, 10]).unwrap!
  prefix = "ERR unknown command 'FOO', with args beginning with: '".bytes
  try Test.eq(run_raw("FOO".bytes, [raw]).replies, [Reply.Error(prefix + raw + "' ".bytes)])
  expected = "ERR unknown command '#{letters(128)}', with args beginning with: '#{letters(128)}' "
  return Test.eq(run(letters(300), [letters(300)]).replies, error_text(expected))
end
