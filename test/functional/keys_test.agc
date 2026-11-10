## DEL, UNLINK, EXISTS, TOUCH, TYPE and KEYS, with the keys that expired.

import {fresh} from "../../src/store/databases"
import {Exchange, exchange, talk, words} from "../support"

def bulk(text: String) -> String
  return "$#{text.bytesize}\r\n#{text}\r\n"
end

# SET b has a deadline at 10; the first batch runs at the clock 0 and the second
# at 11, when b is expired but still held.
def test_del_exists_type_and_touch() -> Result[Void]
  first = talk([["SET", "a", "1"], ["SET", "b", "2", "PX", "10"], ["SET", "c", "3"], ["SET", "", "4"]])
  later = exchange(
    first.databases,
    Bytes.concat([
      words(["EXISTS", "a", "b", "c", "a", "none"]),
      words(["TOUCH", "a", "b", "none"]),
      words(["TYPE", "a"]),
      words(["TYPE", "b"]),
      words(["DBSIZE"]),
      words(["DEL", "b", "none"]),
      words(["DEL", "a", "c", "a", ""]),
      words(["DBSIZE"]),
      words(["EXISTS", "a"]),
      words(["DEL"]),
    ]),
    11,
  )

  want = ":3\r\n:1\r\n+string\r\n+none\r\n:4\r\n:0\r\n:3\r\n:0\r\n:0\r\n"
  try Test.eq(later.reply.to_a, "#{want}-ERR wrong number of arguments for 'del' command\r\n".bytes.to_a)
  return Test.eq(exchange(first.databases, words(["UNLINK", "a", "c"])).reply.to_a, ":2\r\n".bytes.to_a)
end

# KEYS: `*` alone takes every live key, also one with an empty name; any other
# pattern goes through the glob, where an empty name matches only the empty
# pattern; an expired key is never listed.
def test_keys_patterns() -> Result[Void]
  first = talk([["SET", "hello", "1"], ["SET", "hallo", "1"], ["SET", "hxllo", "1", "PX", "5"], ["SET", "", "1"]])

  later = exchange(
    first.databases,
    Bytes.concat([
      words(["KEYS", "*"]),
      words(["KEYS", "h?llo"]),
      words(["KEYS", "h[ae]llo"]),
      words(["KEYS", "**"]),
      words(["KEYS", "?"]),
      words(["KEYS", ""]),
      words(["KEYS", "nope*"]),
    ]),
    6,
  )

  list = "*3\r\n$5\r\nhello\r\n$5\r\nhallo\r\n$0\r\n\r\n"
  pair = "*2\r\n$5\r\nhello\r\n$5\r\nhallo\r\n"
  want = [list, pair, pair, "*2\r\n$5\r\nhello\r\n$5\r\nhallo\r\n", "*0\r\n", "*1\r\n$0\r\n\r\n", "*0\r\n"]
  return Test.eq(later.reply.to_a, want.join("").bytes.to_a)
end

# RENAME and RENAMENX: the value moves with its deadline, what was at the new
# name goes with its own deadline, the same name is a no-op for a key that
# exists, and a missing source is an error. An expired name counts as free.
def test_rename_and_renamenx() -> Result[Void]
  first = talk([
    ["SET", "a", "1", "PX", "10"],
    ["SET", "b", "2"],
    ["SET", "c", "3", "PX", "100"],
    ["SET", "d", "4"],
    ["SET", "e", "5"],
  ])

  sent = [
    ["RENAME", "a", "b"],
    ["GET", "a"],
    ["GET", "b"],
    ["PTTL", "b"],
    ["RENAME", "d", "c"],
    ["PTTL", "c"],
    ["RENAME", "none", "x"],
    ["RENAME", "none", "none"],
    ["RENAME", "e", "e"],
    ["RENAMENX", "e", "e"],
    ["RENAMENX", "none", "e"],
    ["RENAMENX", "e", "c"],
    ["RENAMENX", "e", "f"],
    ["DBSIZE"],
  ]

  got = exchange(first.databases, Bytes.concat(sent.map do |r| words(r) end), 0)
  missing = "-ERR no such key\r\n"
  want = [
    "+OK\r\n",
    "$-1\r\n",
    bulk("1"),
    ":10\r\n",
    "+OK\r\n",
    ":-1\r\n",
    missing,
    missing,
    "+OK\r\n",
    ":0\r\n",
    missing,
  ]

  want = want.concat([":0\r\n", ":1\r\n", ":3\r\n"])
  try Test.eq(got.reply.to_a, want.join("").bytes.to_a)

  later = exchange(got.databases, Bytes.concat([words(["RENAME", "b", "g"]), words(["RENAMENX", "f", "b"])]), 11)
  return Test.eq(later.reply.to_a, "#{missing}:1\r\n".bytes.to_a)
end

# RANDOMKEY answers nil with no live key and otherwise a live key, and over many
# calls every live key shows up (a pick that always takes the same one fails).
def test_randomkey_picks_a_live_key() -> Result[Void]
  empty = exchange(fresh(), words(["RANDOMKEY"]), 0)
  try Test.eq(empty.reply.to_a, "$-1\r\n".bytes.to_a)
  first = talk([["SET", "a", "1"], ["SET", "b", "1"], ["SET", "c", "1"], ["SET", "gone", "1", "PX", "5"]])
  got = exchange(first.databases, Bytes.concat((0...60).to_a.map do |_| words(["RANDOMKEY"]) end), 6)
  seen = ["a", "b", "c"].select do |name| got.reply.to_a.include?(name.bytes[0]) end
  try Test.eq(seen, ["a", "b", "c"])
  return Test.assert(not got.reply.to_a.include?("g".bytes[0]), "an expired key is never picked")
end
