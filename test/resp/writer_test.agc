import {Reply} from "../../src/resp/reply"
import Writer from "../../src/resp/writer"

def test_scalars() -> Result[Void]
  try Test.eq(Writer.encode(Reply.Simple("OK")), "+OK\r\n".bytes)
  try Test.eq(Writer.encode(Reply.Error("ERR boom".bytes)), "-ERR boom\r\n".bytes)
  return Test.eq(Writer.encode(Reply.Integer(-7)), ":-7\r\n".bytes)
end

def test_bulk_is_binary_safe() -> Result[Void]
  data = Bytes.from_list([0, 13, 10, 255]).unwrap!
  try Test.eq(Writer.encode(Reply.Bulk(data)), "$4\r\n".bytes + data + "\r\n".bytes)
  return Test.eq(Writer.encode(Reply.Bulk("".bytes)), "$0\r\n\r\n".bytes)
end

def test_nils() -> Result[Void]
  try Test.eq(Writer.encode(Reply.NilBulk), "$-1\r\n".bytes)
  return Test.eq(Writer.encode(Reply.NilArray), "*-1\r\n".bytes)
end

def test_nested_array() -> Result[Void]
  reply = Reply.Array([Reply.Integer(1), Reply.Array([Reply.Bulk("a".bytes)])])
  return Test.eq(Writer.encode(reply), "*2\r\n:1\r\n*1\r\n$1\r\na\r\n".bytes)
end

def test_status_lines_cannot_carry_a_line_break() -> Result[Void]
  try Test.eq(Writer.encode(Reply.Error("ERR a\r\n+PONG".bytes)), "-ERR a  +PONG\r\n".bytes)
  return Test.eq(Writer.encode(Reply.Simple("a\nb")), "+a b\r\n".bytes)
end
