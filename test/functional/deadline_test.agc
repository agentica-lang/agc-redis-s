## The deadline of a key: SET's time options, GETEX, SETEX, PSETEX, TTL and its
## kin, and the commands that keep or drop a deadline. The clock is an argument
## of `exchange`, so no test sleeps.

import {Databases, fresh} from "../../src/store/databases"
import {Exchange, exchange, words} from "../support"

HIGH = "9223372036854775807"
NOT_INT = "-ERR value is not an integer or out of range\r\n"

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
    ],
  )

  want = ["+OK\r\n", "+OK\r\n", "+OK\r\n", "+OK\r\n", "+OK\r\n", ":10\r\n", ":10000\r\n", ":2\r\n"]
  want = want.concat([":19000\r\n", ":4000\r\n", ":11\r\n", ":11000\r\n", ":-1\r\n", ":-2\r\n"])
  try Test.eq(first.reply.to_a, replies(want).to_a)

  edge = at(first.databases, 2500, [["GET", "b"], ["TTL", "b"]])
  try Test.eq(edge.reply.to_a, "$1\r\n1\r\n:0\r\n".bytes.to_a)
  gone = at(first.databases, 2501, [["GET", "b"], ["TTL", "b"], ["GET", "a"]])
  return Test.eq(gone.reply.to_a, "$-1\r\n:-2\r\n$1\r\n1\r\n".bytes.to_a)
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

# INFO counts the keys with a deadline, swept or not.
def test_info_counts_deadlines() -> Result[Void]
  got = at(fresh(), 0, [["SET", "a", "1", "PX", "5"], ["SET", "b", "1"], ["INFO", "keyspace"]])
  later = at(got.databases, 9, [["INFO", "keyspace"]])
  info = "# Keyspace\r\ndb0:keys=2,expires=1,avg_ttl=0\r\n"
  shown = "$#{info.size}\r\n#{info}\r\n"
  try Test.eq(got.reply.to_a, "+OK\r\n+OK\r\n#{shown}".bytes.to_a)
  return Test.eq(later.reply.to_a, shown.bytes.to_a)
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
