## LMOVE, RPOPLPUSH and LMPOP.

import Table from "../../src/commands/table"
import {run_requests, talk} from "../support"
import {fresh} from "../../src/store/databases"
import Prop from "pkg/prop/prop"

WRONGTYPE = "-WRONGTYPE Operation against a key holding the wrong kind of value\r\n"
SYNTAX = "-ERR syntax error\r\n"
NUMKEYS = "-ERR numkeys should be greater than 0\r\n"
COUNT = "-ERR count should be greater than 0\r\n"

struct Step
  held: List[List[String]]
  reply: String
end

def ask(requests: List[List[String]]) -> String = talk(requests).reply.decode("latin-1").unwrap!

def bulk(text: String) -> String = "$#{text.size}\r\n#{text}\r\n"

def strings(items: List[String]) -> String = "*#{items.size}\r\n#{items.map do |item| bulk(item) end.join("")}"

def popped(key: String, items: List[String]) -> String = "*2\r\n#{bulk(key)}#{strings(items)}"

# The element leaves one end and joins one end of the destination, which may be
# the same list (a rotation) and is created when missing. The words are read
# before the keys; a missing source answers nil even when the destination has
# another type; the source's type is checked before the destination's.
def test_lmove_and_rpoplpush() -> Result[Void]
  got = ask([
    ["RPUSH", "a", "1", "2", "3"],
    ["LMOVE", "a", "b", "LEFT", "RIGHT"],
    ["LMOVE", "a", "b", "right", "left"],
    ["RPOPLPUSH", "b", "a"],
    ["LRANGE", "a", "0", "-1"],
    ["LMOVE", "a", "a", "left", "right"],
    ["LRANGE", "a", "0", "-1"],
    ["RPOPLPUSH", "a", "a"],
    ["LRANGE", "a", "0", "-1"],
    ["RPUSH", "one", "x"],
    ["LMOVE", "one", "one", "LEFT", "LEFT"],
    ["LLEN", "one"],
    ["SET", "s", "v"],
    ["LMOVE", "none", "s", "LEFT", "LEFT"],
    ["LMOVE", "a", "s", "LEFT", "LEFT"],
    ["LMOVE", "s", "a", "LEFT", "LEFT"],
    ["LMOVE", "none", "b", "UP", "LEFT"],
    ["LMOVE", "none", "b", "LEFT", "UP"],
    ["LMOVE", "a", "b", "LEFT"],
    ["LMOVE", "one", "c", "RIGHT", "LEFT"],
    ["EXISTS", "one"],
    ["LRANGE", "c", "0", "-1"],
    ["RPOPLPUSH", "none", "c"],
  ])

  want = [
    ":3\r\n",
    bulk("1"),
    bulk("3"),
    bulk("1"),
    strings(["1", "2"]),
    bulk("1"),
    strings(["2", "1"]),
    bulk("1"),
    strings(["1", "2"]),
    ":1\r\n",
    bulk("x"),
    ":1\r\n",
    "+OK\r\n",
    "$-1\r\n",
    WRONGTYPE,
    WRONGTYPE,
    SYNTAX,
    SYNTAX,
    "-ERR wrong number of arguments for 'lmove' command\r\n",
    bulk("x"),
    ":0\r\n",
    strings(["x"]),
    "$-1\r\n",
  ]

  Test.eq(got, want.join(""))
end

