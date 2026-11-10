import Stream from "../../src/resp/stream"
import {Ending} from "../../src/resp/stream"
import {request} from "../support"

def feed_all(bytes: Bytes, size: Int) -> Stream.Fed
  stream = Stream.start()
  requests: List[List[Bytes]] = []
  ending = Ending.Open
  pos = 0
  while pos < bytes.size
    take = size
    if bytes.size - pos < take
      take = bytes.size - pos
    end

    fed = Stream.feed(stream, bytes.slice(pos, take))
    stream = fed.stream
    requests = requests.concat(fed.requests)
    ending = fed.ending
    pos += size
  end

  return Stream.Fed(stream: stream, requests: requests, ending: ending)
end

# A binary payload with CR LF in it, an inline line with quotes, blank lines and
# an empty array between them: cut into any chunk size the requests are the same.
def test_chunks_give_the_same_requests() -> Result[Void]
  data = Bytes.from_list([0, 13, 10, 36, 42, 255]).unwrap!
  sent = Bytes.concat([
    request(["SET".bytes, "k".bytes, data]),
    "\r\n  \r\n*0\r\n".bytes,
    "ECHO \"a b\" 'c'\r\n".bytes,
    request(["PING".bytes]),
    request(["GET".bytes, "x".bytes + data]),
  ])

  whole = feed_all(sent, sent.size)
  try Test.eq(whole.requests.size, 4)
  try Test.eq(whole.requests[1], ["ECHO".bytes, "a b".bytes, "c".bytes])
  for size in [1, 2, 3, 7, 64]
    try Test.eq(feed_all(sent, size).requests, whole.requests)
  end

  return ok()
end

# A protocol error ends the stream after the requests before it, in any split.
def test_error_comes_after_the_requests_before_it() -> Result[Void]
  sent = request(["PING".bytes]) + "*1\r\n$x\r\n".bytes
  for size in [1, 5, 100]
    fed = feed_all(sent, size)
    try Test.eq(fed.requests, [["PING".bytes]])
    try Test.eq(fed.ending, Ending.Invalid("Protocol error: invalid bulk length"))
  end

  return ok()
end
