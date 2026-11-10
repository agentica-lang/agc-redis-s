import {Databases, fresh, space_at} from "../../src/store/databases"
import Keyspace from "../../src/store/keyspace"
import {Value} from "../../src/store/value"
import {exchange, request, talk, to_bytes} from "../support"
import Prop from "pkg/prop/prop"

# The model of a keyspace: key number to the bytes it holds.
struct Model
  state: Map[Int, List[Int]]
  replies: List[Bytes]
end

def bulk(data: List[Int]) -> Bytes
  return Bytes.concat(["$#{data.size}\r\n".bytes, to_bytes(data), "\r\n".bytes])
end

def maybe(data: Optional[List[Int]]) -> Bytes
  case data
    none -> return "$-1\r\n".bytes
    some(xs) -> return bulk(xs)
  end
end

def whole(n: Int) -> Bytes
  return ":#{n}\r\n".bytes
end

def name(key: Int) -> Bytes
  return "k#{key}".bytes
end

# Part of GETRANGE that is not its code: the indexes as Redis defines them,
# written as a filter over positions.
def slice_of(data: List[Int], start: Int, stop: Int) -> List[Int]
  size = data.size
  if start < 0 and stop < 0 and start > stop
    return []
  end

  first = start
  last = stop
  if first < 0
    first = size + first
  end

  if last < 0
    last = size + last
  end

  lo = first
  if lo < 0
    lo = 0
  end

  hi = last
  if hi < 0
    hi = 0
  end

  return (0...size).to_a.select do |i| i >= lo and i <= hi end.map do |i| data[i] end
end

def written(old: List[Int], offset: Int, value: List[Int]) -> List[Int]
  padded = old
  if old.size < offset
    padded = old.concat((1..(offset - old.size)).to_a.map do |_| 0 end)
  end

  return padded.take(offset).concat(value).concat(padded.drop(offset + value.size))
end

# One operation as a list of numbers: kind, key, two small numbers, then the
# bytes of the value. The request it makes and the model's answer to it.
def request_of(kinds: List[Int], op: List[Int]) -> Bytes
  xs = op.concat([0, 0, 0, 0])
  key = name(xs[1] % 3)
  value = to_bytes(xs.drop(4))
  n = xs[2] % 10
  m = xs[3] % 10
  return case kinds[xs[0] % kinds.size]
    0 -> request(["SET".bytes, key, value])
    1 -> request(["GET".bytes, key])
    2 -> request(["APPEND".bytes, key, value])
    3 -> request(["GETDEL".bytes, key])
    4 -> request(["SETNX".bytes, key, value])
    5 -> request(["GETSET".bytes, key, value])
    6 -> request(["SETRANGE".bytes, key, "#{n}".bytes, value])
    7 -> request(["STRLEN".bytes, key])
    _ -> request(["GETRANGE".bytes, key, "#{n - 4}".bytes, "#{m - 4}".bytes])
  end
end

def model_step(kinds: List[Int], model: Model, op: List[Int]) -> Model
  xs = op.concat([0, 0, 0, 0])
  key = xs[1] % 3
  value = xs.drop(4)
  n = xs[2] % 10
  m = xs[3] % 10
  old = model.state.get(key)
  size = old.unwrap_or([]).size
  state = model.state
  answer = "+OK\r\n".bytes
  case kinds[xs[0] % kinds.size]
    0 -> state = state.put(key, value)
    1 -> answer = maybe(old)
    2 ->
      state = state.put(key, old.unwrap_or([]).concat(value))
      answer = whole(size + value.size)
    3 ->
      state = state.delete(key)
      answer = maybe(old)
    4 ->
      answer = whole(0)
      if old.none?
        state = state.put(key, value)
        answer = whole(1)
      end

    5 ->
      state = state.put(key, value)
      answer = maybe(old)
    6 ->
      answer = whole(size)
      if not value.empty?
        state = state.put(key, written(old.unwrap_or([]), n, value))
        answer = whole(state[key].size)
      end

    7 -> answer = whole(size)
    _ -> answer = bulk(slice_of(old.unwrap_or([]), n - 4, m - 4))
  end

  return Model(state: state, replies: model.replies.push(answer))
