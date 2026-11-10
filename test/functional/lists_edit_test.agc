## The list commands that remove or change elements: LPOP, RPOP, LSET, LTRIM,
## LINSERT, LREM and LPOS.

import Table from "../../src/commands/table"
import {exchange, run_requests, talk, words} from "../support"
import {fresh} from "../../src/store/databases"
import Prop from "pkg/prop/prop"

WRONGTYPE = "-WRONGTYPE Operation against a key holding the wrong kind of value\r\n"
NOT_INT = "-ERR value is not an integer or out of range\r\n"
POSITIVE = "-ERR value is out of range, must be positive\r\n"
SYNTAX = "-ERR syntax error\r\n"

def ask(requests: List[List[String]]) -> String
  return talk(requests).reply.decode("latin-1").unwrap!
end

def bulk(text: String) -> String
  return "$#{text.size}\r\n#{text}\r\n"
end

def strings(items: List[String]) -> String
  return "*#{items.size}\r\n#{items.map do |item| bulk(item) end.join("")}"
end

def numbers(items: List[Int]) -> String
  return "*#{items.size}\r\n#{items.map do |item| ":#{item}\r\n" end.join("")}"
end

# Pops take one element or up to a count (a count past the length takes all);
# RPOP with a count replies from the tail inwards. A missing key is nil, or a
# null array with a count, and 0 on a live list is an empty array. The count is
# read before the key, with Redis's one text for a word and a negative number.
# The key goes with its last element, and so does its deadline.
def test_pops() -> Result[Void]
  got = ask([
    ["RPUSH", "l", "a", "b", "c", "d", "e"],
    ["LPOP", "l"],
    ["RPOP", "l"],
    ["LPOP", "l", "0"],
    ["LPOP", "l", "2"],
    ["RPUSH", "l", "x", "y"],
    ["RPOP", "l", "2"],
    ["LRANGE", "l", "0", "-1"],
    ["RPOP", "l", "100"],
    ["EXISTS", "l"],
    ["LPOP", "l"],
    ["LPOP", "l", "1"],
    ["RPOP", "none"],
    ["LPOP", "none", "x"],
    ["LPOP", "none", "-1"],
    ["LPOP", "l", "1", "2"],
    ["LPOP"],
  ])

  want = [
    ":5\r\n",
    bulk("a"),
    bulk("e"),
    "*0\r\n",
    strings(["b", "c"]),
    ":3\r\n",
    strings(["y", "x"]),
    strings(["d"]),
    strings(["d"]),
    ":0\r\n",
    "$-1\r\n",
    "*-1\r\n",
    "$-1\r\n",
    POSITIVE,
    POSITIVE,
    "-ERR wrong number of arguments for 'lpop' command\r\n",
    "-ERR wrong number of arguments for 'lpop' command\r\n",
  ]

  return Test.eq(got, want.join(""))
end

# A popped-out list drops its deadline: a new list at the key has none.
def test_an_emptied_list_loses_its_deadline() -> Result[Void]
  got = ask([
    ["RPUSH", "l", "a"],
    ["PEXPIRE", "l", "5000"],
    ["LPOP", "l"],
    ["RPUSH", "l", "b"],
    ["PTTL", "l"],
    ["LTRIM", "l", "1", "0"],
    ["EXISTS", "l"],
    ["RPUSH", "l", "b", "b"],
    ["PEXPIRE", "l", "5000"],
    ["LREM", "l", "0", "b"],
    ["EXISTS", "l"],
  ])

  return Test.eq(got, ":1\r\n:1\r\n#{bulk("a")}:1\r\n:-1\r\n+OK\r\n:0\r\n:2\r\n:1\r\n:2\r\n:0\r\n")
end

