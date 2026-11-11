import Stream from "../../src/resp/stream"
import {Ending} from "../../src/resp/stream"
import {argv_gen, quote, request, to_bytes} from "../support"
import Prop from "pkg/prop/prop"

# What may follow the requests: nothing, a protocol error, or a request that
# stops inside a header, a payload or a quote.
TAILS = ["", "*x\r\n", "*1\r\n$", "*1\r\n$3\r\nab", "PING \"x", "*2\r\n$1\r\na\r\n$x\r\n"]
# Lines that run nothing, which may come before any request.
BLANKS = ["", "\r\n", "  \r\n", "*0\r\n"]
ARRAY = 0
QUOTED = 1

struct Case
  requests: List[List[List[Int]]]
  # How each request is written: ARRAY, QUOTED inline, or plain inline (2).
  forms: List[Int]
  blanks: List[String]
  tail: String
  sizes: List[Int]
end

def case_gen() -> Prop.Gen[Case]
  argv = argv_gen(6, 3)
  shape = Prop.pair(Prop.list(argv, 4), Prop.list(Prop.int(0, 2), 4))
  blank = Prop.list(Prop.one_of(BLANKS), 4)
  filler = Prop.pair(blank, Prop.one_of(TAILS))
  sizes = Prop.pair(filler, Prop.list(Prop.int(1, 12), 6))
  Prop.map(Prop.pair(shape, sizes)) do |p|
    Case(
      requests: p.first.first,
      forms: p.first.second,
      blanks: p.second.first.first,
      tail: p.second.first.second,
      sizes: p.second.second,
    )
  end
end

# A plain inline line has no quotes, so its words are letters: that is the
# path of the reader that does not look for quotes.
def letters(arg: List[Int]) -> List[Int]
  return [97] if arg.empty?

  arg.map do |b| 97 + b % 26 end
end

def form_of(c: Case, i: Int) -> Int
  return c.forms[i] if i < c.forms.size

  ARRAY
end

# The arguments the reader must give back for request `i`.
def expected(c: Case, i: Int) -> List[List[Int]]
  return c.requests[i].map do |a| letters(a) end if form_of(c, i) > QUOTED

  c.requests[i]
end

def wire(c: Case, i: Int) -> Bytes
  argv = expected(c, i).map do |xs| to_bytes(xs) end
  form = form_of(c, i)
  return request(argv) if form == ARRAY

  return Bytes.concat(argv.map do |a| quote(a) + " ".bytes end) + "\r\n".bytes if form == QUOTED

  Bytes.concat(argv.map do |a| a + " ".bytes end) + "\r\n".bytes
end

def stream_of(c: Case) -> Bytes
  parts: List[Bytes] = []
  for i in 0...c.requests.size
    if i < c.blanks.size
      parts = parts.push(c.blanks[i].bytes)
    end

    parts = parts.push(wire(c, i))
  end

  Bytes.concat(parts.push(c.tail.bytes))
end

# The requests and the ending when the bytes arrive in chunks of the given sizes
# (the list repeats, so it must not be empty), as text because `Bytes` is not JSON.
def feed_in_chunks(bytes: Bytes, sizes: List[Int]) -> List[String]
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

  ints = requests.map do |r| r.map do |a| a.to_a end end
  ["#{ints}", "#{ending}"]
end

# A stream of arrays, quoted and plain inline lines, with blank lines between,
# ending in nothing, a protocol error or an unfinished request. The whole stream
# gives the generated requests, and any cut of it gives the same as the whole.
# 50 runs: the step budget of a test ends between 100 and 150.
def test_chunks_give_the_same_requests() -> Result[Void]
  Prop.check(case_gen(), Prop.Config(runs: 50)) do |c|
    bytes = stream_of(c)
    whole = feed_in_chunks(bytes, [bytes.size + 1])
    sent = c.requests.size
    wanted = (0...sent).to_a.map do |i| expected(c, i) end
    try Prop.eq(whole[0], "#{wanted}")
    Prop.eq(feed_in_chunks(bytes, c.sizes.concat([2])), whole)
  end
end
