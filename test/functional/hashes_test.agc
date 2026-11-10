## The hash commands and the type checks between hashes and strings.

import Scan from "../../src/store/scan"
import Table from "../../src/commands/table"
import {exchange, run_requests, talk, to_bytes, words} from "../support"
import {fresh} from "../../src/store/databases"
import Prop from "pkg/prop/prop"

WRONGTYPE = "-WRONGTYPE Operation against a key holding the wrong kind of value\r\n"

# The model of one hash: the fields in the order they were first set, and the
# values.
struct Model
  order: List[Int]
  values: Map[Int, List[Int]]
  replies: List[Bytes]
end

def ask(requests: List[List[String]]) -> String
  return talk(requests).reply.decode("latin-1").unwrap!
end

# Fields set and replaced (HSET counts only the new ones), read one by one,
# deleted (a field named twice counts once), and the key goes with its last
# field. A lone field is an arity error, with the text of Redis.
def test_set_get_and_delete() -> Result[Void]
  got = ask([
    ["HSET", "h", "a", "1", "b", "2"],
    ["HSET", "h", "a", "9", "c", "3"],
    ["HGET", "h", "a"],
    ["HGET", "h", "zz"],
    ["HGET", "none", "a"],
    ["HMGET", "h", "a", "zz", "c"],
    ["HMGET", "none", "x", "y"],
    ["HLEN", "h"],
    ["HLEN", "none"],
    ["HEXISTS", "h", "b"],
    ["HEXISTS", "h", "zz"],
    ["HSTRLEN", "h", "a"],
    ["HSTRLEN", "h", "zz"],
    ["HSETNX", "h", "a", "x"],
    ["HSETNX", "h", "d", "4"],
    ["HSETNX", "new", "f", "v"],
    ["HMSET", "m", "x", "1", "y", "2"],
    ["HDEL", "h", "a", "a", "zz"],
    ["HDEL", "h", "b", "c", "d"],
    ["HLEN", "h"],
    ["EXISTS", "h"],
    ["HDEL", "h", "a"],
    ["HSET", "h", "a", "1", "b"],
    ["HSET", "h", "a"],
  ])

  want = [
    ":2", ":1", "$1\r\n9", "$-1", "$-1", "*3\r\n$1\r\n9\r\n$-1\r\n$1\r\n3", "*2\r\n$-1\r\n$-1", ":3", ":0", ":1", ":0",
    ":1", ":0", ":0", ":1", ":1", "+OK", ":1", ":3", ":0", ":0", ":0",
    "-ERR wrong number of arguments for 'hset' command", "-ERR wrong number of arguments for 'hset' command",
  ]

  return Test.eq(got, "#{want.join("\r\n")}\r\n")
end

# A write keeps the deadline of a live hash, and a hash that expired is a new
# one: the old fields are gone.
def test_hash_deadline() -> Result[Void]
  first = talk([["HSET", "h", "a", "1"], ["PEXPIRE", "h", "100"]])
  later = exchange(first.databases, words(["HSET", "h", "b", "2"]), 50)
  try Test.eq(
    exchange(later.databases, Bytes.concat([words(["PTTL", "h"]), words(["HLEN", "h"])]), 60).reply.to_a,
    ":40\r\n:2\r\n".bytes.to_a,
  )

  fresh_hash = exchange(
    later.databases,
    Bytes.concat([words(["HSET", "h", "c", "3"]), words(["HLEN", "h"]), words(["TTL", "h"])]),
    500,
  )

  return Test.eq(fresh_hash.reply.to_a, ":1\r\n:1\r\n:-1\r\n".bytes.to_a)
end

