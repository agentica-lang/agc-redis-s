## The set commands and the type checks between sets and the other types.

import Scan from "../../src/store/scan"
import Table from "../../src/commands/table"
import {exchange, run_requests, talk, words} from "../support"
import {fresh} from "../../src/store/databases"
import Prop from "pkg/prop/prop"

WRONGTYPE = "-WRONGTYPE Operation against a key holding the wrong kind of value"
NOT_INT = "-ERR value is not an integer or out of range"
POSITIVE = "-ERR value is out of range, must be positive"

def ask(requests: List[List[String]]) -> String = talk(requests).reply.decode("latin-1").unwrap!

def joined(lines: List[String]) -> String = "#{lines.join("\r\n")}\r\n"

# The members a reply lists, sorted: the lines that are no length marker.
def names_in(reply: String) -> List[String]
  lines = reply.split("\r\n").select do |line| line != "" and not ["$", "*", ":"].include?(line.slice(0, 1).to_s) end
  lines.sort
end

# A member named twice counts once; SREM counts what was there; the key goes
# with its last member; the questions about a missing key answer as for an empty
# set; a lone SADD key is an arity error.
def test_add_remove_and_ask() -> Result[Void]
  got = ask([
    ["SADD", "s", "a", "b", "a"],
    ["SADD", "s", "b", "c"],
    ["SCARD", "s"],
    ["SISMEMBER", "s", "a"],
    ["SISMEMBER", "s", "zz"],
    ["SMISMEMBER", "s", "c", "zz", "a", "a"],
    ["SMEMBERS", "none"],
    ["SCARD", "none"],
    ["SISMEMBER", "none", "a"],
    ["SMISMEMBER", "none", "a", "b"],
    ["SREM", "s", "a", "a", "zz"],
    ["SREM", "s", "zz"],
    ["SREM", "none", "a"],
    ["SREM", "s", "b", "c"],
    ["EXISTS", "s"],
    ["SADD", "s"],
    ["SMEMBERS"],
  ])

  want = [
    ":2", ":1", ":3", ":1", ":0", "*4\r\n:1\r\n:0\r\n:1\r\n:1", "*0", ":0", ":0", "*2\r\n:0\r\n:0", ":1", ":0", ":0",
    ":2", ":0", "-ERR wrong number of arguments for 'sadd' command",
    "-ERR wrong number of arguments for 'smembers' command",
  ]

  try Test.eq(got, joined(want))
  # The slot of a removed member is taken by the last one: nothing is lost.
  moved = ask([["SADD", "s", "a", "b", "c", "d"], ["SREM", "s", "a", "c"], ["SADD", "s", "e"], ["SMEMBERS", "s"]])
  Test.eq(names_in(moved), ["b", "d", "e"])
end

# A set command on another type and another type's command on a set answer
# WRONGTYPE, except the ones that replace the value (SET) or only look whether
# the key exists (SETNX), and MGET, which answers nil. A bad count wins over the
# type for SPOP and SRANDMEMBER, as in Redis. TYPE and SCAN TYPE know sets.
def test_wrong_type_both_ways() -> Result[Void]
  on_set = [
    ["GET", "s"],
    ["APPEND", "s", "x"],
    ["STRLEN", "s"],
    ["INCR", "s"],
    ["HGET", "s", "a"],
    ["HSET", "s", "a", "1"],
    ["LPUSH", "s", "a"],
    ["LLEN", "s"],
    ["SET", "s", "v", "GET"],
  ]

  setup = [["SADD", "s", "a"], ["SET", "str", "1"]]
  try Test.eq(ask(setup.concat(on_set)), joined([":1", "+OK"].concat(on_set.map do |_| WRONGTYPE end)))
  on_string = [
    ["SADD", "str", "a"],
    ["SREM", "str", "a"],
    ["SISMEMBER", "str", "a"],
    ["SMISMEMBER", "str", "a"],
    ["SCARD", "str"],
    ["SMEMBERS", "str"],
    ["SPOP", "str"],
    ["SPOP", "str", "2"],
    ["SRANDMEMBER", "str"],
    ["SRANDMEMBER", "str", "2"],
    ["SSCAN", "str", "0"],
  ]

  try Test.eq(ask(setup.concat(on_string)), joined([":1", "+OK"].concat(on_string.map do |_| WRONGTYPE end)))
  odd = ask(
    setup.concat([
      ["MGET", "s", "str"],
      ["SETNX", "s", "x"],
      ["TYPE", "s"],
      ["SCAN", "0", "TYPE", "set"],
      ["SPOP", "str", "x"],
      ["SRANDMEMBER", "str", "x"],
      ["SET", "s", "v"],
      ["TYPE", "s"],
      ["SADD", "s", "a"],
    ]),
  )

  want = [
    ":1", "+OK", "*2\r\n$-1\r\n$1\r\n1", ":0", "+set", "*2\r\n$1\r\n0\r\n*1\r\n$1\r\ns", POSITIVE, NOT_INT, "+OK",
    "+string", WRONGTYPE,
  ]

  Test.eq(odd, joined(want))
end

