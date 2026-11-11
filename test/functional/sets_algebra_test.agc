## SMOVE, the set algebra (SUNION, SINTER, SDIFF, their STORE forms, SINTERCARD)
## and the leftover of the random commands: a single draw changes with the call.

import {Command} from "../../src/commands/command"
import Databases from "../../src/store/databases"
import {exchange, run_requests, talk, words} from "../support"
import Table from "../../src/commands/table"
import Prop from "pkg/prop/prop"

WRONGTYPE = "-WRONGTYPE Operation against a key holding the wrong kind of value"
NOT_INT = "-ERR value is not an integer or out of range"
SYNTAX = "-ERR syntax error"

def ask(requests: List[List[String]]) -> String = talk(requests).reply.decode("latin-1").unwrap!

def joined(lines: List[String]) -> String = "#{lines.join("\r\n")}\r\n"

# The members a reply lists, sorted: the lines that are no length marker.
def names_in(reply: String) -> List[String]
  lines = reply.split("\r\n").select do |line| line != "" and not ["$", "*", ":"].include?(line.slice(0, 1).to_s) end
  lines.sort
end

# A missing source is 0 even when the destination holds a string; then the
# source's type, then the destination's, even for a member that is not there;
# one key twice only asks; the source left empty goes; a member already at the
# destination is still removed from the source; arity.
def test_smove() -> Result[Void]
  got = ask([
    ["SET", "str", "x"],
    ["SMOVE", "none", "str", "a"],
    ["SMOVE", "str", "t", "a"],
    ["SADD", "s", "a", "b"],
    ["SMOVE", "s", "str", "zz"],
    ["SMOVE", "s", "s", "a"],
    ["SMOVE", "s", "s", "zz"],
    ["SMOVE", "s", "t", "zz"],
    ["EXISTS", "t"],
    ["SMOVE", "s", "t", "a"],
    ["SADD", "t", "b"],
    ["SMOVE", "s", "t", "b"],
    ["EXISTS", "s"],
    ["SCARD", "t"],
    ["SMOVE", "s", "t"],
  ])

  want = [
    "+OK", ":0", WRONGTYPE, ":2", WRONGTYPE, ":1", ":0", ":0", ":0", ":1", ":1", ":1", ":0", ":2",
    "-ERR wrong number of arguments for 'smove' command",
  ]

  try Test.eq(got, joined(want))
  # The source keeps its deadline; the new destination has none; a live one keeps its own.
  first = talk([["SADD", "s", "a", "b"], ["SADD", "d", "x"], ["PEXPIRE", "s", "100"], ["PEXPIRE", "d", "200"]])
  later = exchange(first.databases, words(["SMOVE", "s", "d", "a"]), 50)
  try Test.eq(exchange(later.databases, words(["PTTL", "s"]), 60).reply, ":40\r\n".bytes)
  more = exchange(later.databases, words(["SMOVE", "s", "n", "b"]), 60)
  Test.eq(
    exchange(
      more.databases,
      Bytes.concat([words(["PTTL", "d"]), words(["TTL", "n"]), words(["EXISTS", "s"])]),
      70,
    ).reply,
    ":130\r\n:-1\r\n:0\r\n".bytes,
  )
end

# One read-only request against the databases of a setup, as a short text: an
# array is its member names sorted, anything else is the reply line.
def look(table: Map[String, Command], databases: Databases.Databases, request: List[String]) -> String
  reply = run_requests(table, databases, [request.map do |word| word.bytes end]).reply.decode("latin-1").unwrap!
  return "[#{names_in(reply).join(",")}]" if reply.starts_with?("*")

  reply.trim
end

def looks(setup: List[List[String]], requests: List[List[String]]) -> List[String]
  databases = talk(setup).databases
  table = Table.build()
  requests.map do |request| look(table, databases, request) end
end

# The three readers: a missing key is an empty set; any key of another type is
# WRONGTYPE even when an earlier key is missing (every key is checked first); the
# first key of SDIFF is the one that counts; a key named twice; arity.
def test_union_inter_diff() -> Result[Void]
  setup = [["SADD", "a", "1", "2", "3"], ["SADD", "b", "3", "4"], ["SET", "str", "x"]]
  got = looks(
    setup,
    [
      ["SUNION", "a", "b", "none"],
      ["SUNION", "none"],
      ["SINTER", "a", "b"],
      ["SINTER", "a", "none"],
      ["SINTER", "none", "str"],
      ["SDIFF", "a", "b", "none"],
      ["SDIFF", "b", "a"],
      ["SDIFF", "none", "a"],
      ["SDIFF", "a", "a"],
      ["SDIFF", "a", "none", "a"],
      ["SINTER", "a", "a"],
      ["SUNION", "a", "str"],
      ["SDIFF", "none", "str"],
      ["SUNION"],
    ],
  )

  want = [
    "[1,2,3,4]", "[]", "[3]", "[]", WRONGTYPE, "[1,2]", "[4]", "[]", "[]", "[]", "[1,2,3]", WRONGTYPE, WRONGTYPE,
    "-ERR wrong number of arguments for 'sunion' command",
  ]

  Test.eq(got, want)