# Every command that changes a list but leaves it non-empty keeps the deadline
# (the model law of deadline_test.agc covers it too, but meets it rarely).
def test_edits_keep_the_deadline() -> Result[Void]
  got = ask([
    ["RPUSH", "l", "a", "b", "c", "d", "e", "f", "g", "h"],
    ["PEXPIRE", "l", "1000"],
    ["LSET", "l", "0", "z"],
    ["PTTL", "l"],
    ["LTRIM", "l", "0", "6"],
    ["PTTL", "l"],
    ["LPOP", "l", "2"],
    ["PTTL", "l"],
    ["RPOP", "l", "1"],
    ["PTTL", "l"],
    ["LINSERT", "l", "AFTER", "d", "y"],
    ["PTTL", "l"],
    ["LREM", "l", "1", "y"],
    ["PTTL", "l"],
  ])

  want = [":8\r\n", ":1\r\n", "+OK\r\n", ":1000\r\n", "+OK\r\n", ":1000\r\n"]
  want = want.concat([strings(["z", "b"]), ":1000\r\n", strings(["g"]), ":1000\r\n"])
  want = want.concat([":5\r\n", ":1000\r\n", ":1\r\n", ":1000\r\n"])
  return Test.eq(got, want.join(""))
end

# LSET replaces by index (negative from the tail) and answers OK; a missing key
# is an error before the index is read; the index must be in the list.
def test_lset_and_ltrim() -> Result[Void]
  got = ask([
    ["RPUSH", "l", "a", "b", "c", "d"],
    ["LSET", "l", "0", "A"],
    ["LSET", "l", "-1", "D"],
    ["LSET", "l", "4", "x"],
    ["LSET", "l", "-5", "x"],
    ["LSET", "l", "x", "x"],
    ["LSET", "none", "x", "x"],
    ["LTRIM", "l", "1", "-2"],
    ["LRANGE", "l", "0", "-1"],
    ["LTRIM", "l", "x", "1"],
    ["LTRIM", "none", "0", "y"],
    ["LTRIM", "none", "0", "1"],
    ["LTRIM", "l", "-100", "100"],
    ["LRANGE", "l", "0", "-1"],
    ["LTRIM", "l", "5", "9"],
    ["EXISTS", "l"],
  ])

  out_of_range = "-ERR index out of range\r\n"
  want = [
    ":4\r\n",
    "+OK\r\n",
    "+OK\r\n",
    out_of_range,
    out_of_range,
    NOT_INT,
    "-ERR no such key\r\n",
    "+OK\r\n",
    strings(["b", "c"]),
    NOT_INT,
    NOT_INT,
    "+OK\r\n",
    "+OK\r\n",
    strings(["b", "c"]),
    "+OK\r\n",
    ":0\r\n",
  ]

  return Test.eq(got, want.join(""))
end

# LINSERT: the word is checked before the key, the first pivot from the head
# counts, a missing pivot answers -1 and a missing key 0. LREM removes from the
# head for a positive count, from the tail for a negative one, all for 0.
def test_linsert_and_lrem() -> Result[Void]
  got = ask([
    ["RPUSH", "l", "a", "b", "a", "b", "a"],
    ["LINSERT", "l", "BEFORE", "b", "x"],
    ["LINSERT", "l", "after", "a", "y"],
    ["LINSERT", "l", "AFTER", "zz", "q"],
    ["LINSERT", "none", "AFTER", "a", "q"],
    ["LINSERT", "none", "MIDDLE", "a", "q"],
    ["LRANGE", "l", "0", "-1"],
    ["LREM", "l", "1", "a"],
    ["LREM", "l", "-1", "b"],
    ["LREM", "l", "0", "a"],
    ["LRANGE", "l", "0", "-1"],
    ["LREM", "l", "x", "a"],
    ["LREM", "none", "x", "a"],
    ["LREM", "none", "0", "a"],
    ["RPUSH", "l", "b"],
    ["LREM", "l", "-9223372036854775808", "b"],
    ["EXISTS", "l"],
  ])

  want = [
    ":5\r\n",
    ":6\r\n",
    ":7\r\n",
    ":-1\r\n",
    ":0\r\n",
    SYNTAX,
    strings(["a", "y", "x", "b", "a", "b", "a"]),
    ":1\r\n",
    ":1\r\n",
    ":2\r\n",
    strings(["y", "x", "b"]),
    NOT_INT,
    NOT_INT,
    ":0\r\n",
    ":4\r\n",
    ":2\r\n",
    ":1\r\n",
  ]

  return Test.eq(got, want.join(""))
