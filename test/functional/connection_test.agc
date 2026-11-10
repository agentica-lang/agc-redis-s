import {fresh} from "../../src/store/databases"
import {exchange, request, talk, words} from "../support"

# Pipelined requests in one buffer: an array, an inline line, a lowercase name,
# a binary-safe ECHO, an ECHO without argument, then QUIT; what follows QUIT is never run.
def test_pipeline_and_quit() -> Result[Void]
  data = Bytes.from_list([0, 13, 10, 255]).unwrap!
  sent = Bytes.concat([
    words(["PING"]),
    "PING\r\n".bytes,
    words(["ping", "hi"]),
    request(["ECHO".bytes, data]),
    words(["QUIT"]),
    words(["PING"]),
  ])

  expected = Bytes.concat(["+PONG\r\n+PONG\r\n$2\r\nhi\r\n$4\r\n".bytes, data, "\r\n+OK\r\n".bytes])
  result = exchange(fresh(), sent)
  try Test.eq(result.reply, expected)
  return Test.assert(result.closed, "QUIT closes the connection")
end

# Client bytes echoed in an error must not forge a reply (CR LF) or change (0xff).
def test_errors_keep_the_stream_in_step() -> Result[Void]
  raw = Bytes.from_list([97, 13, 10, 43, 79, 75, 255]).unwrap!
  sent = request(["FOO".bytes, raw]) + words(["PING", "a", "b", "c"]) + words(["PING"])
  prefix = "-ERR unknown command 'FOO', with args beginning with: 'a  +OK".bytes
  arity = "' \r\n-ERR wrong number of arguments for 'ping' command\r\n+PONG\r\n".bytes
  expected = prefix + Bytes.from_list([255]).unwrap! + arity
  return Test.eq(exchange(fresh(), sent).reply, expected)
end

def test_protocol_error_closes() -> Result[Void]
  result = exchange(fresh(), "*x\r\n".bytes)
  try Test.eq(result.reply, "-ERR Protocol error: invalid multibulk length\r\n".bytes)
  return Test.assert(result.closed, "a protocol error closes the connection")
end

# The reply path of inline quoting: a quoted command is answered, and bad quotes
# close the connection after the replies before them.
def test_inline_quotes_and_their_errors() -> Result[Void]
  result = exchange(fresh(), "ECHO \"a b\\x41\"\r\nPING \"x\r\nPING\r\n".bytes)
  try Test.eq(result.reply, "$4\r\na bA\r\n-ERR Protocol error: unbalanced quotes in request\r\n".bytes)
  return Test.assert(result.closed, "unbalanced quotes close the connection")
end

def greeting(id: Int) -> String
  head = (
    "*14\r\n$6\r\nserver\r\n$5\r\nredis\r\n$7\r\nversion\r\n$6\r\n7.2.17\r\n$5\r\nproto\r\n:2\r\n$2\r\nid\r\n:#{id}\r\n"
  )

  return head + "$4\r\nmode\r\n$10\r\nstandalone\r\n$4\r\nrole\r\n$6\r\nmaster\r\n$7\r\nmodules\r\n*0\r\n"
end

# HELLO 2 answers the greeting; 3 and the bad forms get Redis's errors; the
# options run in order, so a bad name wins over a bad user.
def test_hello() -> Result[Void]
  good = talk([["HELLO"], ["hello", "2", "AUTH", "default", "any", "SETNAME", "n1"], ["CLIENT", "GETNAME"]])
  try Test.eq(good.reply, (greeting(1) + greeting(1) + "$2\r\nn1\r\n").bytes)

  bad = talk([
    ["HELLO", "3"],
    ["HELLO", "x"],
    ["HELLO", "2", "SETNAME", "a b", "AUTH", "u", "p"],
    ["HELLO", "2", "AUTH", "u", "p"],
    ["HELLO", "2", "AUTH", "u"],
    ["HELLO", "2", "SETNAME"],
  ])

  expected = [
    "-NOPROTO unsupported protocol version\r\n",
    "-ERR Protocol version is not an integer or out of range\r\n",
    "-ERR Client names cannot contain spaces, newlines or special characters.\r\n",
    "-WRONGPASS invalid username-password pair or user is disabled.\r\n",
    "-ERR Syntax error in HELLO option 'AUTH'\r\n",
    "-ERR Syntax error in HELLO option 'SETNAME'\r\n",
  ].join("")

  return Test.eq(bad.reply, expected.bytes)
end

# SELECT moves the session, and its errors are the ones of Redis for a number
# that is not an int, one past the int range and one past the 16 databases.
def test_select() -> Result[Void]
  moved = talk([["SELECT", "15"], ["select", "0"], ["SELECT", "15"]])
  try Test.eq(moved.reply, "+OK\r\n+OK\r\n+OK\r\n".bytes)
  try Test.eq(moved.session.db, 15)

  bad = talk([["SELECT", "16"], ["SELECT", "-1"], ["SELECT", "1x"], ["SELECT", "2147483648"], ["SELECT"]])
  expected = [
    "-ERR DB index is out of range\r\n-ERR DB index is out of range\r\n",
    "-ERR value is not an integer or out of range\r\n",
    "-ERR value is out of range, value must between -2147483648 and 2147483647\r\n",
    "-ERR wrong number of arguments for 'select' command\r\n",
  ].join("")

  try Test.eq(bad.reply, expected.bytes)
  return Test.eq(bad.session.db, 0)
end
