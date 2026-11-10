import {Read} from "../../src/resp/reader"
import Reader from "../../src/resp/reader"

def argv(words: List[String]) -> List[Bytes]
  return words.map do |w| w.bytes end
end

def test_array_request() -> Result[Void]
  buf = "*2\r\n$4\r\nPING\r\n$2\r\nhi\r\n".bytes
  return Test.eq(Reader.read_request(buf, 0), Read.Request(argv(["PING", "hi"]), buf.size))
end

def test_two_requests_walk_by_offset() -> Result[Void]
  one = "*1\r\n$4\r\nPING\r\n".bytes
  buf = one + one
  return Test.eq(Reader.read_request(buf, one.size), Read.Request(argv(["PING"]), buf.size))
end

def test_bulk_is_binary_safe() -> Result[Void]
  data = Bytes.from_list([13, 10, 0]).unwrap!
  buf = "*1\r\n$3\r\n".bytes + data + "\r\n".bytes
  return Test.eq(Reader.read_request(buf, 0), Read.Request([data], buf.size))
end

def test_inline_request() -> Result[Void]
  try Test.eq(Reader.read_request("PING  a\r\n".bytes, 0), Read.Request(argv(["PING", "a"]), 9))
  return Test.eq(Reader.read_request("\r\n".bytes, 0), Read.Skip(2))
end

def test_every_prefix_is_incomplete() -> Result[Void]
  whole = "*2\r\n$4\r\nPING\r\n$2\r\nhi\r\n".bytes
  for n in 0...whole.size
    try Test.eq(Reader.read_request(whole.take(n), 0), Read.Incomplete)
  end

  return ok()
end

def test_protocol_errors() -> Result[Void]
  try Test.eq(Reader.read_request("*x\r\n".bytes, 0), Read.Invalid("Protocol error: invalid multibulk length"))
  try Test.eq(Reader.read_request("*1\r\n$-5\r\n".bytes, 0), Read.Invalid("Protocol error: invalid bulk length"))
  return Test.eq(Reader.read_request("*1\r\nx\r\n".bytes, 0), Read.Invalid("Protocol error: expected '$', got 'x'"))
end