# A live source and a live destination keep their deadlines, a source left
# empty loses its key and deadline, a new destination has none, and a list of
# one element moved onto itself keeps its deadline.
def test_a_move_keeps_the_deadlines() -> Result[Void]
  got = ask([
    ["RPUSH", "s", "1", "2"],
    ["RPUSH", "d", "x"],
    ["PEXPIRE", "s", "1000"],
    ["PEXPIRE", "d", "2000"],
    ["LMOVE", "s", "d", "LEFT", "RIGHT"],
    ["PTTL", "s"],
    ["PTTL", "d"],
    ["LMOVE", "s", "n", "LEFT", "LEFT"],
    ["EXISTS", "s"],
    ["PTTL", "n"],
    ["PTTL", "s"],
    ["RPUSH", "o", "x"],
    ["PEXPIRE", "o", "500"],
    ["LMOVE", "o", "o", "LEFT", "RIGHT"],
    ["PTTL", "o"],
  ])

  want = [":2\r\n", ":1\r\n", ":1\r\n", ":1\r\n", bulk("1"), ":1000\r\n", ":2000\r\n", bulk("2")]
  want = want.concat([":0\r\n", ":-1\r\n", ":-2\r\n", ":1\r\n", ":1\r\n", bulk("x"), ":500\r\n"])
  Test.eq(got, want.join(""))
end

# LMPOP pops from the first key that holds a list, up to COUNT elements, and
# answers the key with them; none is a null array. The numbers are read first
# (the same text for a word and a number below 1), then the word after the
# keys, then COUNT once; a key of another type that is met before a list
# answers WRONGTYPE.
def test_lmpop() -> Result[Void]
  got = ask([
    ["RPUSH", "a", "1", "2", "3", "4", "5"],
    ["RPUSH", "b", "x", "y"],
    ["SET", "s", "v"],
    ["LMPOP", "2", "none", "a", "LEFT"],
    ["LMPOP", "1", "a", "RIGHT", "COUNT", "2"],
    ["LMPOP", "2", "a", "b", "left", "count", "10"],
    ["EXISTS", "a"],
    ["LMPOP", "2", "a", "b", "RIGHT"],
    ["LMPOP", "1", "a", "LEFT"],
    ["LMPOP", "2", "s", "b", "LEFT"],
    ["LMPOP", "2", "b", "s", "LEFT"],
    ["EXISTS", "b"],
  ])

  want = [
    ":5\r\n",
    ":2\r\n",
    "+OK\r\n",
    popped("a", ["1"]),
    popped("a", ["5", "4"]),
    popped("a", ["2", "3"]),
    ":0\r\n",
    popped("b", ["y"]),
    "*-1\r\n",
    WRONGTYPE,
    popped("b", ["x"]),
    ":0\r\n",
  ]

  try Test.eq(got, want.join(""))
  errors = ask([
    ["LMPOP", "0", "a", "LEFT"],
    ["LMPOP", "x", "a", "LEFT"],
    ["LMPOP", "-1", "a", "LEFT"],
    ["LMPOP", "2", "a", "LEFT"],
    ["LMPOP", "9223372036854775807", "a", "LEFT"],
    ["LMPOP", "1", "a", "UP"],
    ["LMPOP", "1", "a", "LEFT", "COUNT", "0"],
    ["LMPOP", "1", "a", "LEFT", "COUNT", "x"],
    ["LMPOP", "1", "a", "LEFT", "COUNT", "1", "COUNT", "1"],
    ["LMPOP", "1", "a", "LEFT", "COUNT"],
    ["LMPOP", "1", "a", "LEFT", "FOO", "1"],
    ["LMPOP", "1", "a"],
  ])

  # Only numkeys keys are looked at: the word after them is not a key.
  try Test.eq(ask([["RPUSH", "LEFT", "x"], ["LMPOP", "1", "a", "LEFT"]]), ":1\r\n*-1\r\n")

  bad = [NUMKEYS, NUMKEYS, NUMKEYS, SYNTAX, SYNTAX, SYNTAX, COUNT, COUNT, SYNTAX, SYNTAX, SYNTAX]
  Test.eq(errors, bad.concat(["-ERR wrong number of arguments for 'lmpop' command\r\n"]).join(""))
end

