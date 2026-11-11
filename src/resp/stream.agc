## The bytes of one connection to requests. The chunks of a receive are kept
## apart until the request that waits for them can be complete, so a large
## request costs one join and one parse, not one of each per chunk.

import {Partial, Read} from "reader"
import Reader from "reader"

LF = 10

export struct Stream
  chunks: List[Bytes]
  have: Int
  partial: Partial
end

export enum Ending
  ## The connection goes on.
  Open
  ## A protocol error; the text is the reply, then the connection closes.
  Invalid(String)
  ## The request is too big; the connection closes without a reply.
  Overflow
end

## What one chunk gave: the requests it completed, in order, and what is next.
export struct Fed
  stream: Stream
  requests: List[List[Bytes]]
  ending: Ending
end

## A stream with nothing held.
export def start() -> Stream = Stream(chunks: [], have: 0, partial: Partial())

## Adds a chunk and cuts every whole request out of what is held.
export def feed(stream: Stream, chunk: Bytes) -> Fed
  chunks = stream.chunks.push(chunk)
  have = stream.have + chunk.size
  if waiting?(stream.partial, have, chunk)
    return Fed(stream: Stream(chunks: chunks, have: have, partial: stream.partial), requests: [], ending: Ending.Open)
  end

  cut(Bytes.concat(chunks), stream.partial)
end

# Nothing can change yet: the request needs more bytes, or only a LF is missing
# and this chunk has none (a line is refused at MAX_LINE, which needs a parse).
def waiting?(partial: Partial, have: Int, chunk: Bytes) -> Bool
  return true if have < partial.need

  partial.line and have <= Reader.MAX_LINE and not has_lf?(chunk)
end

def has_lf?(chunk: Bytes) -> Bool
  for byte in chunk
    return true if byte == LF
  end

  false
end

def cut(buf: Bytes, resume: Partial) -> Fed
  requests: List[List[Bytes]] = []
  state = resume
  while true
    case Reader.read_request(buf, state)
      Read.Request(argv, next) ->
        requests = requests.push(argv)
        state = Partial(at: next)
      Read.Skip(next) -> state = Partial(at: next)
      Read.Incomplete(partial) -> return Fed(stream: keep(buf, partial), requests: requests, ending: Ending.Open)
      Read.Invalid(text) -> return Fed(stream: start(), requests: requests, ending: Ending.Invalid(text))
      Read.Overflow -> return Fed(stream: start(), requests: requests, ending: Ending.Overflow)
    end
  end

  Fed(stream: start(), requests: requests, ending: Ending.Open)
end

# Only what the reader has not consumed stays; the offsets restart at 0.
def keep(buf: Bytes, partial: Partial) -> Stream
  rest = buf
  if partial.at > 0
    rest = buf.drop(partial.at)
  end

  return Stream(chunks: [], have: 0, partial: partial.with(at: 0)) if rest.empty?

  Stream(chunks: [rest], have: rest.size, partial: partial.with(at: 0))
end
