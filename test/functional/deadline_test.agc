## The deadline of a key: SET's time options, GETEX, SETEX, PSETEX, the EXPIRE
## family, TTL, PERSIST, and the commands that keep or drop a deadline. The
## clock is an argument of `exchange`, so no test sleeps.

import Requests from "../../src/commands/session"
import Table from "../../src/commands/table"
import {Databases, fresh} from "../../src/store/databases"
import {Command} from "../../src/commands/command"
import {Exchange, exchange, to_bytes, words} from "../support"
import Prop from "pkg/prop/prop"

HIGH = "9223372036854775807"
NOT_INT = "-ERR value is not an integer or out of range\r\n"

# One key of the model: its value and its deadline, if it has one.
struct Entry
  value: List[Int]
  due: Optional[Int]
end

struct Model
  state: Map[Int, Entry]
  replies: List[Bytes]
end

# The requests at the clock `now`, on the databases a request before left.
def at(databases: Databases, now: Int, requests: List[List[String]]) -> Exchange
  return exchange(databases, Bytes.concat(requests.map do |r| words(r) end), now)
end

def replies(list: List[String]) -> Bytes
  return list.join("").bytes
end

# SET EX, PX, EXAT and PXAT, and what TTL, PTTL and EXPIRETIME say. The key
# lives up to and including its deadline and is gone one ms after it. The
# seconds of TTL round to the nearest.
def test_set_time_options_and_ttl() -> Result[Void]
  first = at(
    fresh(),
    1000,
    [
      ["SET", "a", "1", "EX", "10"],
      ["SET", "b", "1", "px", "1500"],
      ["SET", "c", "1", "EXAT", "20"],
      ["SET", "d", "1", "PXAT", "5000"],
      ["SET", "e", "1"],
      ["TTL", "a"],
      ["PTTL", "a"],
      ["TTL", "b"],
      ["PTTL", "c"],
      ["PTTL", "d"],
      ["EXPIRETIME", "a"],
      ["PEXPIRETIME", "a"],
      ["TTL", "e"],
      ["PTTL", "nope"],
      ["EXISTS", "a", "b", "e", "nope", "e"],
    ],
  )

  want = ["+OK\r\n", "+OK\r\n", "+OK\r\n", "+OK\r\n", "+OK\r\n", ":10\r\n", ":10000\r\n", ":2\r\n"]
  want = want.concat([":19000\r\n", ":4000\r\n", ":11\r\n", ":11000\r\n", ":-1\r\n", ":-2\r\n", ":4\r\n"])
  try Test.eq(first.reply.to_a, replies(want).to_a)

  edge = at(first.databases, 2500, [["GET", "b"], ["TTL", "b"]])
  try Test.eq(edge.reply.to_a, "$1\r\n1\r\n:0\r\n".bytes.to_a)
  gone = at(first.databases, 2501, [["GET", "b"], ["EXISTS", "b"], ["TTL", "b"], ["TYPE", "b"], ["TYPE", "a"]])
  return Test.eq(gone.reply.to_a, "$-1\r\n:0\r\n:-2\r\n+none\r\n+string\r\n".bytes.to_a)
end

# The texts and the rules of the time words: a positive integer that does not
# overflow, one word of each kind, and a time in the past is stored and reads as
# missing (an EXAT of the clock second itself is still alive).
def test_set_time_option_errors() -> Result[Void]
  invalid = "-ERR invalid expire time in 'set' command\r\n"
  got = at(
    fresh(),
    1000,
    [
      ["SET", "k", "v", "EX", "0"],
      ["SET", "k", "v", "EX", "-5"],
      ["SET", "k", "v", "EX", "x"],
      ["SET", "k", "v", "EX", HIGH],
      ["SET", "k", "v", "PX", HIGH],
      ["SET", "k", "v", "PXAT", HIGH],
      ["SET", "k", "v", "EX"],
      ["SET", "k", "v", "EX", "1", "PX", "1"],
      ["SET", "k", "v", "KEEPTTL", "EX", "1"],
      ["SET", "k", "v", "EX", "1", "KEEPTTL"],
      ["SET", "k", "v", "PERSIST"],
      ["SET", "k", "v", "EX", "1", "EX", "5"],
      ["PTTL", "k"],
      ["SET", "p", "v", "PXAT", "999"],
      ["GET", "p"],
    ],
  )

  syntax = "-ERR syntax error\r\n"
  want = [invalid, invalid, NOT_INT, invalid, invalid, "+OK\r\n", syntax, syntax, syntax, syntax, syntax]
  want = want.concat(["+OK\r\n", ":5000\r\n", "+OK\r\n", "$-1\r\n"])
  return Test.eq(got.reply.to_a, replies(want).to_a)
