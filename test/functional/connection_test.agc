import {Keyspace} from "../../src/store/keyspace"
import {exchange, request} from "../support"

def words(list: List[String]) -> Bytes
  return request(list.map do |w| w.bytes end)
end

# Pipelined requests in one buffer: an array, an inline line, a lowercase name,
# a binary-safe ECHO, then QUIT; what follows QUIT is never run.
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
  result = exchange(Keyspace(), sent)
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
  return Test.eq(exchange(Keyspace(), sent).reply, expected)
end

def test_protocol_error_closes() -> Result[Void]
  result = exchange(Keyspace(), "*x\r\n".bytes)
  try Test.eq(result.reply, "-ERR Protocol error: invalid multibulk length\r\n".bytes)
  return Test.assert(result.closed, "a protocol error closes the connection")
end