# Two lists against a model of two Lists: pushes at both ends, LMOVE between
# any two ends of any two lists (also one list onto itself), LMPOP over both
# keys in either order, and LRANGE. 150 runs.
def test_moves_follow_a_model() -> Result[Void]
  table = Table.build()
  numbers = Prop.int(0, 99)
  ops = Prop.list(Prop.list(numbers, 5), 25)
  Prop.check(ops, Prop.Config(runs: 150)) do |list|
    padded = list.map do |op| op.concat([0, 0, 0, 0, 0]) end
    got = run_requests(table, fresh(), padded.map do |op| argv_of(op) end).reply
    Prop.eq(got.to_a, modeled(padded).bytes.to_a)
  end
end

def key_of(n: Int) -> String = ["a", "b"][n % 2]

def side_of(n: Int) -> String = ["LEFT", "RIGHT"][n % 2]

def argv_of(op: List[Int]) -> List[Bytes]
  value = "v#{op[1] % 5}".bytes
  keys = [key_of(op[3]), key_of(op[3] + 1)]
  return case op[0] % 5
    0 -> ["RPUSH".bytes, key_of(op[2]).bytes, value]
    1 -> ["LPUSH".bytes, key_of(op[2]).bytes, value]
    2 -> ["LMOVE".bytes, key_of(op[1]).bytes, key_of(op[2]).bytes, side_of(op[3]).bytes, side_of(op[4]).bytes]
    3 ->
      [
        "LMPOP".bytes,
        "2".bytes,
        keys[0].bytes,
        keys[1].bytes,
        side_of(op[1]).bytes,
        "COUNT".bytes,
        "#{op[2] % 4 + 1}".bytes,
      ]
    _ -> ["LRANGE".bytes, key_of(op[1]).bytes, "0".bytes, "-1".bytes]
  end
end

def modeled(ops: List[List[Int]]) -> String
  held: List[List[String]] = [[], []]
  out = ""
  for op in ops
    value = "v#{op[1] % 5}"
    case op[0] % 5
      0 ->
        held = replaced(held, op[2] % 2, held[op[2] % 2].push(value))
        out = "#{out}:#{held[op[2] % 2].size}\r\n"
      1 ->
        held = replaced(held, op[2] % 2, [value].concat(held[op[2] % 2]))
        out = "#{out}:#{held[op[2] % 2].size}\r\n"
      2 ->
        done = moved(held, op)
        held = done.held
        out = "#{out}#{done.reply}"
      3 ->
        done = popped_first(held, op)
        held = done.held
        out = "#{out}#{done.reply}"
      _ -> out = "#{out}#{strings(held[op[1] % 2])}"
    end
  end

  out
end

def replaced(held: List[List[String]], index: Int, items: List[String]) -> List[List[String]]
  return [items, held[1]] if index == 0

  [held[0], items]
end

def moved(held: List[List[String]], op: List[Int]) -> Step
  source = held[op[1] % 2]
  return Step(held: held, reply: "$-1\r\n") if source.empty?

  element = source[source.size - 1]
  rest = source.take(source.size - 1)
  if op[3] % 2 == 0
    element = source[0]
    rest = source.drop(1)
  end

  after = replaced(held, op[1] % 2, rest)
  target = after[op[2] % 2]
  grown = target.push(element)
  if op[4] % 2 == 0
    grown = [element].concat(target)
  end

  Step(held: replaced(after, op[2] % 2, grown), reply: bulk(element))
end

def popped_first(held: List[List[String]], op: List[Int]) -> Step
  count = op[2] % 4 + 1
  for pick in [op[3], op[3] + 1]
    items = held[pick % 2]
    if not items.empty?
      taken = items.take(count)
      rest = items.drop(count)
      shown = taken
      if op[1] % 2 == 1
        taken = items
        if count < items.size
          taken = items.drop(items.size - count)
        end

        rest = items.take(items.size - taken.size)
        shown = taken.reverse
      end

      return Step(held: replaced(held, pick % 2, rest), reply: popped(key_of(pick), shown))
    end
  end

  Step(held: held, reply: "*-1\r\n")
end