end

# LPOS: rank from the head or the tail, COUNT (0 is all), MAXLEN, indexes as
# LINDEX would say them, and Redis's texts; the options are read before the key.
def test_lpos() -> Result[Void]
  got = ask([
    ["RPUSH", "l", "a", "b", "a", "c", "a"],
    ["LPOS", "l", "a"],
    ["LPOS", "l", "a", "RANK", "2"],
    ["LPOS", "l", "a", "RANK", "-1"],
    ["LPOS", "l", "a", "RANK", "-4"],
    ["LPOS", "l", "a", "COUNT", "0"],
    ["LPOS", "l", "a", "COUNT", "2", "RANK", "2"],
    ["LPOS", "l", "a", "RANK", "-1", "COUNT", "0"],
    ["LPOS", "l", "a", "MAXLEN", "2"],
    ["LPOS", "l", "a", "MAXLEN", "3", "COUNT", "0"],
    ["LPOS", "l", "zz"],
    ["LPOS", "l", "zz", "COUNT", "0"],
    ["LPOS", "none", "a"],
    ["LPOS", "none", "a", "count", "1"],
    ["LPOS", "l", "a", "RANK", "0"],
    ["LPOS", "l", "a", "RANK", "-9223372036854775808"],
    ["LPOS", "l", "a", "RANK", "x"],
    ["LPOS", "l", "a", "COUNT", "-1"],
    ["LPOS", "l", "a", "MAXLEN", "x"],
    ["LPOS", "l", "a", "RANK"],
    ["LPOS", "l", "a", "FOO", "1"],
    ["LPOS", "h", "a", "RANK", "0"],
  ])

  zero = (
    "-ERR RANK can't be zero: use 1 to start from the first match, 2 from the second ... or use negative to start from the end of the list\r\n"
  )

  range = "-ERR value is out of range, value must between -9223372036854775807 and 9223372036854775807\r\n"
  want = [
    ":5\r\n",
    ":0\r\n",
    ":2\r\n",
    ":4\r\n",
    "$-1\r\n",
    numbers([0, 2, 4]),
    numbers([2, 4]),
    numbers([4, 2, 0]),
    ":0\r\n",
    numbers([0, 2]),
    "$-1\r\n",
    "*0\r\n",
    "$-1\r\n",
    "*0\r\n",
    zero,
    range,
    NOT_INT,
    "-ERR COUNT can't be negative\r\n",
    "-ERR MAXLEN can't be negative\r\n",
    SYNTAX,
    SYNTAX,
    zero,
  ]

  return Test.eq(got, want.join(""))
end

# The new commands on a string or a hash key answer WRONGTYPE; on a list key
# the string commands do, and LSET reads its index only after the type check.
def test_wrong_type() -> Result[Void]
  on_other = [
    ["LPOP", "s"],
    ["RPOP", "s", "1"],
    ["LSET", "s", "0", "a"],
    ["LTRIM", "s", "0", "1"],
    ["LINSERT", "s", "BEFORE", "a", "b"],
    ["LREM", "s", "0", "a"],
    ["LPOS", "s", "a"],
    ["LPOP", "h"],
  ]

  setup = [["SET", "s", "1"], ["HSET", "h", "f", "1"], ["RPUSH", "l", "a"]]
  try Test.eq(ask(setup.concat(on_other)), "+OK\r\n:1\r\n:1\r\n#{on_other.map do |_| WRONGTYPE end.join("")}")
  more = [
    ["SETRANGE", "l", "0", "x"],
    ["INCRBYFLOAT", "l", "1"],
    ["LSET", "l", "x", "a"],
    ["LPOS", "l", "a", "RANK", "0"],
  ]

  return Test.eq(
    ask(setup.concat(more)),
    "+OK\r\n:1\r\n:1\r\n#{WRONGTYPE}#{WRONGTYPE}#{NOT_INT}-ERR RANK can't be zero: use 1 to start from the first match, 2 from the second ... or use negative to start from the end of the list\r\n",
  )
