## The list commands: push, length, index and range, and the type checks
## between lists and the other types.

import Table from "../../src/commands/table"
import {exchange, run_requests, talk, words} from "../support"
import {fresh} from "../../src/store/databases"
import Prop from "pkg/prop/prop"

WRONGTYPE = "-WRONGTYPE Operation against a key holding the wrong kind of value\r\n"
NOT_INT = "-ERR value is not an integer or out of range\r\n"

def ask(requests: List[List[String]]) -> String = talk(requests).reply.decode("latin-1").unwrap!

def bulk(text: String) -> String = "$#{text.size}\r\n#{text}\r\n"

def strings(items: List[String]) -> String = "*#{items.size}\r\n#{items.map { |item| bulk(item) }.join("")}"

# LPUSH puts its elements at the head one by one (so the last one is first),
# RPUSH at the tail; the X forms need a live list. LINDEX counts from the tail
# with a negative index; LRANGE clamps its range and answers an empty array for
# an empty one; a missing key reads as an empty list.
def test_push_and_read() -> Result[Void]
  got = ask([
    ["LPUSH", "l", "a", "b", "c"],
    ["RPUSH", "l", "x", "y"],
    ["LPUSHX", "l", "z"],
    ["RPUSHX", "l", "w"],
    ["LPUSHX", "none", "a"],
    ["RPUSHX", "none", "a"],
    ["EXISTS", "none"],
    ["LLEN", "l"],
    ["LLEN", "none"],
    ["LRANGE", "l", "0", "-1"],
    ["LRANGE", "l", "-3", "-2"],
    ["LRANGE", "l", "-100", "1"],
    ["LRANGE", "l", "6", "100"],
    ["LRANGE", "l", "7", "100"],
    ["LRANGE", "l", "3", "2"],
    ["LRANGE", "l", "0", "-100"],
    ["LRANGE", "none", "0", "-1"],
    ["LINDEX", "l", "0"],
    ["LINDEX", "l", "-1"],
    ["LINDEX", "l", "7"],
    ["LINDEX", "l", "-8"],
    ["LINDEX", "none", "0"],
    ["LPUSH", "l"],
  ])

  want = [
    ":3\r\n",
    ":5\r\n",
    ":6\r\n",
    ":7\r\n",
    ":0\r\n",
    ":0\r\n",
    ":0\r\n",
    ":7\r\n",
    ":0\r\n",
    strings(["z", "c", "b", "a", "x", "y", "w"]),
    strings(["x", "y"]),
    strings(["z", "c"]),
    strings(["w"]),
    "*0\r\n",
    "*0\r\n",
    "*0\r\n",
    "*0\r\n",
    bulk("z"),
    bulk("w"),
    "$-1\r\n",
    "$-1\r\n",
    "$-1\r\n",
    "-ERR wrong number of arguments for 'lpush' command\r\n",
  ]

  Test.eq(got, want.join(""))
end

# The numbers are read before the key for LRANGE, after the type check for
# LINDEX, and a missing key answers before a bad number for LINDEX.
def test_index_errors() -> Result[Void]
  got = ask([
    ["RPUSH", "l", "a"],
    ["HSET", "h", "f", "1"],
    ["LRANGE", "l", "x", "1"],
    ["LRANGE", "none", "0", "y"],
    ["LRANGE", "h", "0", "y"],
    ["LINDEX", "l", "x"],
    ["LINDEX", "none", "x"],
    ["LINDEX", "h", "x"],
    ["LRANGE", "l", "0", "9223372036854775808"],
    ["LRANGE", "l", "-9223372036854775807", "9223372036854775807"],
  ])

  want = [":1\r\n", ":1\r\n", NOT_INT, NOT_INT, NOT_INT, NOT_INT, "$-1\r\n", WRONGTYPE, NOT_INT, strings(["a"])]
  Test.eq(got, want.join(""))
end

# A list command on a string or a hash key, and the other commands on a list
# key, answer WRONGTYPE; SET replaces a list, and TYPE and SCAN TYPE name it.
def test_wrong_type_both_ways() -> Result[Void]
  on_other = [
    ["LPUSH", "s", "a"],
    ["RPUSH", "s", "a"],
    ["LPUSHX", "s", "a"],
    ["RPUSHX", "s", "a"],
    ["LLEN", "s"],
    ["LINDEX", "s", "0"],
    ["LRANGE", "s", "0", "1"],
    ["LPUSH", "h", "a"],
    ["LLEN", "h"],
  ]

  setup = [["SET", "s", "1"], ["HSET", "h", "f", "1"], ["RPUSH", "l", "a"]]
  try Test.eq(ask(setup.concat(on_other)), "+OK\r\n:1\r\n:1\r\n#{on_other.map { |_| WRONGTYPE }.join("")}")

  on_list = [
    ["GET", "l"],
    ["APPEND", "l", "x"],
    ["STRLEN", "l"],
    ["INCR", "l"],
    ["GETRANGE", "l", "0", "1"],
    ["HSET", "l", "f", "1"],
    ["HGET", "l", "f"],
    ["HLEN", "l"],
  ]

  odd = [["MGET", "l", "s"], ["SETNX", "l", "x"], ["TYPE", "l"], ["TYPE", "s"]]
  try Test.eq(
    ask(setup.concat(on_list).concat(odd)),
    "+OK\r\n:1\r\n:1\r\n#{on_list.map { |_| WRONGTYPE }.join("")}*2\r\n$-1\r\n$1\r\n1\r\n:0\r\n+list\r\n+string\r\n",
  )

  first = talk(setup)
  asked = exchange(first.databases, Bytes.concat([words(["SCAN", "0", "TYPE", "LIST"]), words(["SET", "l", "v"])]), 0)
  try Test.eq(asked.reply.decode("latin-1").unwrap!, "*2\r\n$1\r\n0\r\n*1\r\n$1\r\nl\r\n+OK\r\n")
  Test.eq(
    ask(setup.concat([["SET", "l", "v"], ["TYPE", "l"], ["LLEN", "l"]])),
    "+OK\r\n:1\r\n:1\r\n+OK\r\n+string\r\n#{WRONGTYPE}",
  )
