import {Call, Command, Outcome, reply} from "../../src/commands/command"
import {Reply} from "../../src/resp/reply"
import {run_in} from "../support"

def count_args(call: Call) -> Outcome = reply(call, Reply.Integer(call.args.size))

def error_text(text: String) -> List[Reply] = [Reply.Error(text.bytes)]

def letters(n: Int) -> String = (1..n).to_a.map do |_| "x" end.join("")

# One command of fixed arity (name and one argument) and one of variable arity
# (name and at least one argument), to test the arity rule on its own.
def test_arity_rule() -> Result[Void]
  table = {
    "fixed": Command(name: "fixed", arity: 2, handler: &count_args),
    "atleast": Command(name: "atleast", arity: -2, handler: &count_args),
  }

  bad = error_text("ERR wrong number of arguments for 'fixed' command")
  try Test.eq(run_in(table, "fixed", ["a"]).replies, [Reply.Integer(1)])
  try Test.eq(run_in(table, "FIXED", ["a", "b"]).replies, bad)
  try Test.eq(run_in(table, "atleast", ["a", "b", "c"]).replies, [Reply.Integer(3)])
  Test.eq(run_in(table, "atleast", []).replies, error_text("ERR wrong number of arguments for 'atleast' command"))
end

# Redis cuts the command name and the echoed arguments at 128 bytes.
def test_unknown_command_text_is_cut() -> Result[Void]
  expected = "ERR unknown command '#{letters(128)}', with args beginning with: '#{letters(128)}' "
  Test.eq(run_in({}, letters(300), [letters(300)]).replies, error_text(expected))
end