# A write keeps the deadline of a live set; the last member takes the key and so
# the deadline, and a set made later has none; an expired set is a new one.
def test_deadlines() -> Result[Void]
  first = talk([["SADD", "s", "a", "b"], ["PEXPIRE", "s", "100"]])
  later = exchange(first.databases, words(["SADD", "s", "c"]), 50)
  try Test.eq(
    exchange(later.databases, Bytes.concat([words(["PTTL", "s"]), words(["SREM", "s", "a"])]), 60).reply.to_a,
    ":40\r\n:1\r\n".bytes.to_a,
  )

  fresh_set = exchange(
    later.databases,
    Bytes.concat([words(["SADD", "s", "x"]), words(["SCARD", "s"]), words(["TTL", "s"])]),
    500,
  )

  try Test.eq(fresh_set.reply.to_a, ":1\r\n:1\r\n:-1\r\n".bytes.to_a)
  got = ask([
    ["SADD", "s", "a", "b"],
    ["PEXPIRE", "s", "100000"],
    ["SPOP", "s", "5"],
    ["SADD", "s", "a"],
    ["TTL", "s"],
    ["SPOP", "s"],
    ["SADD", "s", "a"],
    ["TTL", "s"],
    ["SREM", "s", "a"],
    ["SADD", "s", "a"],
    ["TTL", "s"],
  ])

  Test.eq(
    got,
    joined([":2", ":1", "*2\r\n$1\r\na\r\n$1\r\nb", ":1", ":-1", "$1\r\na", ":1", ":-1", ":1", ":1", ":-1"]),
  )
end

# SPOP: one member, or up to a count; the members popped and the ones left are
# the whole set, none twice; a count that covers the set gives all of it and the
# key goes; a missing key is nil, or an empty array with a count; the count is
# read before the key and a word or a negative number is refused with the same
# text.
def test_spop() -> Result[Void]
  setup = [["SADD", "s", "a", "b", "c", "d", "e"]]
  everything = ["a", "b", "c", "d", "e"]
  two = ask(setup.concat([["SPOP", "s", "2"], ["SMEMBERS", "s"], ["SCARD", "s"]]))
  try Test.assert(two.start_with?(":5\r\n*2\r\n") and two.end_with?(":3\r\n"), "two popped: #{two}")
  try Test.eq(names_in(two).size, 5)
  try Test.eq(names_in(two).uniq, everything)
  one = ask(setup.concat([["SPOP", "s"], ["SMEMBERS", "s"]]))
  try Test.assert(one.start_with?(":5\r\n$1\r\n"), "one popped: #{one}")
  try Test.eq(names_in(one).uniq, everything)
  try Test.eq(names_in(one).size, 5)
  every = ask(setup.concat([["SPOP", "s", "9"], ["EXISTS", "s"], ["SPOP", "s", "0"], ["SPOP", "s"]]))
  try Test.assert(every.start_with?(":5\r\n*5\r\n") and every.end_with?(":0\r\n*0\r\n$-1\r\n"), every)
  try Test.eq(names_in(every), everything)
  got = ask([
    ["SADD", "s", "a"],
    ["SPOP", "s", "0"],
    ["SPOP", "none"],
    ["SPOP", "none", "3"],
    ["SPOP", "none", "x"],
    ["SPOP", "s", "-1"],
    ["SPOP", "s", "1", "2"],
  ])

  want = [":1", "*0", "$-1", "*0", POSITIVE, POSITIVE, "-ERR syntax error"]

  Test.eq(got, joined(want))
end

# SRANDMEMBER: one member; a count that covers the set gives all of it; a
# smaller one gives that many different members; a negative one gives that many
# with repeats; the set is never changed. A missing key is nil, or an empty
# array with a count.
def test_srandmember() -> Result[Void]
  setup = [["SADD", "s", "a", "b", "c", "d", "e"]]
  all = ask(setup.concat([["SRANDMEMBER", "s", "9"], ["SRANDMEMBER", "s", "5"], ["SRANDMEMBER", "s", "0"]]))
  try Test.eq(names_in(all).size, 10)
  try Test.assert(all.include?("*5\r\n"), "the whole set")
  try Test.assert(all.end_with?("*0\r\n"), "zero is empty")
  # Ten draws of 3 different members.
  for _ in 0...10
    picked = ask(setup.concat([["SRANDMEMBER", "s", "3"]]))
    names = names_in(picked)
    try Test.assert(names[0] != names[1] and names[1] != names[2], "three different members: #{names}")
  end

  noise = ask(setup.concat([["SRANDMEMBER", "s", "-40"], ["SCARD", "s"]]))
  try Test.assert(names_in(noise).size == 40 and noise.end_with?(":5\r\n"), "forty members, the set stays")
  single = ask(setup.concat([["SRANDMEMBER", "s"], ["SRANDMEMBER", "s", "1"]]))
  try Test.assert(single.start_with?(":5\r\n$1\r\n") and single.include?("*1\r\n$1\r\n"), "one member each")
  got = ask([
    ["SRANDMEMBER", "none"],
    ["SRANDMEMBER", "none", "3"],
    ["SRANDMEMBER", "none", "-3"],
    ["SRANDMEMBER", "none", "x"],
    ["SRANDMEMBER", "none", "-9223372036854775808"],
    ["SRANDMEMBER", "none", "9223372036854775807"],
    ["SRANDMEMBER", "none", "1", "2"],
    ["SADD", "s", "a"],
    ["SRANDMEMBER", "s", "-1000000000"],
    ["SRANDMEMBER", "s", "-1300001"],
  ])

  want = [
    "$-1", "*0", "*0", NOT_INT,
    "-ERR value is out of range, value must between -9223372036854775807 and 9223372036854775807", "*0",
    "-ERR syntax error", ":1", "-ERR count is too large for the output limit",
    "-ERR count is too large for the output limit",
  ]

  Test.eq(got, joined(want))