end

# A push keeps the deadline of a live list, and a list that expired is a new
# one: the old elements are gone.
def test_list_deadline() -> Result[Void]
  first = talk([["RPUSH", "l", "a"], ["PEXPIRE", "l", "100"]])
  later = exchange(first.databases, words(["RPUSH", "l", "b"]), 50)
  try Test.eq(
    exchange(later.databases, Bytes.concat([words(["PTTL", "l"]), words(["LLEN", "l"])]), 60).reply.to_a,
    ":40\r\n:2\r\n".bytes.to_a,
  )

  fresh_list = exchange(
    later.databases,
    Bytes.concat([words(["RPUSH", "l", "c"]), words(["LLEN", "l"]), words(["TTL", "l"]), words(["LPUSHX", "l", "d"])]),
    500,
  )

  Test.eq(fresh_list.reply.to_a, ":1\r\n:1\r\n:-1\r\n:2\r\n".bytes.to_a)
end

# One list against a model that is a List: pushes at both ends (also the X
# forms, on a list that may be missing), LLEN, LINDEX and LRANGE with indexes
# on both sides of the ends. The elements are numbers, so the replies are text
# the model can write. 150 runs: the step limit is between 400 and 600 runs.
def test_a_list_follows_a_model() -> Result[Void]
  table = Table.build()
  numbers = Prop.int(0, 99)
  ops = Prop.list(Prop.list(numbers, 3), 25)
  Prop.check(ops, Prop.Config(runs: 150)) do |list|
    requests = list.map do |op| argv_of(op.concat([0, 0, 0])) end
    expected = modeled(list.map do |op| op.concat([0, 0, 0]) end)
    Prop.eq(run_requests(table, fresh(), requests).reply.to_a, expected.bytes.to_a)
  end
end

def argv_of(op: List[Int]) -> List[Bytes]
  value = "v#{op[1]}".bytes
  return case op[0] % 7
    0 -> ["LPUSH".bytes, "k".bytes, value]
    1 -> ["RPUSH".bytes, "k".bytes, value]
    2 -> ["LPUSHX".bytes, "k".bytes, value]
    3 -> ["RPUSHX".bytes, "k".bytes, value]
    4 -> ["LLEN".bytes, "k".bytes]
    5 -> ["LINDEX".bytes, "k".bytes, "#{op[1] % 31 - 15}".bytes]
    _ -> ["LRANGE".bytes, "k".bytes, "#{op[1] % 31 - 15}".bytes, "#{op[2] % 31 - 15}".bytes]
  end
end

# The replies of the same operations over a plain List of text.
def modeled(ops: List[List[Int]]) -> String
  held: List[String] = []
  out = ""
  for op in ops
    value = "v#{op[1]}"
    case op[0] % 7
      0 ->
        held = [value].concat(held)
        out = "#{out}:#{held.size}\r\n"
      1 ->
        held = held.push(value)
        out = "#{out}:#{held.size}\r\n"
      2 ->
        if held.empty?
          out = "#{out}:0\r\n"
        else
          held = [value].concat(held)
          out = "#{out}:#{held.size}\r\n"
        end

      3 ->
        if held.empty?
          out = "#{out}:0\r\n"
        else
          held = held.push(value)
          out = "#{out}:#{held.size}\r\n"
        end

      4 -> out = "#{out}:#{held.size}\r\n"
      5 -> out = "#{out}#{index_reply(held, op[1] % 31 - 15)}"
      _ -> out = "#{out}#{range_reply(held, op[1] % 31 - 15, op[2] % 31 - 15)}"
    end
  end

  out
end

def index_reply(held: List[String], index: Int) -> String
  position = index
  if index < 0
    position = held.size + index
  end

  return "$-1\r\n" if position < 0 or position >= held.size

  bulk(held[position])
end

def range_reply(held: List[String], start: Int, stop: Int) -> String
  first = start
  last = stop
  if start < 0
    first = held.size + start
  end

  if stop < 0
    last = held.size + stop
  end

  picked: List[String] = []
  for i in 0...held.size
    if i >= first and i <= last
      picked = picked.push(held[i])
    end
  end

  strings(picked)
end
