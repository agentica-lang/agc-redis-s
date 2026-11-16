## The RESP2 writer: a `Reply` to the bytes that go on the socket.

import {Reply} from "reply"

## The last bytes before a connection closes on a protocol error.
def protocol_error(text: String) -> Bytes = "-ERR #{text}\r\n".bytes

## A reply of one or two parts is joined at once; a build pays off only for
## arrays.
def encode(reply: Reply) -> Bytes
  return case reply
    Reply.Simple(text) -> Bytes.concat(["+".bytes, single_line(text.bytes), CRLF])
    Reply.Error(text) -> Bytes.concat(["-".bytes, single_line(text), CRLF])
    Reply.Integer(n) -> ":#{n}\r\n".bytes
    Reply.Bulk(data) -> Bytes.concat([bulk_header(data.size), data, CRLF])
    Reply.NilBulk -> "$-1\r\n".bytes
    Reply.Array(_) -> Bytes.build do |out| write(out, reply) end
    Reply.NilArray -> "*-1\r\n".bytes
    Reply.Raw(bytes) -> bytes
  end
end

## The replies one after another, in one `Bytes`.
def encode_all(replies: List[Reply]) -> Bytes
  Bytes.build do |out|
    for reply in replies
      write(out, reply)
    end
  end
end

## Writes `reply` to `out`: the parts of every reply of a build go into one buffer, with no copy in between.
def write(out: Bytes.Builder, reply: Reply) -> Void
  case reply
    Reply.Simple(text) -> out.write("+", single_line(text.bytes), "\r\n")
    Reply.Error(text) -> out.write("-", single_line(text), "\r\n")
    Reply.Integer(n) -> out.write(":", n, "\r\n")
    Reply.Bulk(data) -> write_bulk(out, data)
    Reply.NilBulk -> out.write("$-1\r\n")
    Reply.Array(items) ->
      out.write("*", items.size, "\r\n")
      for item in items
        write(out, item)
      end

    Reply.NilArray -> out.write("*-1\r\n")
    Reply.Raw(bytes) -> out.write(bytes)
  end
end

## A bulk string: `$N\r\n`, the data, `\r\n`.
def write_bulk(out: Bytes.Builder, data: Bytes) -> Void
  out.write("$", data.size, "\r\n", data, "\r\n")
end

private

CR = 13

LF = 10

SPACE = 32

CRLF = "\r\n".bytes

HEADER_COUNT = 1024

HEADERS = (0...HEADER_COUNT).to_a.map do |size| "$#{size}\r\n".bytes end

# The `$N\r\n` line before a bulk string of N bytes; the common small sizes
# are built once (Redis's `shared.bulkhdr`).
def bulk_header(size: Int) -> Bytes
  return HEADERS[size] if size < HEADER_COUNT

  "$#{size}\r\n".bytes
end

# A CR or LF inside a status line ends it early, so a client that sends one in
# an argument could forge replies. Redis turns them into spaces too.
def single_line(text: Bytes) -> Bytes
  return text if not breaks?(text)

  Bytes.from_list(text.to_a.map do |byte| spaced(byte) end).unwrap!
end

def breaks?(text: Bytes) -> Bool
  for byte in text
    return true if byte == CR or byte == LF
  end

  false
end

def spaced(byte: Int) -> Int
  return SPACE if byte == CR or byte == LF

  byte
end