# A string command on a hash key and a hash command on a string key answer
# WRONGTYPE, except the ones that replace the value (SET) or only look whether
# the key exists (SETNX), and MGET, which answers nil. A bad number wins over
# the type for INCRBY and SETRANGE.
def test_wrong_type_both_ways() -> Result[Void]
  on_hash = [
    ["GET", "h"],
    ["GETDEL", "h"],
    ["GETSET", "h", "v"],
    ["GETEX", "h"],
    ["APPEND", "h", "x"],
    ["STRLEN", "h"],
    ["GETRANGE", "h", "0", "1"],
    ["SETRANGE", "h", "0", "x"],
    ["SETRANGE", "h", "0", ""],
    ["INCR", "h"],
    ["DECR", "h"],
    ["INCRBY", "h", "1"],
    ["INCRBYFLOAT", "h", "1"],
    ["SET", "h", "v", "GET"],
  ]

  setup = [["HSET", "h", "f", "1"], ["SET", "s", "1"]]
  got = ask(setup.concat(on_hash))
  try Test.eq(got, ":1\r\n+OK\r\n#{on_hash.map do |_| WRONGTYPE end.join("")}")
  odd = ask(
    setup.concat([["INCRBY", "h", "x"], ["MGET", "h", "s"], ["SETNX", "h", "x"], ["TYPE", "h"], ["TYPE", "s"]]),
  )

  try Test.eq(
    odd,
    ":1\r\n+OK\r\n-ERR value is not an integer or out of range\r\n*2\r\n$-1\r\n$1\r\n1\r\n:0\r\n+hash\r\n+string\r\n",
  )

  on_string = [
    ["HSET", "s", "a", "1"],
    ["HMSET", "s", "a", "1"],
    ["HSETNX", "s", "a", "1"],
    ["HGET", "s", "a"],
    ["HMGET", "s", "a"],
    ["HDEL", "s", "a"],
    ["HLEN", "s"],
    ["HEXISTS", "s", "a"],
    ["HSTRLEN", "s", "a"],
  ]

  try Test.eq(ask(setup.concat(on_string)), ":1\r\n+OK\r\n#{on_string.map do |_| WRONGTYPE end.join("")}")
  replaced = ask(setup.concat([["SET", "h", "v"], ["TYPE", "h"], ["HSET", "h", "a", "1"]]))
  return Test.eq(replaced, ":1\r\n+OK\r\n+OK\r\n+string\r\n#{WRONGTYPE}")
end

# SCAN TYPE lists the keys of that type only, case aside.
def test_scan_type_hash() -> Result[Void]
  first = talk([["HSET", "h", "a", "1"], ["SET", "s", "1"]])
  asked = exchange(
    first.databases,
    Bytes.concat([words(["SCAN", "0", "TYPE", "Hash"]), words(["SCAN", "0", "TYPE", "string"])]),
    0,
  )

  return Test.eq(
    asked.reply.decode("latin-1").unwrap!,
    "*2\r\n$1\r\n0\r\n*1\r\n$1\r\nh\r\n*2\r\n$1\r\n0\r\n*1\r\n$1\r\ns\r\n",
  )
end

# The listings come in the order the fields were first set; a missing key is an
# empty array.
def test_listings() -> Result[Void]
  got = ask([
    ["HSET", "h", "b", "1", "a", "2", "c", "3"],
    ["HSET", "h", "b", "9"],
    ["HDEL", "h", "a"],
    ["HSET", "h", "a", "7"],
    ["HGETALL", "h"],
    ["HKEYS", "h"],
    ["HVALS", "h"],
    ["HGETALL", "none"],
    ["HKEYS", "none"],
    ["HVALS", "none"],
  ])

  want = [
    ":3", ":0", ":1", ":1", "*6\r\n$1\r\nb\r\n$1\r\n9\r\n$1\r\nc\r\n$1\r\n3\r\n$1\r\na\r\n$1\r\n7",
    "*3\r\n$1\r\nb\r\n$1\r\nc\r\n$1\r\na", "*3\r\n$1\r\n9\r\n$1\r\n3\r\n$1\r\n7", "*0", "*0", "*0",
  ]

  return Test.eq(got, "#{want.join("\r\n")}\r\n")
end

# HINCRBY: a missing key or field starts at 0; the increment is read first; a
# field that is no integer and an overflow are refused with Redis's texts.
def test_hincrby() -> Result[Void]
  got = ask([
    ["HINCRBY", "h", "a", "5"],
    ["HINCRBY", "h", "a", "-7"],
    ["HSET", "h", "t", "x", "m", "9223372036854775807", "n", "-9223372036854775808"],
    ["HINCRBY", "h", "t", "1"],
    ["HINCRBY", "h", "m", "1"],
    ["HINCRBY", "h", "n", "-1"],
    ["HINCRBY", "h", "m", "-1"],
    ["HINCRBY", "h", "a", "x"],
    ["HINCRBY", "h", "a", "1.5"],
    ["HGET", "h", "a"],
    ["SET", "s", "1"],
    ["HINCRBY", "s", "a", "1"],
    ["HINCRBY", "s", "a", "x"],
  ])

  want = [
    ":5",
    ":-2",
    ":3",
    "-ERR hash value is not an integer",
    "-ERR increment or decrement would overflow",
    "-ERR increment or decrement would overflow",
    ":9223372036854775806",
    "-ERR value is not an integer or out of range",
    "-ERR value is not an integer or out of range",
    "$2\r\n-2",
    "+OK",
    WRONGTYPE.trim,
    "-ERR value is not an integer or out of range",
  ]

  return Test.eq(got, "#{want.join("\r\n")}\r\n")