end

# One list against a model that is a List: the pops (with and without a
# count), LSET, LTRIM, LINSERT, LREM and LPOS, next to pushes and LRANGE to see
# the list. The model writes each command with plain List operations. 150 runs:
# the step limit is between 400 and 600 runs.
def test_a_list_follows_a_model() -> Result[Void]
  table = Table.build()
  numbers = Prop.int(0, 99)
  ops = Prop.list(Prop.list(numbers, 4), 25)
  return Prop.check(ops, Prop.Config(runs: 150)) do |list|
    padded = list.map do |op| op.concat([0, 0, 0, 0]) end
    expected = modeled(padded)
    requests = padded.map do |op| argv_of(op) end
    got = run_requests(table, fresh(), requests).reply
    Prop.eq(got.to_a, expected.bytes.to_a)
  end
end

# Indexes reach 8 past either end of a list that is mostly shorter, and counts
# go past its length, so the clamps and the take-all branches are met.
def small(n: Int) -> Int
  return n % 17 - 8
end

def count_of(n: Int) -> Int
  return n % 12
end

def rank_of(n: Int) -> Int
  if small(n) == 0
    return 1
  end

  return small(n)
end

def argv_of(op: List[Int]) -> List[Bytes]
  key = "k".bytes
  value = "v#{op[1] % 4}".bytes
  return case op[0] % 13
    0 -> ["RPUSH".bytes, key, value, "v#{op[2] % 4}".bytes]
    1 -> ["LPUSH".bytes, key, value]
    2 -> ["LPOP".bytes, key]
    3 -> ["RPOP".bytes, key]
    4 -> ["LPOP".bytes, key, "#{count_of(op[1])}".bytes]
    5 -> ["RPOP".bytes, key, "#{count_of(op[1])}".bytes]
    6 -> ["LSET".bytes, key, "#{small(op[1])}".bytes, value]
    7 -> ["LTRIM".bytes, key, "#{small(op[1])}".bytes, "#{small(op[2])}".bytes]
    8 -> ["LINSERT".bytes, key, ["BEFORE".bytes, "AFTER".bytes][op[2] % 2], "v#{op[3] % 4}".bytes, value]
    9 -> ["LREM".bytes, key, "#{small(op[1])}".bytes, "v#{op[2] % 4}".bytes]
    10 -> ["LPOS".bytes, key, value, "RANK".bytes, "#{rank_of(op[2])}".bytes, "COUNT".bytes, "0".bytes]
    11 -> ["LPOS".bytes, key, value]
    _ -> ["LRANGE".bytes, key, "0".bytes, "-1".bytes]
  end
end

def at_most(count: Int, held: List[String]) -> Int
  if count > held.size
    return held.size
  end

  return count
end