end

# What keeps the deadline of a key (INCR, INCRBYFLOAT, APPEND, SETRANGE, SET
# KEEPTTL) and what drops it (SET, GETSET, MSET, SETEX without it, SETNX is
# not reached on a live key), and an expired key that is written is a new key.
def test_writes_keep_or_drop_the_deadline() -> Result[Void]
  kept = at(
    fresh(),
    0,
    [
      ["SET", "k", "1", "EX", "100"],
      ["INCR", "k"],
      ["PTTL", "k"],
      ["INCRBYFLOAT", "k", "1.5"],
      ["PTTL", "k"],
      ["APPEND", "k", "0"],
      ["PTTL", "k"],
      ["SETRANGE", "k", "0", "7"],
      ["PTTL", "k"],
      ["DECR", "n"],
      ["SET", "k", "2", "KEEPTTL"],
      ["PTTL", "k"],
    ],
  )

  want = ["+OK\r\n", ":2\r\n", ":100000\r\n", "$3\r\n3.5\r\n", ":100000\r\n", ":4\r\n", ":100000\r\n"]
  want = want.concat([":4\r\n", ":100000\r\n", ":-1\r\n", "+OK\r\n", ":100000\r\n"])
  try Test.eq(kept.reply.to_a, replies(want).to_a)

  dropped = at(
    kept.databases,
    0,
    [
      ["GETSET", "k", "3"],
      ["TTL", "k"],
      ["SET", "k", "3", "EX", "9"],
      ["MSET", "k", "4"],
      ["TTL", "k"],
      ["SET", "k", "3", "EX", "9"],
      ["SET", "k", "5"],
      ["TTL", "k"],
    ],
  )

  try Test.eq(dropped.reply.to_a, "$1\r\n2\r\n:-1\r\n+OK\r\n+OK\r\n:-1\r\n+OK\r\n+OK\r\n:-1\r\n".bytes.to_a)

  stale = at(fresh(), 0, [["SET", "k", "5", "PX", "10"], ["SET", "s", "ab", "PX", "10"]])
  later = at(stale.databases, 11, [["INCR", "k"], ["TTL", "k"], ["APPEND", "s", "c"], ["TTL", "s"], ["GET", "s"]])
  return Test.eq(later.reply.to_a, ":1\r\n:-1\r\n:1\r\n:-1\r\n$1\r\nc\r\n".bytes.to_a)
end

# GETEX answers nil for a missing key before it reads the time; with a time
# word it sets, moves or removes the deadline, and an absolute time that has
# passed deletes the key after the value was read. SETEX and PSETEX are SET with
# EX and PX and name themselves in the error.
def test_getex_setex_psetex() -> Result[Void]
  got = at(
    fresh(),
    1000,
    [
      ["GETEX", "none", "EX", "0"],
      ["SET", "k", "v"],
      ["GETEX", "k"],
      ["GETEX", "k", "EX", "10"],
      ["TTL", "k"],
      ["GETEX", "k", "PERSIST"],
      ["TTL", "k"],
      ["GETEX", "k", "EX", "0"],
      ["GETEX", "k", "PERSIST", "EX", "1"],
      ["GETEX", "k", "NX"],
      ["GETEX", "k", "PXAT", "1000"],
      ["GET", "k"],
      ["SETEX", "s", "10", "x"],
      ["TTL", "s"],
      ["SETEX", "s", "0", "x"],
      ["PSETEX", "s", "1500", "y"],
      ["PTTL", "s"],
      ["PSETEX", "s", "z", "y"],
    ],
  )

  want = ["$-1\r\n", "+OK\r\n", "$1\r\nv\r\n", "$1\r\nv\r\n", ":10\r\n", "$1\r\nv\r\n", ":-1\r\n"]
  want = want.concat([
    "-ERR invalid expire time in 'getex' command\r\n", "-ERR syntax error\r\n", "-ERR syntax error\r\n",
  ])

  want = want.concat([
    "$1\r\nv\r\n", "$-1\r\n", "+OK\r\n", ":10\r\n", "-ERR invalid expire time in 'setex' command\r\n",
  ])

  want = want.concat(["+OK\r\n", ":1500\r\n", NOT_INT])
  return Test.eq(got.reply.to_a, replies(want).to_a)
end

