## The RESP2 writer: a `Reply` to the bytes that go on the socket.

import {Reply} from "reply"

CR = 13
LF = 10
SPACE = 32
CRLF = "\r\n".bytes
HEADER_COUNT = 1024
HEADERS = (0...HEADER_COUNT).to_a.map do |size| "$#{size}\r\n".bytes end

## The last bytes before a connection closes on a protocol error.
export def protocol_error(text: String) -> Bytes
  return "-ERR #{text}\r\n".bytes
end

export def encode(reply: Reply) -> Bytes
  return case reply
    Reply.Simple(text) -> line("+".bytes, text.bytes)
    Reply.Error(text) -> line("-".bytes, text)
    Reply.Integer(n) -> ":#{n}\r\n".bytes
    Reply.Bulk(data) -> Bytes.concat([bulk_header(data.size), data, CRLF])
    Reply.NilBulk -> "$-1\r\n".bytes
    Reply.Array(items) -> Bytes.concat(["*#{items.size}\r\n".bytes].concat(items.map do |item| encode(item) end))
    Reply.NilArray -> "*-1\r\n".bytes
    Reply.Raw(bytes) -> bytes
  end
end

## The `$N\r\n` line before a bulk string of N bytes; the common small sizes
## are built once (Redis's `shared.bulkhdr`).
export def bulk_header(size: Int) -> Bytes
  if size < HEADER_COUNT
    return HEADERS[size]
  end

  return "$#{size}\r\n".bytes
end

## The `*N\r\n` line before an array of N items.
export def array_header(size: Int) -> Bytes
  return "*#{size}\r\n".bytes
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