# The replies of the same operations over a plain List of text.
def modeled(ops: List[List[Int]]) -> String
  held: List[String] = []
  out = ""
  for op in ops
    value = "v#{op[1] % 4}"
    other = "v#{op[2] % 4}"
    case op[0] % 13
      0 ->
        held = held.push(value).push(other)
        out = "#{out}:#{held.size}\r\n"
      1 ->
        held = [value].concat(held)
        out = "#{out}:#{held.size}\r\n"
      2 ->
        out = "#{out}#{popped_one(held, true)}"
        held = after_pop(held, 1, true)
      3 ->
        out = "#{out}#{popped_one(held, false)}"
        held = after_pop(held, 1, false)
      4 ->
        out = "#{out}#{popped_many(held, count_of(op[1]), true)}"
        held = after_pop(held, count_of(op[1]), true)
      5 ->
        out = "#{out}#{popped_many(held, count_of(op[1]), false)}"
        held = after_pop(held, count_of(op[1]), false)
      6 ->
        index = small(op[1])
        if held.empty?
          out = "#{out}-ERR no such key\r\n"
        elsif index >= held.size or index < 0 - held.size
          out = "#{out}-ERR index out of range\r\n"
        else
          held = replaced(held, index, value)
          out = "#{out}+OK\r\n"
        end

      7 ->
        held = trimmed(held, small(op[1]), small(op[2]))
        out = "#{out}+OK\r\n"
      8 ->
        at = position_of(held, "v#{op[3] % 4}")
        if held.empty?
          out = "#{out}:0\r\n"
        elsif at < 0
          out = "#{out}:-1\r\n"
        else
          cut = at + op[2] % 2
          held = held.take(cut).push(value).concat(held.drop(cut))
          out = "#{out}:#{held.size}\r\n"
        end

      9 ->
        removal = removed(held, small(op[1]), other)
        out = "#{out}:#{held.size - removal.size}\r\n"
        held = removal
      10 -> out = "#{out}#{positions(held, value, rank_of(op[2]))}"
      11 -> out = "#{out}#{first_position(held, value)}"
      _ -> out = "#{out}#{listing(held)}"
    end
  end

  return out
end

def listing(held: List[String]) -> String
  return strings(held)
end

def popped_one(held: List[String], front: Bool) -> String
  if held.empty?
    return "$-1\r\n"
  end

  if front
    return bulk(held[0])
  end

  return bulk(held[held.size - 1])
end

def popped_many(held: List[String], count: Int, front: Bool) -> String
  if held.empty?
    return "*-1\r\n"
  end

  taken = at_most(count, held)
  if front
    return strings(held.take(taken))
  end

  return strings(held.drop(held.size - taken).reverse)
end

def after_pop(held: List[String], count: Int, front: Bool) -> List[String]
  taken = at_most(count, held)
  if front
    return held.drop(taken)
  end

  return held.take(held.size - taken)
end

def replaced(held: List[String], index: Int, value: String) -> List[String]
  position = index
  if index < 0
    position = held.size + index
  end

  return held.take(position).push(value).concat(held.drop(position + 1))
end

def trimmed(held: List[String], start: Int, stop: Int) -> List[String]
  first = start
  last = stop
  if start < 0
    first = held.size + start
  end

  if stop < 0
    last = held.size + stop
  end

  kept: List[String] = []
  for i in 0...held.size
    if i >= first and i <= last
      kept = kept.push(held[i])
    end
  end

  return kept
end

def position_of(held: List[String], wanted: String) -> Int
  for i in 0...held.size
    if held[i] == wanted
      return i
    end
  end

  return -1
end

# A positive count removes the first matches, a negative one the last, 0 all.
def removed(held: List[String], count: Int, wanted: String) -> List[String]
  limit = count
  if count < 0
    limit = 0 - count
  end

  kept: List[String] = []
  gone = 0
  indexes = (0...held.size).to_a
  if count < 0
    indexes = indexes.reverse
  end

  dropped: Map[Int, Bool] = {}
  for i in indexes
    if held[i] == wanted and (count == 0 or gone < limit)
      dropped = dropped.put(i, true)
      gone += 1
    end
  end

  for i in 0...held.size
    if not dropped.has_key?(i)
      kept = kept.push(held[i])
    end
  end

  return kept
end

def first_position(held: List[String], wanted: String) -> String
  at = position_of(held, wanted)
  if at < 0
    return "$-1\r\n"
  end

  return ":#{at}\r\n"
end

# LPOS with COUNT 0 and a rank: all the matches from the rank-th on, from the
# head or, for a negative rank, from the tail. A list that is missing is an
# empty array.
def positions(held: List[String], wanted: String, rank: Int) -> String
  hits: List[Int] = []
  seen = 0
  for step in 0...held.size
    index = step
    if rank < 0
      index = held.size - 1 - step
    end

    if held[index] == wanted
      seen += 1
      if seen >= rank.abs
        hits = hits.push(index)
      end
    end
  end

  return numbers(hits)
end