# EXPIRE, PEXPIRE, EXPIREAT and PEXPIREAT with NX, XX, GT and LT: a key with no
# deadline is an infinite one for GT and LT. A time that is not in the future
# deletes the key and answers 1. The options are read before the key.
def test_expire_family() -> Result[Void]
  got = at(
    fresh(),
    1000,
    [
      ["SET", "k", "v"],
      ["EXPIRE", "k", "10", "XX"],
      ["EXPIRE", "k", "10", "GT"],
      ["EXPIRE", "k", "10", "LT"],
      ["PTTL", "k"],
      ["EXPIRE", "k", "10", "NX"],
      ["EXPIRE", "k", "20", "gt"],
      ["EXPIRE", "k", "5", "GT"],
      ["EXPIRE", "k", "20", "GT"],
      ["EXPIRE", "k", "30", "LT"],
      ["PEXPIRE", "k", "5000", "LT"],
      ["PEXPIRE", "k", "5000", "LT"],
      ["PEXPIRE", "k", "6000", "XX"],
      ["PTTL", "k"],
      ["PEXPIREAT", "k", "9000"],
      ["EXPIREAT", "k", "9"],
      ["PEXPIRETIME", "k"],
      ["PERSIST", "k"],
      ["PERSIST", "k"],
      ["PERSIST", "none"],
      ["EXPIRE", "none", "1"],
      ["EXPIRE", "k", "-1"],
      ["GET", "k"],
    ],
  )

  want = [
    "+OK\r\n", ":0\r\n", ":0\r\n", ":1\r\n", ":10000\r\n", ":0\r\n", ":1\r\n", ":0\r\n", ":0\r\n", ":0\r\n", ":1\r\n",
  ]

  want = want.concat([
    ":0\r\n", ":1\r\n", ":6000\r\n", ":1\r\n", ":1\r\n", ":9000\r\n", ":1\r\n", ":0\r\n", ":0\r\n", ":0\r\n",
  ])

  want = want.concat([":1\r\n", "$-1\r\n"])
  return Test.eq(got.reply.to_a, replies(want).to_a)
end

# The error texts of the EXPIRE family and what they are tested before: the
# options come first, then the time, then whether the key exists. A time in the
# past needs no overflow of the arithmetic.
def test_expire_errors_and_past_times() -> Result[Void]
  bad = "-ERR invalid expire time in '"
  got = at(
    fresh(),
    1000,
    [
      ["EXPIRE", "none", "10", "FOO"],
      ["EXPIRE", "none", "10", "NX", "XX"],
      ["EXPIRE", "none", "10", "GT", "LT"],
      ["EXPIRE", "none", "10", "NX", "LT"],
      ["EXPIRE", "none", "x"],
      ["SET", "k", "v"],
      ["EXPIRE", "k", HIGH],
      ["EXPIREAT", "k", HIGH],
      ["PEXPIRE", "k", HIGH],
      ["PEXPIREAT", "k", HIGH],
      ["PTTL", "k"],
      ["EXPIREAT", "k", "1"],
      ["EXISTS", "k"],
      ["DBSIZE"],
    ],
  )

  conflict = "-ERR NX and XX, GT or LT options at the same time are not compatible\r\n"
  want = [
    "-ERR Unsupported option FOO\r\n", conflict, "-ERR GT and LT options at the same time are not compatible\r\n",
  ]

  want = want.concat([conflict, NOT_INT, "+OK\r\n", "#{bad}expire' command\r\n", "#{bad}expireat' command\r\n"])
  want = want.concat(["#{bad}pexpire' command\r\n", ":1\r\n", ":9223372036854774807\r\n"])
  want = want.concat([":1\r\n", ":0\r\n", ":0\r\n"])
  return Test.eq(got.reply.to_a, replies(want).to_a)
end

# INFO counts the keys with a deadline, swept or not.
def test_info_counts_deadlines() -> Result[Void]
  got = at(fresh(), 0, [["SET", "a", "1", "PX", "5"], ["SET", "b", "1"], ["INFO", "keyspace"]])
  later = at(got.databases, 9, [["INFO", "keyspace"]])
  info = "# Keyspace\r\ndb0:keys=2,expires=1,avg_ttl=0\r\n"
  shown = "$#{info.size}\r\n#{info}\r\n"
  try Test.eq(got.reply.to_a, "+OK\r\n+OK\r\n#{shown}".bytes.to_a)
  return Test.eq(later.reply.to_a, shown.bytes.to_a)
end

def bulk(data: List[Int]) -> Bytes
  return Bytes.concat(["$#{data.size}\r\n".bytes, to_bytes(data), "\r\n".bytes])
