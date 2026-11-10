import {Read} from "../../src/resp/reader"
import Reader from "../../src/resp/reader"

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

# Lengths are read as Redis's string2ll does: only `-` and digits, no leading zero.
def test_lengths_are_strict() -> Result[Void]
  for text in ["$+3", "$ 3", "$1_0", "$03", "$-0", "$"]
    try Test.eq(
      Reader.read_request("*1\r\n#{text}\r\nabc\r\n".bytes, 0),
      Read.Invalid("Protocol error: invalid bulk length"),
    )
  end

  try Test.eq(Reader.read_request("*1_0\r\n".bytes, 0), Read.Invalid("Protocol error: invalid multibulk length"))
  try Test.eq(Reader.read_request("*1\r\n$0\r\n\r\n".bytes, 0), Read.Request(["".bytes], 10))
  return Test.eq(Reader.read_request("*-1\r\n".bytes, 0), Read.Skip(5))
end

def test_inline_line_is_bytes() -> Result[Void]
  line = Bytes.from_list([102, 111, 111, 9, 255, 32, 32, 98, 13, 10]).unwrap!
  expected = [Bytes.from_list([102, 111, 111]).unwrap!, Bytes.from_list([255]).unwrap!, "b".bytes]
  try Test.eq(Reader.read_request(line, 0), Read.Request(expected, 10))
  return Test.eq(Reader.read_request("  \r\n".bytes, 0), Read.Skip(4))
end