end

# A STORE form replaces whatever the destination held, string and deadline
# included, and never reads its type; an empty result deletes the destination
# and answers 0, also for a missing one; the destination may be a source; a
# source of another type is WRONGTYPE and leaves the destination alone.
def test_the_store_forms() -> Result[Void]
  setup = [["SADD", "a", "1", "2", "3"], ["SADD", "b", "3", "4"], ["SET", "d", "x"], ["SET", "str", "x"]]
  got = ask(
    setup.concat([
      ["SUNIONSTORE", "d", "a", "b"],
      ["TYPE", "d"],
      ["SCARD", "d"],
      ["SINTERSTORE", "d", "a", "b"],
      ["SMEMBERS", "d"],
      ["SDIFFSTORE", "d", "d", "b"],
      ["SMEMBERS", "d"],
      ["SINTERSTORE", "d", "a", "none"],
      ["EXISTS", "d"],
      ["SDIFFSTORE", "gone", "none", "a"],
      ["EXISTS", "gone"],
      ["SUNIONSTORE", "d", "a"],
      ["SUNIONSTORE", "d", "a", "str"],
      ["SCARD", "d"],
      ["SDIFFSTORE", "d"],
      ["SUNIONSTORE", "d"],
    ]),
  )

  want = [
    ":4", "+set", ":4", ":1", "*1\r\n$1\r\n3", ":0", "*0", ":0", ":0", ":0", ":0", ":3", WRONGTYPE, ":3",
    "-ERR wrong number of arguments for 'sdiffstore' command",
    "-ERR wrong number of arguments for 'sunionstore' command",
  ]

  try Test.eq(got.split("\r\n").drop(setup.size), joined(want).split("\r\n"))
  first = talk([
    ["SADD", "a", "1"],
    ["SET", "d", "x"],
    ["PEXPIRE", "d", "100"],
    ["SADD", "e", "1"],
    ["PEXPIRE", "e", "100"],
  ])

  stored = exchange(first.databases, words(["SUNIONSTORE", "d", "a"]), 10)
  empty = exchange(stored.databases, words(["SINTERSTORE", "e", "a", "none"]), 20)
  Test.eq(
    exchange(empty.databases, Bytes.concat([words(["TTL", "d"]), words(["EXISTS", "e"])]), 30).reply,
    ":-1\r\n:0\r\n".bytes,
  )
end

# SINTERCARD: numkeys is read first, a word and a number below 1 alike; it must
# fit the arguments; LIMIT n any number of times, the last wins, 0 is no limit,
# a negative or a word is refused with one text; another option is a syntax
# error; a missing key makes 0; the type is checked first.
def test_sintercard() -> Result[Void]
  setup = [["SADD", "a", "1", "2", "3", "4"], ["SADD", "b", "2", "3", "4", "5"], ["SET", "str", "x"]]
  got = looks(
    setup,
    [
      ["SINTERCARD", "2", "a", "b"],
      ["SINTERCARD", "2", "a", "b", "LIMIT", "2"],
      ["SINTERCARD", "2", "a", "b", "limit", "9"],
      ["SINTERCARD", "2", "a", "b", "LIMIT", "0"],
      ["SINTERCARD", "2", "a", "b", "LIMIT", "1", "LIMIT", "2"],
      ["SINTERCARD", "1", "a"],
      ["SINTERCARD", "2", "a", "none"],
      ["SINTERCARD", "2", "none", "str"],
      ["SINTERCARD", "0", "a"],
      ["SINTERCARD", "x", "a"],
      ["SINTERCARD", "-1", "a"],
      ["SINTERCARD", "3", "a", "b"],
      ["SINTERCARD", "9223372036854775807", "a"],
      ["SINTERCARD", "2", "a", "b", "LIMIT", "-1"],
      ["SINTERCARD", "2", "a", "b", "LIMIT", "x"],
      ["SINTERCARD", "2", "a", "b", "LIMIT"],
      ["SINTERCARD", "2", "a", "b", "COUNT", "1"],
      ["SINTERCARD", "2", "a", "b", "LIMIT", "1", "x"],
      ["SINTERCARD", "1"],
    ],
  )

  want = [
    ":3", ":2", ":3", ":3", ":2", ":4", ":0", WRONGTYPE, "-ERR numkeys should be greater than 0",
    "-ERR numkeys should be greater than 0", "-ERR numkeys should be greater than 0",
    "-ERR Number of keys can't be greater than number of args",
    "-ERR Number of keys can't be greater than number of args", "-ERR LIMIT can't be negative",
    "-ERR LIMIT can't be negative", SYNTAX, SYNTAX, SYNTAX, "-ERR wrong number of arguments for 'sintercard' command",
  ]

  Test.eq(got, want)