end

def present(entry: Optional[Entry]) -> Int
  if entry.some?
    return 1
  end

  return 0
end

def whole(n: Int) -> Bytes
  return ":#{n}\r\n".bytes
end

# The entry of a key that is not expired at `now`.
def live(model: Map[Int, Entry], key: Int, now: Int) -> Optional[Entry]
  case model.get(key)
    none -> return none
    some(entry) ->
      case entry.due
        none -> return some(entry)
        some(due) ->
          if now > due
            return none
          end

          return some(entry)
      end
  end
end

# The fifteen operations as the requests they make (the tenth, a sweep, makes
# none): the clock moves by the second number first, and the key is one of three.
# PEXPIRE takes -2 to 8 ms, so a time that is now or past deletes the key.
def argv_of(op: List[Int]) -> List[Bytes]
  xs = op.concat([0, 0, 0, 0])
  key = "k#{xs[1] % 3}".bytes
  ms = "#{xs[2] % 9 + 1}".bytes
  moved = "#{xs[2] % 11 - 2}".bytes
  value = to_bytes(op.drop(4))
  return case xs[0] % 15
    0 -> ["SET".bytes, key, value]
    1 -> ["SET".bytes, key, value, "PX".bytes, ms]
    2 -> ["PEXPIRE".bytes, key, moved]
    3 -> ["PERSIST".bytes, key]
    4 -> ["GET".bytes, key]
    5 -> ["PTTL".bytes, key]
    6 -> ["EXISTS".bytes, key]
    7 -> ["APPEND".bytes, key, value]
    10 -> ["PEXPIRE".bytes, key, moved, option_of(xs[3])]
    11 -> ["DBSIZE".bytes]
    12 -> ["INFO".bytes, "keyspace".bytes]
    13 -> ["RENAME".bytes, key, "k#{xs[3] % 3}".bytes]
    14 -> ["FLUSHDB".bytes]
    _ -> ["DEL".bytes, key]
  end
end

def option_of(n: Int) -> Bytes
  return ["NX".bytes, "XX".bytes, "GT".bytes, "LT".bytes][n % 4]
end

# Whether NX, XX, GT or LT lets a key with the deadline `current` take `when`;
# a key with none counts as an infinite one.
def allowed?(option: Int, current: Optional[Int], when: Int) -> Bool
  case current
    none -> return option % 4 == 0 or option % 4 == 3
    some(due) -> return case option % 4
        0 -> false
        1 -> true
        2 -> when > due
        _ -> when < due
      end
  end
end

def keyspace_text(state: Map[Int, Entry]) -> Bytes
  if state.empty?
    return bulk_text("# Keyspace\r\n")
  end

  expiring = state.values.select do |entry| entry.due.some? end
  return bulk_text("# Keyspace\r\ndb0:keys=#{state.size},expires=#{expiring.size},avg_ttl=0\r\n")
end

def bulk_text(text: String) -> Bytes
  return "$#{text.size}\r\n#{text}\r\n".bytes
end

def model_step(model: Model, op: List[Int], now: Int) -> Model
  xs = op.concat([0, 0, 0, 0])
  key = xs[1] % 3
  ms = xs[2] % 9 + 1
  moved = xs[2] % 11 - 2
  value = op.drop(4)
  old = live(model.state, key, now)
  held = old.unwrap_or(Entry(value: [], due: none))
  state = model.state
  answer = "+OK\r\n".bytes
  case xs[0] % 15
    0 -> state = state.put(key, Entry(value: value, due: none))
    1 -> state = state.put(key, Entry(value: value, due: some(now + ms)))
    2 ->
      answer = whole(0)
      if old.some?
        answer = whole(1)
        if now + moved <= now
          state = state.delete(key)
        else
          state = state.put(key, held.with(due: some(now + moved)))
        end
      end

    3 ->
      answer = whole(0)
      if old.some? and held.due.some?
        state = state.put(key, held.with(due: none))
        answer = whole(1)
      end

    4 ->
      answer = "$-1\r\n".bytes
      if old.some?
        answer = bulk(held.value)
      end

    5 ->
      answer = whole(-2)
      if old.some?
        answer = whole(-1)
        case held.due
          some(due) -> answer = whole(due - now)
          none -> nil
        end
      end

    6 -> answer = whole(present(old))
    7 ->
      state = state.put(key, held.with(value: held.value.concat(value)))
      answer = whole(held.value.size + value.size)
    9 ->
      state = swept(state, now)
      return Model(state: state, replies: model.replies)
    10 ->
      answer = whole(0)
      if old.some? and allowed?(xs[3], held.due, now + moved)
        answer = whole(1)
        if now + moved <= now
          state = state.delete(key)
        else
          state = state.put(key, held.with(due: some(now + moved)))
        end
      end

    11 -> answer = whole(state.size)
    12 -> answer = keyspace_text(state)
    13 ->
      target = xs[3] % 3
      answer = "-ERR no such key\r\n".bytes
      if old.some? and target != key
        state = state.put(target, held).delete(key)
        answer = "+OK\r\n".bytes
      elsif old.some?
        answer = "+OK\r\n".bytes
      end

    14 -> state = {}
    _ ->
      state = state.delete(key)
      answer = whole(present(old))
  end

  return Model(state: state, replies: model.replies.push(answer))