end

# HINCRBYFLOAT sums as INCRBYFLOAT does and stores the text it answers; an
# infinite increment, a field that is no float and a bad increment are refused.
def test_hincrbyfloat() -> Result[Void]
  got = ask([
    ["HINCRBYFLOAT", "h", "a", "10.5"],
    ["HINCRBYFLOAT", "h", "a", "-0.25"],
    ["HINCRBYFLOAT", "h", "a", "5.0e3"],
    ["HSET", "h", "t", "x", "i", "inf", "n", "7"],
    ["HINCRBYFLOAT", "h", "n", "0.5"],
    ["HINCRBYFLOAT", "h", "t", "1"],
    ["HINCRBYFLOAT", "h", "i", "1"],
    ["HINCRBYFLOAT", "h", "a", "inf"],
    ["HINCRBYFLOAT", "h", "a", "x"],
    ["HGET", "h", "a"],
    ["SET", "s", "1"],
    ["HINCRBYFLOAT", "s", "a", "1"],
  ])

  want = [
    "$4\r\n10.5",
    "$5\r\n10.25",
    "$7\r\n5010.25",
    ":3",
    "$3\r\n7.5",
    "-ERR hash value is not a float",
    "-ERR increment would produce NaN or Infinity",
    "-ERR value is NaN or Infinity",
    "-ERR value is not a valid float",
    "$7\r\n5010.25",
    "+OK",
    WRONGTYPE.trim,
  ]

  return Test.eq(got, "#{want.join("\r\n")}\r\n")
end

# What a client sees first on a hash key: the number or the option is checked
# before the type, except for GETEX, which checks the type before the time.
def test_error_order_on_a_hash_key() -> Result[Void]
  got = ask([
    ["HSET", "h", "f", "1"],
    ["SETRANGE", "h", "x", "v"],
    ["SETRANGE", "h", "-1", "v"],
    ["GETRANGE", "h", "a", "b"],
    ["SET", "h", "v", "EX", "0", "GET"],
    ["GETEX", "h", "EX", "0"],
    ["GETEX", "h", "BAD"],
  ])

  want = [
    ":1",
    "-ERR value is not an integer or out of range",
    "-ERR offset is out of range",
    "-ERR value is not an integer or out of range",
    "-ERR invalid expire time in 'set' command",
    WRONGTYPE.trim,
    "-ERR syntax error",
  ]

  return Test.eq(got, "#{want.join("\r\n")}\r\n")
end

# Deleting the last field deletes the key, so a hash made later has no
# deadline.
def test_last_field_drops_the_deadline() -> Result[Void]
  got = ask([
    ["HSET", "h", "a", "1"],
    ["PEXPIRE", "h", "100000"],
    ["HDEL", "h", "a"],
    ["HSET", "h", "a", "1"],
    ["TTL", "h"],
  ])

  return Test.eq(got, ":1\r\n:1\r\n:1\r\n:1\r\n:-1\r\n")
end

# The fields of a reply that lists them: the lines that are no length marker.
def names_in(reply: String) -> List[String]
  return reply.split("\r\n").select do |line| line != "" and not ["$", "*", ":"].include?(line.slice(0, 1).to_s) end
end

def count_in(requests: List[List[String]]) -> String
  return ask([["HSET", "h", "f0", "v0", "f1", "v1", "f2", "v2", "f3", "v3", "f4", "v4"]].concat(requests))
end