end

# A single SPOP or SRANDMEMBER draw depends on the call: twenty sets of the same
# five members must not all give the same one.
def test_a_single_draw_varies() -> Result[Void]
  adds = ["a", "b", "c", "d", "e"].map do |name| name end
  keys = (1..20).to_a.map do |n| "s#{n}" end
  setup = keys.map do |key| ["SADD", key].concat(adds) end
  popped = ask(setup.concat(keys.map do |key| ["SPOP", key] end))
  seen = ask(setup.concat(keys.map do |key| ["SRANDMEMBER", key] end))
  try Test.assert(names_in(popped).uniq.size > 1, "SPOP gave one member twenty times")
  Test.assert(names_in(seen).uniq.size > 1, "SRANDMEMBER gave one member twenty times")
end

def capped(size: Int, limit: Int) -> Int
  return size if size < limit

  limit
end

def shown(numbers: List[Int]) -> String = "[#{numbers.uniq.sort.map do |n| "m#{n}" end.join(",")}]"

def minus(first: List[Int], others: List[List[Int]]) -> List[Int]
  first.select do |n| not others.any? do |other| other.include?(n) end end
end

def common(first: List[Int], others: List[List[Int]]) -> List[Int]
  first.select do |n| others.all? do |other| other.include?(n) end end
end

def adds(index: Int, numbers: List[Int]) -> List[List[String]]
  return [] if numbers.empty?

  [["SADD", "s#{index}"].concat(numbers.map do |n| "m#{n}" end)]
end

def stored_and_read(table: Map[String, Command], databases: Databases.Databases, name: String) -> List[String]
  after = run_requests(table, databases, [[name, "d", "s0", "s1", "s2"].map do |word| word.bytes end])
  [
    after.reply.decode("latin-1").unwrap!.trim,
    look(table, after.databases, ["SMEMBERS", "d"]),
    look(table, after.databases, ["EXISTS", "d"]),
  ]
end

# The algebra of three sets (a missing one is an empty set) against lists: the
# three readers with the first key changed, the three STORE forms (the string
# at the destination is replaced, an empty result deletes it) and SINTERCARD
# with and without a LIMIT. 200 runs: it fails at 800 (the step limit).
def test_the_algebra_follows_a_model() -> Result[Void]
  table = Table.build()
  pieces = Prop.list(Prop.int(0, 7), 6)
  gen = Prop.list(pieces, 3)
  Prop.check(gen, Prop.Config(runs: 200)) do |generated|
    lists = generated.concat([[], [], []]).take(3)
    setup = [["SET", "d", "x"]].concat(adds(0, lists[0])).concat(adds(1, lists[1])).concat(adds(2, lists[2]))
    databases = talk(setup).databases
    rest = [lists[1], lists[2]]
    inter = common(lists[0], rest).uniq
    union = lists[0].concat(lists[1]).concat(lists[2]).uniq
    diff = minus(lists[0], rest).uniq
    keys = ["s0", "s1", "s2"]
    got = [
      look(table, databases, ["SUNION"].concat(keys)),
      look(table, databases, ["SINTER"].concat(keys)),
      look(table, databases, ["SDIFF"].concat(keys)),
      look(table, databases, ["SDIFF", "s1", "s0", "s2"]),
      look(table, databases, ["SINTERCARD", "3"].concat(keys)),
      look(table, databases, ["SINTERCARD", "3"].concat(keys).concat(["LIMIT", "2"])),
    ]
      .concat(stored_and_read(table, databases, "SUNIONSTORE"))
      .concat(stored_and_read(table, databases, "SINTERSTORE"))
      .concat(stored_and_read(table, databases, "SDIFFSTORE"))

    want = [
      shown(union),
      shown(inter),
      shown(diff),
      shown(minus(lists[1], [lists[0], lists[2]])),
      ":#{inter.size}",
      ":#{capped(inter.size, 2)}",
    ]

    for result in [union, inter, diff]
      want = want.concat([":#{result.size}", shown(result), ":#{capped(result.size, 1)}"])
    end

    Prop.eq(got.join("|"), want.join("|"))
  end
end