end

# What a sweep at `now` leaves: the keys that are not past their deadline.
def swept(state: Map[Int, Entry], now: Int) -> Map[Int, Entry]
  left = state
  for key in state.keys
    due = state.get(key).unwrap_or(Entry(value: [], due: none)).due
    if due.some? and now > due.unwrap_or(0)
      left = left.delete(key)
    end
  end

  return left
end

# The clock of each operation: it moves by 0 to 4 ms, so keys with a deadline
# of 1 to 9 ms are met before, at and after it.
def clocks(ops: List[List[Int]]) -> List[Int]
  now = 0
  times: List[Int] = []
  for op in ops
    now += op.concat([0, 0])[1] % 5
    times = times.push(now)
  end

  return times
end

# The server run with the sweep operations in place: an answer depends on one
# only through DBSIZE and INFO, which count the keys not swept yet.
def run_with_sweeps(table: Map[String, Command], ops: List[List[Int]], times: List[Int]) -> Bytes
  started = Requests.start(fresh())
  store = Requests.join(started, 1)
  replies: List[Bytes] = []
  for i in 0...ops.size
    if ops[i].concat([0])[0] % 15 == 9
      store = Requests.expire_keys(store, times[i])
    else
      done = Requests.run(table, store, 1, argv_of(ops[i]), times[i])
      store = done.store
      replies = replies.push(done.reply)
    end
  end

  return Bytes.concat(replies)
end

# SET, SET PX, PEXPIRE (also with NX, XX, GT, LT and a time that is now or
# past), PERSIST, GET, PTTL, EXISTS, APPEND, DEL, RENAME among the keys, FLUSHDB,
# DBSIZE and INFO keyspace against
# a Map of values and deadlines, with a clock that moves and a sweep that the
# model repeats: the counts of DBSIZE and `expires` show an index that drifted,
# and a key that a stale index entry dropped shows in a GET. 300 runs: the step
# limit is between 800 and 1000 runs.
def test_deadlines_follow_a_model() -> Result[Void]
  table = Table.build()
  numbers = Prop.int(0, 255)
  ops = Prop.list(Prop.list(numbers, 8), 16)
  return Prop.check(ops, Prop.Config(runs: 300)) do |list|
    times = clocks(list)
    start = Model(state: {}, replies: [])
    model = (0...list.size).to_a.reduce(start) do |acc, i| model_step(acc, list[i], times[i]) end
    Prop.eq(run_with_sweeps(table, list, times).to_a, Bytes.concat(model.replies).to_a)
  end
end

# A deadline near the largest Int is accepted (as in Redis) and must read back
# without an overflow, in seconds too: the rounding adds nothing to it.
def test_a_deadline_near_the_largest_int_reads_back() -> Result[Void]
  got = at(
    fresh(),
    1000,
    [
      ["SET", "a", "1", "PXAT", "9223372036854775500"],
      ["EXPIRETIME", "a"],
      ["PEXPIRETIME", "a"],
      ["TTL", "a"],
      ["PTTL", "a"],
      ["SET", "b", "1", "PXAT", "9223372036854775807"],
      ["EXPIRETIME", "b"],
      ["SET", "c", "1", "EXAT", "9223372036854775"],
      ["EXPIRETIME", "c"],
    ],
  )

  want = ["+OK\r\n", ":9223372036854776\r\n", ":9223372036854775500\r\n", ":9223372036854775\r\n"]
  want = want.concat([
    ":9223372036854774500\r\n", "+OK\r\n", ":9223372036854776\r\n", "+OK\r\n", ":9223372036854775\r\n",
  ])

  return Test.eq(got.reply.to_a, replies(want).to_a)
end