# HRANDFIELD: one field; a count that covers the hash gives all of it in order;
# a smaller one gives that many different fields in order; a negative one gives
# that many, repeats allowed; WITHVALUES pairs each with its value.
def test_hrandfield() -> Result[Void]
  single = ask([
    ["HSET", "h", "a", "1"],
    ["HRANDFIELD", "h"],
    ["HRANDFIELD", "h", "-3"],
    ["HRANDFIELD", "h", "-2", "withvalues"],
  ])

  try Test.eq(
    single,
    ":1\r\n$1\r\na\r\n*3\r\n$1\r\na\r\n$1\r\na\r\n$1\r\na\r\n*4\r\n$1\r\na\r\n$1\r\n1\r\n$1\r\na\r\n$1\r\n1\r\n",
  )

  all = count_in([
    ["HRANDFIELD", "h", "9"],
    ["HRANDFIELD", "h", "5"],
    ["HRANDFIELD", "h", "0"],
    ["HRANDFIELD", "h", "7", "WITHVALUES"],
  ])

  try Test.assert(
    all.include?("*5\r\n$2\r\nf0\r\n$2\r\nf1\r\n$2\r\nf2\r\n$2\r\nf3\r\n$2\r\nf4\r\n*5\r\n$2\r\nf0"),
    "the whole hash, in order",
  )

  try Test.assert(all.include?("*0\r\n*10\r\n$2\r\nf0\r\n$2\r\nv0"), "zero is empty; WITHVALUES doubles the length")
  # Ten draws of 3 different fields: ascending and distinct every time.
  draws = count_in((1..10).to_a.map do |_| ["HRANDFIELD", "h", "3"] end)
  found = names_in(draws)
  try Test.eq(found.size, 30)
  for i in 0...10
    picked = found.drop(i * 3).take(3)
    try Test.assert(
      picked.sort == picked and picked[0] != picked[1] and picked[1] != picked[2],
      "three different fields in order: #{picked}",
    )
  end

  noise = count_in([["HRANDFIELD", "h", "-40"]])
  try Test.assert(names_in(noise).size == 40, "forty fields from the hash")
  return Test.eq(
    ask([["HRANDFIELD", "none"], ["HRANDFIELD", "none", "3"], ["HRANDFIELD", "none", "-3", "WITHVALUES"]]),
    "$-1\r\n*0\r\n*0\r\n",
  )
end

# The count is read before the options and the key; the limits are Redis's.
def test_hrandfield_errors() -> Result[Void]
  got = ask([
    ["SET", "s", "1"],
    ["HRANDFIELD", "s"],
    ["HRANDFIELD", "s", "2"],
    ["HRANDFIELD", "s", "x", "BAD"],
    ["HRANDFIELD", "s", "1", "BAD"],
    ["HRANDFIELD", "s", "1", "WITHVALUES", "x"],
    ["HRANDFIELD", "none", "-9223372036854775808"],
    ["HRANDFIELD", "none", "4611686018427387904", "WITHVALUES"],
    ["HRANDFIELD", "none", "-4611686018427387904", "WITHVALUES"],
    ["HRANDFIELD", "none", "4611686018427387904"],
    ["HRANDFIELD", "none", "4611686018427387903", "WITHVALUES"],
    ["HRANDFIELD", "none", "-4611686018427387903", "WITHVALUES"],
    ["HSET", "h", "a", "1"],
    ["HRANDFIELD", "h", "-1000000000"],
    ["HRANDFIELD", "h", "-650001", "WITHVALUES"],
  ])

  want = [
    "+OK",
    WRONGTYPE.trim,
    WRONGTYPE.trim,
    "-ERR value is not an integer or out of range",
    "-ERR syntax error",
    "-ERR syntax error",
    "-ERR value is out of range, value must between -9223372036854775807 and 9223372036854775807",
    "-ERR value is out of range",
    "-ERR value is out of range",
    "*0",
    "*0",
    "*0",
    ":1",
    "-ERR count is too large for the output limit",
    "-ERR count is too large for the output limit",
  ]

  return Test.eq(got, "#{want.join("\r\n")}\r\n")
end

def pair(name: String, value: String) -> String
  return "$#{name.size}\r\n#{name}\r\n$#{value.size}\r\n#{value}\r\n"
end

