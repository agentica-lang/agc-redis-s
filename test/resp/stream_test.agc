import Stream from "../../src/resp/stream"
import {Ending} from "../../src/resp/stream"
import {argv_gen, quote, request, to_bytes} from "../support"
import Prop from "pkg/prop/prop"

# What may follow the requests: nothing, a protocol error, or a request that
# stops inside a header, a payload or a quote.
TAILS = ["", "*x\r\n", "*1\r\n$", "*1\r\n$3\r\nab", "PING \"x", "*2\r\n$1\r\na\r\n$x\r\n"]

struct Case
  requests: List[List[List[Int]]]
  inline: List[Bool]
  tail: String
  sizes: List[Int]
end

# Each request as an array or as an inline line, then a tail, in a few bytes.
def case_gen() -> Prop.Gen[Case]
  argv = argv_gen(6, 3)
  shape = Prop.pair(Prop.list(argv, 4), Prop.list(Prop.bool(), 4))
  rest = Prop.pair(Prop.one_of(TAILS), Prop.list(Prop.int(1, 12), 6))
  return Prop.map(Prop.pair(shape, rest)) do |p|
    Case(requests: p.first.first, inline: p.first.second, tail: p.second.first, sizes: p.second.second)
  end
end

def wire(items: List[List[Int]], inline: Bool) -> Bytes
  argv = items.map do |xs| to_bytes(xs) end
  if inline
    return Bytes.concat(argv.map do |a| quote(a) + " ".bytes end) + "\r\n".bytes
  end

  return request(argv)
end

def stream_of(c: Case) -> Bytes
  parts: List[Bytes] = []
  for i in 0...c.requests.size
    inline = i < c.inline.size and c.inline[i]
    parts = parts.push(wire(c.requests[i], inline))
  end

  return Bytes.concat(parts.push(c.tail.bytes))
end

# The requests and the ending when the bytes arrive in chunks of the given sizes
# (the list repeats, so it must not be empty), as text because `Bytes` is not JSON.
def feed_in_chunks(bytes: Bytes, sizes: List[Int]) -> String
  stream = Stream.start()
  requests: List[List[Bytes]] = []
  ending = Ending.Open
  pos = 0
  n = 0
  while pos < bytes.size and ending == Ending.Open
    take = sizes[n % sizes.size]
    if bytes.size - pos < take
      take = bytes.size - pos
    end

    fed = Stream.feed(stream, bytes.slice(pos, take))
    stream = fed.stream
    requests = requests.concat(fed.requests)
    ending = fed.ending
    pos += take
    n += 1
  end

  return "#{requests.map do |r| r.map do |a| a.to_a end end} #{ending}"
end

# Any cut of a stream of arrays and inline lines, ending in an error or an
# unfinished request, gives what the whole stream gives. 80 runs (the step budget of
# a test ends near 150): up to 4 requests of 4 arguments of 6 bytes.
def test_chunks_give_the_same_requests() -> Result[Void]
  return Prop.check(case_gen(), Prop.Config(runs: 80)) do |c|
    bytes = stream_of(c)
    Prop.eq(feed_in_chunks(bytes, c.sizes.concat([2])), feed_in_chunks(bytes, [bytes.size + 1]))
  end
end
