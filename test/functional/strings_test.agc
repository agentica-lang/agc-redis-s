import Table from "../../src/commands/table"
import {Exchange, exchange, run_requests, talk, to_bytes, words} from "../support"
import {Databases, fresh, space_at} from "../../src/store/databases"
import Keyspace from "../../src/store/keyspace"
import {joined_text, pending?} from "../../src/store/value"
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
# The options of SET for the six flavors: none, NX, XX, GET, NX GET, XX GET.
def set_options(n: Int) -> List[Bytes]
  flavors: List[List[String]] = [[], ["NX"], ["XX"], ["GET"], ["nx", "get"], ["XX", "GET"]]
  return flavors[n % 6].map do |w| w.bytes end
end

def argv_of(kinds: List[Int], op: List[Int]) -> List[Bytes]
  xs = op.concat([0, 0, 0, 0])
  key = name(xs[1] % 3)
  value = to_bytes(op.drop(4))
  n = xs[2] % 10
  m = xs[3] % 10
  return case kinds[xs[0] % kinds.size]
    0 -> ["SET".bytes, key, value].concat(set_options(n))
    1 -> ["GET".bytes, key]
    2 -> ["APPEND".bytes, key, value]
    3 -> ["GETDEL".bytes, key]
    4 -> ["SETNX".bytes, key, value]
    5 -> ["GETSET".bytes, key, value]
    6 -> ["SETRANGE".bytes, key, "#{n}".bytes, value]
    7 -> ["STRLEN".bytes, key]
    _ -> ["GETRANGE".bytes, key, "#{n - 4}".bytes, "#{m - 4}".bytes]
  end
end

def model_step(kinds: List[Int], model: Model, op: List[Int]) -> Model
  xs = op.concat([0, 0, 0, 0])
  key = xs[1] % 3
  value = op.drop(4)
  n = xs[2] % 10
  m = xs[3] % 10
  old = model.state.get(key)
  size = old.unwrap_or([]).size
  state = model.state
  answer = "+OK\r\n".bytes
  case kinds[xs[0] % kinds.size]
    0 ->
      flavor = n % 6
      nx = flavor == 1 or flavor == 4
      xx = flavor == 2 or flavor == 5
      wrote = (not nx or old.none?) and (not xx or old.some?)
      if wrote
        state = state.put(key, value)
      end

      if flavor >= 3
        answer = maybe(old)
      elsif not wrote
        answer = "$-1\r\n".bytes
      end

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
def follows_the_model(kinds: List[Int], runs: Int) -> Result[Void]
  table = Table.build()
  numbers = Prop.int(0, 255)
  ops = Prop.list(Prop.list(numbers, 8), 14)
  return Prop.check(ops, Prop.Config(runs: runs)) do |list|
    argvs = list.map do |op| argv_of(kinds, op) end
    start = Model(state: {}, replies: [])
    model = list.reduce(start) do |acc, op| model_step(kinds, acc, op) end
    got = run_requests(table, fresh(), argvs)
    held = [0, 1, 2].map do |k| left_in(got.databases, k) end
    want = [0, 1, 2].map do |k| model.state.get(k) end
    try Prop.eq(got.reply.to_a, Bytes.concat(model.replies).to_a)
    Prop.eq(held, want)
  end
end

# SET (with its six flavors of NX, XX and GET), GET, APPEND, GETDEL, SETNX,
# GETSET and STRLEN against a Map. 100 runs: the step limit is between 400 and
# 800 runs for this law, so a third of the lower.
def test_whole_value_commands_follow_a_map() -> Result[Void]
  return follows_the_model([0, 1, 2, 3, 4, 5, 7], 100)
end

# SETRANGE and GETRANGE, with SET, GET, STRLEN and APPEND (which leaves pieces
# for them to join) around them, against a Map. 65 runs: the limit is between 200 and 300.
def test_range_commands_follow_a_map() -> Result[Void]
  return follows_the_model([0, 6, 8, 1, 7, 6, 8, 2], 65)
end

# What the server holds at key number `k`, as the model's list of numbers.
def left_in(databases: Databases, k: Int) -> Optional[List[Int]]
  case Keyspace.get(space_at(databases, 0), name(k), 0)
    none -> return none
    some(value) -> return some(joined_text(value).to_a)
  end
end

# True when key `k` of the first database holds pieces not yet joined.
def pending_at(databases: Databases, k: Int) -> Bool
  case Keyspace.get(space_at(databases, 0), name(k), 0)
    none -> return false
    some(value) -> return pending?(value)
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
    "+OK\r\n$-1\r\n$1\r\n1\r\n$-1\r\n-ERR syntax error\r\n+OK\r\n",
    "-ERR wrong number of arguments for 'mset' command\r\n",
    ":0\r\n:1\r\n*3\r\n$1\r\n3\r\n$-1\r\n$1\r\n9\r\n",
    "$0\r\n\r\n-ERR value is not an integer or out of range\r\n",
    "-ERR offset is out of range\r\n",
    "-ERR string exceeds maximum allowed size (proto-max-bulk-len)\r\n",
    "-ERR value is not an integer or out of range\r\n",
  ].join("")

  return Test.eq(result.reply, expected.bytes)
end

# The databases after one request that reads key `k0`, which holds the pieces
# "ab", "cd" and "ef", and the reply.
def read_pieces(request: List[String]) -> Exchange
  start = talk([["APPEND", "k0", "ab"], ["APPEND", "k0", "cd"], ["APPEND", "k0", "ef"], ["APPEND", "k0", ""]])
  return exchange(start.databases, words(request))
end

# APPEND keeps the pieces and the size (STRLEN is right at once, an empty
# APPEND adds no piece); GET, MGET and GETRANGE each join them and write the
# joined form back, so the next read finds one piece.
def test_append_keeps_pieces_and_a_read_joins_them_once() -> Result[Void]
  start = talk([
    ["APPEND", "k0", "ab"],
    ["APPEND", "k0", "cd"],
    ["APPEND", "k0", "ef"],
    ["APPEND", "k0", ""],
    ["STRLEN", "k0"],
  ])

  try Test.eq(start.reply, ":2\r\n:4\r\n:6\r\n:6\r\n:6\r\n".bytes)
  try Test.eq(pending_at(start.databases, 0), true)
  try Test.eq(left_in(start.databases, 0).unwrap_or([]), "abcdef".bytes.to_a)

  length = read_pieces(["STRLEN", "k0"])
  try Test.eq(length.reply, ":6\r\n".bytes)
  try Test.eq(pending_at(length.databases, 0), true)

  nx = read_pieces(["SETNX", "k0", "z"])
  try Test.eq(nx.reply, ":0\r\n".bytes)
  try Test.eq(pending_at(nx.databases, 0), true)

  got = read_pieces(["GET", "k0"])
  try Test.eq(got.reply, "$6\r\nabcdef\r\n".bytes)
  try Test.eq(pending_at(got.databases, 0), false)
  try Test.eq(left_in(got.databases, 0).unwrap_or([]), "abcdef".bytes.to_a)

  many = read_pieces(["MGET", "k0", "k1"])
  try Test.eq(many.reply, "*2\r\n$6\r\nabcdef\r\n$-1\r\n".bytes)
  try Test.eq(pending_at(many.databases, 0), false)

  ranged = read_pieces(["GETRANGE", "k0", "1", "4"])
  try Test.eq(ranged.reply, "$4\r\nbcde\r\n".bytes)
  return Test.eq(pending_at(ranged.databases, 0), false)
end
