## The RESP2 writer: a `Reply` to the bytes that go on the socket.

import {Reply} from "reply"

CR = 13
LF = 10
SPACE = 32

export def encode(reply: Reply) -> Bytes
  return case reply
    Reply.Simple(text) -> line("+".bytes, text.bytes)
    Reply.Error(text) -> line("-".bytes, text)
    Reply.Integer(n) -> ":#{n}\r\n".bytes
    Reply.Bulk(data) -> Bytes.concat(["$#{data.size}\r\n".bytes, data, "\r\n".bytes])
    Reply.NilBulk -> "$-1\r\n".bytes
    Reply.Array(items) -> Bytes.concat(["*#{items.size}\r\n".bytes].concat(items.map do |item| encode(item) end))
    Reply.NilArray -> "*-1\r\n".bytes
  end
end

# A CR or LF inside a status line ends it early, so a client that sends one in
# an argument could forge replies. Redis turns them into spaces too.
def line(prefix: Bytes, text: Bytes) -> Bytes
  clean = Bytes.from_list(text.to_a.map do |byte| single_line(byte) end).unwrap!
  return Bytes.concat([prefix, clean, "\r\n".bytes])
end

def single_line(byte: Int) -> Int
  if byte == CR or byte == LF
    return SPACE
  end

  return byte
end
