## The hash commands and the type checks between hashes and strings.

import {fresh} from "../../src/store/databases"
import {exchange, talk, words} from "../support"

WRONGTYPE = "-WRONGTYPE Operation against a key holding the wrong kind of value\r\n"

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
