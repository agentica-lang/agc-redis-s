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