# HSCAN pages by the hash of the field name, as SCAN does: COUNT 1 gives one
# field and the hash of the next as the cursor; MATCH filters the names; TYPE is
# a syntax error; a missing key is an empty scan.
def test_hscan() -> Result[Void]
  setup = [["HSET", "h", "a", "1", "b", "2", "c", "3"], ["SET", "s", "1"]]
  names = ["a", "b", "c"].sort_by do |name| Scan.hash(name.bytes) end
  values = {"a": "1", "b": "2", "c": "3"}
  next = "#{Scan.hash(names[1].bytes)}"
  first = "*2\r\n$#{next.size}\r\n#{next}\r\n*2\r\n#{pair(names[0], values[names[0]])}"
  rest = "*2\r\n$1\r\n0\r\n*4\r\n#{pair(names[1], values[names[1]])}#{pair(names[2], values[names[2]])}"

  got = ask(setup.concat([["HSCAN", "h", "0", "COUNT", "1"], ["HSCAN", "h", next, "COUNT", "5"]]))
  try Test.eq(got, ":3\r\n+OK\r\n#{first}#{rest}")
  more = ask(
    setup.concat([
      ["HSCAN", "h", "0", "MATCH", "b"],
      ["HSCAN", "h", "0", "TYPE", "hash"],
      ["HSCAN", "none", "0"],
      ["HSCAN", "s", "0"],
      ["HSCAN", "h", "x"],
      ["HSCAN", "s", "x"],
      ["HSCAN", "h", "0", "COUNT", "0"],
    ]),
  )

  want = [
    ":3",
    "+OK",
    "*2\r\n$1\r\n0\r\n*2\r\n#{pair("b", "2").trim}",
    "-ERR syntax error",
    "*2\r\n$1\r\n0\r\n*0",
    WRONGTYPE.trim,
    "-ERR invalid cursor",
    "-ERR invalid cursor",
    "-ERR syntax error",
  ]

  return Test.eq(more, "#{want.join("\r\n")}\r\n")
end

def bulk(data: List[Int]) -> Bytes
  return Bytes.concat(["$#{data.size}\r\n".bytes, to_bytes(data), "\r\n".bytes])
end

def argv_for(op: List[Int]) -> List[Bytes]
  xs = op.concat([0, 0, 0])
  field = "f#{xs[1] % 4}".bytes
  return case xs[0] % 5
    0 -> ["HSET".bytes, "h".bytes, field, to_bytes(op.drop(2))]
    1 -> ["HDEL".bytes, "h".bytes, field]
    2 -> ["HLEN".bytes, "h".bytes]
    3 -> ["HGET".bytes, "h".bytes, field]
    _ -> ["HGETALL".bytes, "h".bytes]
  end
end

def model_step(model: Model, op: List[Int]) -> Model
  xs = op.concat([0, 0, 0])
  field = xs[1] % 4
  data = op.drop(2)
  order = model.order
  values = model.values
  answer = bulk([])
  case xs[0] % 5
    0 ->
      answer = ":#{1 - count_of(values, field)}\r\n".bytes
      if not values.has_key?(field)
        order = order.push(field)
      end

      values = values.put(field, data)
    1 ->
      answer = ":#{count_of(values, field)}\r\n".bytes
      order = order.select do |name| name != field end
      values = values.delete(field)
    2 -> answer = ":#{order.size}\r\n".bytes
    3 ->
      answer = "$-1\r\n".bytes
      if values.has_key?(field)
        answer = bulk(values.get(field, []))
      end

    _ ->
      parts = order.map do |name| Bytes.concat([bulk("f#{name}".bytes.to_a), bulk(values.get(name, []))]) end
      answer = Bytes.concat(["*#{order.size * 2}\r\n".bytes].concat(parts))
  end

  return Model(order: order, values: values, replies: model.replies.push(answer))
end

def count_of(values: Map[Int, List[Int]], field: Int) -> Int
  if values.has_key?(field)
    return 1
  end

  return 0
end

# HSET, HDEL, HLEN, HGET and HGETALL on one hash against the model, 300 runs.
def test_a_hash_follows_a_model() -> Result[Void]
  table = Table.build()
  numbers = Prop.int(0, 255)
  ops = Prop.list(Prop.list(numbers, 6), 24)
  return Prop.check(ops, Prop.Config(runs: 300)) do |list|
    start = Model(order: [], values: {}, replies: [])
    model = list.reduce(start) do |acc, op| model_step(acc, op) end
    argvs = list.map do |op| argv_for(op) end
    got = run_requests(table, fresh(), argvs)
    Prop.eq(got.reply.to_a, Bytes.concat(model.replies).to_a)
  end
end