end

def pair(name: String) -> String = "$#{name.size}\r\n#{name}\r\n"

# SSCAN pages by the hash of the member, as SCAN does: COUNT 1 gives one member
# and the hash of the next as the cursor; MATCH filters; TYPE is a syntax error;
# a missing key is an empty scan; the cursor is read before the key.
def test_sscan() -> Result[Void]
  setup = [["SADD", "s", "a", "b", "c"], ["SET", "str", "1"]]
  names = ["a", "b", "c"].sort_by do |name| Scan.hash(name.bytes) end
  next = "#{Scan.hash(names[1].bytes)}"
  first = "*2\r\n$#{next.size}\r\n#{next}\r\n*1\r\n#{pair(names[0])}"
  rest = "*2\r\n$1\r\n0\r\n*2\r\n#{pair(names[1])}#{pair(names[2])}"
  got = ask(setup.concat([["SSCAN", "s", "0", "COUNT", "1"], ["SSCAN", "s", next, "COUNT", "5"]]))
  try Test.eq(got, ":3\r\n+OK\r\n#{first}#{rest}")
  more = ask(
    setup.concat([
      ["SSCAN", "s", "0", "MATCH", "b"],
      ["SSCAN", "s", "0", "TYPE", "set"],
      ["SSCAN", "none", "0"],
      ["SSCAN", "str", "0"],
      ["SSCAN", "s", "x"],
      ["SSCAN", "str", "x"],
      ["SSCAN", "s", "0", "COUNT", "0"],
    ]),
  )

  want = [
    ":3",
    "+OK",
    "*2\r\n$1\r\n0\r\n*1\r\n#{pair("b").strip}",
    "-ERR syntax error",
    "*2\r\n$1\r\n0\r\n*0",
    WRONGTYPE,
    "-ERR invalid cursor",
    "-ERR invalid cursor",
    "-ERR syntax error",
  ]

  Test.eq(more, joined(want))
end

def argv_for(op: List[Int]) -> List[Bytes]
  xs = op.concat([0, 0, 0, 0])
  first = "m#{xs[1] % 5}".bytes
  second = "m#{xs[2] % 5}".bytes
  return case xs[0] % 5
    0 -> ["SADD".bytes, "s".bytes, first, second]
    1 -> ["SREM".bytes, "s".bytes, first, second]
    2 -> ["SISMEMBER".bytes, "s".bytes, first]
    3 -> ["SMISMEMBER".bytes, "s".bytes, first, second]
    _ -> ["SCARD".bytes, "s".bytes]
  end
end

def has(members: List[Int], n: Int) -> Int
  return 1 if members.include?(n)

  0
end

def without(members: List[Int], n: Int) -> List[Int] = members.select do |one| one != n end

# SADD, SREM, SISMEMBER, SMISMEMBER and SCARD on one set against the model, and
# the members at the end. 180 runs: it fails at 600 (the step limit).
def test_a_set_follows_a_model() -> Result[Void]
  table = Table.build()
  numbers = Prop.int(0, 255)
  ops = Prop.list(Prop.list(numbers, 4), 24)
  Prop.check(ops, Prop.Config(runs: 180)) do |list|
    held: List[Int] = []
    expected: List[String] = []
    for op in list
      xs = op.concat([0, 0, 0, 0])
      first = xs[1] % 5
      second = xs[2] % 5
      case xs[0] % 5
        0 ->
          grown = held.concat([first, second]).uniq
          expected = expected.push(":#{grown.size - held.size}")
          held = grown
        1 ->
          left = without(without(held, first), second)
          expected = expected.push(":#{held.size - left.size}")
          held = left
        2 -> expected = expected.push(":#{has(held, first)}")
        3 -> expected = expected.push("*2\r\n:#{has(held, first)}\r\n:#{has(held, second)}")
        _ -> expected = expected.push(":#{held.size}")
      end
    end

    got = run_requests(table, fresh(), list.map do |op| argv_for(op) end)
    final = exchange(got.databases, words(["SMEMBERS", "s"]), 0).reply.decode("latin-1").unwrap!
    sorted = held.sort.map do |n| "m#{n}" end
    shown = expected.map { |line| "#{line}\r\n" }.join("")
    replies = got.reply.decode("latin-1").unwrap!
    Prop.eq("#{replies}#{names_in(final)}", "#{shown}#{sorted}")
  end
end