end

# Under a run of up to 14 operations from `kinds` the server answers as the
# model does, and holds what the model holds after it. Three keys, so the
# operations meet often.
def follows_the_model(kinds: List[Int]) -> Result[Void]
  numbers = Prop.int(0, 255)
  ops = Prop.list(Prop.list(numbers, 8), 14)
  return Prop.check(ops, Prop.Config(runs: 40)) do |list|
    requests = list.map do |op| request_of(kinds, op) end
    start = Model(state: {}, replies: [])
    model = list.reduce(start) do |acc, op| model_step(kinds, acc, op) end
    got = exchange(fresh(), Bytes.concat(requests))
    held = [0, 1, 2].map do |k| left_in(got.databases, k) end
    want = [0, 1, 2].map do |k| model.state.get(k) end
    try Prop.eq("#{got.reply}", "#{Bytes.concat(model.replies)}")
    Prop.eq("#{held}", "#{want}")
  end
end

# SET, GET, APPEND, GETDEL, SETNX, GETSET and STRLEN against a Map. 40 runs:
# the step limit is between 100 and 130, and a third of it is the rule.
def test_whole_value_commands_follow_a_map() -> Result[Void]
  return follows_the_model([0, 1, 2, 3, 4, 5, 7])
end

# SETRANGE and GETRANGE, with SET, GET and STRLEN around them, against a Map.
# 40 runs, for the same reason.
def test_range_commands_follow_a_map() -> Result[Void]
  return follows_the_model([0, 6, 8, 1, 7, 6, 8])
end

# What the server holds at key number `k`, as the model's list of numbers.
def left_in(databases: Databases, k: Int) -> Optional[List[Int]]
  case Keyspace.get(space_at(databases, 0), name(k), 0)
    none -> return none
    some(value) ->
      case value
        Value.Str(text) -> return some(text.to_a)
      end
  end
end

# What a model does not say: SET's options and their errors, GET as an option
# (the old value is the answer, also when NX or XX stops the write), the
# arity of MSET, MSETNX that sets nothing when one key exists, MGET with a
# missing key, GETRANGE with the negative pair that Redis answers with "".
def test_commands_and_their_texts() -> Result[Void]
  result = talk([
    ["SET", "a", "1", "NX"],
    ["SET", "a", "2", "nx"],
    ["SET", "a", "3", "XX", "GET"],
    ["SET", "b", "x", "XX"],
    ["SET", "b", "x", "NX", "XX"],
    ["SET", "b", "x", "EX", "10"],
    ["MSET", "k", "v", "z"],
    ["MSETNX", "a", "9", "c", "9"],
    ["MSETNX", "c", "8", "c", "9"],
    ["MGET", "a", "nope", "c"],
    ["GETRANGE", "a", "-1", "-2"],
    ["GETRANGE", "a", "0", "x"],
    ["SETRANGE", "a", "-1", "x"],
    ["SETRANGE", "a", "536870912", "x"],
    ["SETRANGE", "a", "y", "x"],
  ])

  expected = [
    "+OK\r\n$-1\r\n$1\r\n1\r\n$-1\r\n-ERR syntax error\r\n-ERR syntax error\r\n",
    "-ERR wrong number of arguments for 'mset' command\r\n",
    ":0\r\n:1\r\n*3\r\n$1\r\n3\r\n$-1\r\n$1\r\n9\r\n",
    "$0\r\n\r\n-ERR value is not an integer or out of range\r\n",
    "-ERR offset is out of range\r\n",
    "-ERR string exceeds maximum allowed size (proto-max-bulk-len)\r\n",
    "-ERR value is not an integer or out of range\r\n",
  ].join("")

  return Test.eq(result.reply, expected.bytes)
end
