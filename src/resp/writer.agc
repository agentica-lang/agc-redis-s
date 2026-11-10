## The RESP2 writer: a `Reply` to the bytes that go on the socket.

import {Reply} from "reply"

export def encode(reply: Reply) -> Bytes
  return case reply
    Reply.Simple(text) -> "+#{text}\r\n".bytes
    Reply.Error(text) -> "-#{text}\r\n".bytes
    Reply.Integer(n) -> ":#{n}\r\n".bytes
    Reply.Bulk(data) -> Bytes.concat(["$#{data.size}\r\n".bytes, data, "\r\n".bytes])
    Reply.NilBulk -> "$-1\r\n".bytes
    Reply.Array(items) -> Bytes.concat(["*#{items.size}\r\n".bytes].concat(items.map do |item| encode(item) end))
    Reply.NilArray -> "*-1\r\n".bytes
  end
end
