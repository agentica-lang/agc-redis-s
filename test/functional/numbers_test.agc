import Table from "../../src/commands/table"
import {Databases, fresh, space_at} from "../../src/store/databases"
import Keyspace from "../../src/store/keyspace"
import {joined_text, pending?} from "../../src/store/value"
import {exchange, run_requests, talk, words} from "../support"
import Prop from "pkg/prop/prop"

STEP = 4_294_967_296
HIGH = 9_223_372_036_854_775_807
LOW = -9_223_372_036_854_775_807 - 1

# The values around the ends of Int64 and of its halves.
EDGES = [LOW, LOW + 1, -STEP, -2, -1, 0, 1, 2, STEP - 1, HIGH - 1, HIGH]

# The model of the keys: key number to the integer it holds.
struct Model
  state: Map[Int, Int]
  replies: List[Bytes]
end

def name(key: Int) -> Bytes
  return "k#{key}".bytes
end

# `a + b` if it fits in 64 bits, else none, found without a 64-bit sum: each
# number is a high part times 2^32 plus a low part below 2^32.
def sum(a: Int, b: Int) -> Optional[Int]
  a_low = (a % STEP + STEP) % STEP
  b_low = (b % STEP + STEP) % STEP
  carry = (a_low + b_low) / STEP
  high = (a - a_low) / STEP + (b - b_low) / STEP + carry
  if high < -2_147_483_648 or high > 2_147_483_647
    return none
  end

  return some(high * STEP + (a_low + b_low) % STEP)
end

def argv_of(op: List[Int]) -> List[Bytes]
  xs = op.concat([0, 0, 0, 0])
  key = name(xs[1] % 2)
  edge = "#{EDGES[xs[2] % EDGES.size]}".bytes
  return case xs[0] % 6
    0 -> ["SET".bytes, key, edge]
    1 -> ["INCRBY".bytes, key, edge]
    2 -> ["DECRBY".bytes, key, edge]
    3 -> ["INCR".bytes, key]
    4 -> ["DECR".bytes, key]
    _ -> ["GET".bytes, key]
  end
end

def model_step(model: Model, op: List[Int]) -> Model
  xs = op.concat([0, 0, 0, 0])
  key = xs[1] % 2
  edge = EDGES[xs[2] % EDGES.size]
  old = model.state.get(key)
  kind = xs[0] % 6
  if kind == 0
    return Model(state: model.state.put(key, edge), replies: model.replies.push("+OK\r\n".bytes))
  end

  if kind == 5
    got = "$-1\r\n".bytes
    if old.some?
      got = "$#{"#{old.unwrap!}".size}\r\n#{old.unwrap!}\r\n".bytes
    end

    return Model(state: model.state, replies: model.replies.push(got))
  end

  if kind == 2 and edge == LOW
    return Model(state: model.state, replies: model.replies.push("-ERR decrement would overflow\r\n".bytes))
  end

  delta = case kind
    1 -> edge
    2 -> 0 - edge
    4 -> -1
    _ -> 1
  end

  case sum(old.unwrap_or(0), delta)
    none ->
      return Model(
        state: model.state,
        replies: model.replies.push("-ERR increment or decrement would overflow\r\n".bytes),
      )
    some(total) -> return Model(state: model.state.put(key, total), replies: model.replies.push(":#{total}\r\n".bytes))
  end
end

def held(databases: Databases, key: Int) -> Optional[List[Int]]
  case Keyspace.get(space_at(databases, 0), name(key), 0)
    none -> return none
    some(value) -> return some(joined_text(value).to_a)
  end
end

# INCR, DECR, INCRBY and DECRBY (and SET and GET around them) against a Map of
# integers, with values at the ends of Int64: the replies, the overflow errors
# at both ends and what is stored. 100 runs: the step limit is between 350 and
# 600 runs, about a third of the lower.
def test_increments_follow_a_map() -> Result[Void]
  table = Table.build()
  numbers = Prop.int(0, 255)
  ops = Prop.list(Prop.list(numbers, 4), 12)
  return Prop.check(ops, Prop.Config(runs: 100)) do |list|
    argvs = list.map do |op| argv_of(op) end
    model = list.reduce(Model(state: {}, replies: [])) do |acc, op| model_step(acc, op) end
    got = run_requests(table, fresh(), argvs)
    try Prop.eq(got.reply.to_a, Bytes.concat(model.replies).to_a)
    stored = [0, 1].map do |k| held(got.databases, k) end
    want = [0, 1].map do |k| model.state.get(k).map do |n| "#{n}".bytes.to_a end end
    Prop.eq(stored, want)
  end
end

# What a model does not say: the texts that are not integers (a space, a zero
# first, a decimal point, a plus), a bad increment before a bad value, the
# least Int with DECRBY, the last value before each end, and a value built by APPEND (joined, then stored as the
# number).
def test_texts_of_the_number_commands() -> Result[Void]
  result = talk([
    ["INCR", "a"],
    ["SET", "s", " 1"],
    ["INCR", "s"],
    ["SET", "s", "01"],
    ["DECR", "s"],
    ["SET", "s", "1.5"],
    ["INCRBY", "s", "1"],
    ["SET", "s", "+1"],
    ["INCR", "s"],
    ["INCRBY", "s", "x"],
    ["INCRBY", "a", "1.5"],
    ["DECRBY", "a", "-9223372036854775808"],
    ["SET", "m", "9223372036854775806"],
    ["INCR", "m"],
    ["INCR", "m"],
    ["SET", "n", "-9223372036854775807"],
    ["DECR", "n"],
    ["DECR", "n"],
    ["APPEND", "p", "1"],
    ["APPEND", "p", "2"],
    ["INCR", "p"],
    ["GET", "p"],
  ])

  expected = [
    ":1\r\n",
    "+OK\r\n-ERR value is not an integer or out of range\r\n",
    "+OK\r\n-ERR value is not an integer or out of range\r\n",
    "+OK\r\n-ERR value is not an integer or out of range\r\n",
    "+OK\r\n-ERR value is not an integer or out of range\r\n",
    "-ERR value is not an integer or out of range\r\n",
    "-ERR value is not an integer or out of range\r\n",
    "-ERR decrement would overflow\r\n",
    "+OK\r\n:9223372036854775807\r\n-ERR increment or decrement would overflow\r\n",
    "+OK\r\n:-9223372036854775808\r\n-ERR increment or decrement would overflow\r\n",
    ":1\r\n:2\r\n:13\r\n$2\r\n13\r\n",
  ].join("")

  return Test.eq(result.reply, expected.bytes)
end
