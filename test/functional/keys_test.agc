## DEL, UNLINK, EXISTS, TOUCH, TYPE and KEYS, with the keys that expired.

import {Exchange, exchange, talk, words} from "../support"

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

  want = ":3\r\n:1\r\n+string\r\n+none\r\n:4\r\n:0\r\n:3\r\n:1\r\n:0\r\n"
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
