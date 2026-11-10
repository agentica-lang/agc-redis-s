## The bytes of one connection to requests. The chunks of a receive are kept
## apart until the request that waits for them can be complete, so a large
## request costs one join and one parse, not one of each per chunk.

import {Partial, Read} from "reader"
import Reader from "reader"

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
export def start() -> Stream
  return Stream(chunks: [], have: 0, partial: Partial())
end

## Adds a chunk and cuts every whole request out of what is held.
export def feed(stream: Stream, chunk: Bytes) -> Fed
  chunks = stream.chunks.push(chunk)
  have = stream.have + chunk.size
  if have < stream.partial.need
    return Fed(stream: Stream(chunks: chunks, have: have, partial: stream.partial), requests: [], ending: Ending.Open)
  end

  return cut(Bytes.concat(chunks), stream.partial)
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

  return Fed(stream: start(), requests: requests, ending: Ending.Open)
end

# Only what the reader has not consumed stays; the offsets restart at 0.
def keep(buf: Bytes, partial: Partial) -> Stream
  rest = buf
  if partial.at > 0
    rest = buf.drop(partial.at)
  end

  if rest.empty?
    return Stream(chunks: [], have: 0, partial: partial.with(at: 0))
  end

  return Stream(chunks: [rest], have: rest.size, partial: partial.with(at: 0))
end
