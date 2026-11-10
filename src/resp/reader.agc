## The RESP2 request reader: bytes to one request. It starts at an offset and
## never copies the buffer, so a read that holds many pipelined requests walks
## it once. A request is an array of bulk strings or an inline line
## (`redis-cli`, telnet).

MAX_BULK = 536_870_912
MAX_ARRAY = 1_048_576
LF = 10
CR = 13
DOLLAR = 36
STAR = 42

export enum Read
  ## One request; `next` is the offset after it.
  Request(List[Bytes], Int)
  ## An empty line or an empty array: nothing to run, go on at the offset.
  Skip(Int)
  ## The buffer ends inside a request: read more and try again.
  Incomplete
  ## A protocol error; the text is the reply, and the connection closes.
  Invalid(String)
end

enum Bulk
  Item(Bytes, Int)
  More
  Bad(String)
end

export def read_request(buf: Bytes, from: Int) -> Read
  if from >= buf.size
    return Read.Incomplete
  end

  if buf[from] == STAR
    return read_array(buf, from)
  end

  return read_inline(buf, from)
end

# The offset of the first LF at or after `from`.
def find_lf(buf: Bytes, from: Int) -> Optional[Int]
  i = from
  while i < buf.size
    if buf[i] == LF
      return some(i)
    end

    i += 1
  end

  return none
end

# The line without its CR LF; `lf` is the offset of the LF.
def line_text(buf: Bytes, from: Int, lf: Int) -> Bytes
  stop = lf
  if stop > from and buf[stop - 1] == CR
    stop -= 1
  end

  return buf.slice(from, stop - from)
end

def parse_int(text: Bytes) -> Optional[Int]
  case String.from_bytes(text)
    error(_) -> return none
    ok(s) ->
      case s.to_i
        ok(n) -> return some(n)
        error(_) -> return none
      end
  end
end

def read_inline(buf: Bytes, from: Int) -> Read
  case find_lf(buf, from)
    none -> return Read.Incomplete
    some(lf) -> return inline_request(line_text(buf, from, lf), lf + 1)
  end
end

def inline_request(line: Bytes, next: Int) -> Read
  words = String.from_bytes(line).unwrap_or("").split(" ").select do |w| w != "" end
  if words.empty?
    return Read.Skip(next)
  end

  return Read.Request(words.map do |w| w.bytes end, next)
end

def read_array(buf: Bytes, from: Int) -> Read
  case find_lf(buf, from)
    none -> return Read.Incomplete
    some(lf) ->
      case parse_int(line_text(buf, from + 1, lf))
        none -> return Read.Invalid("Protocol error: invalid multibulk length")
        some(n) -> return array_items(buf, n, lf + 1)
      end
  end
end

def array_items(buf: Bytes, count: Int, from: Int) -> Read
  if count > MAX_ARRAY
    return Read.Invalid("Protocol error: invalid multibulk length")
  end

  if count <= 0
    return Read.Skip(from)
  end

  pos = from
  items: List[Bytes] = []
  while items.size < count
    case read_bulk(buf, pos)
      Bulk.Item(data, next) ->
        items = items.push(data)
        pos = next
      Bulk.More -> return Read.Incomplete
      Bulk.Bad(text) -> return Read.Invalid(text)
    end
  end

  return Read.Request(items, pos)
end

def read_bulk(buf: Bytes, from: Int) -> Bulk
  if from >= buf.size
    return Bulk.More
  end

  if buf[from] != DOLLAR
    return Bulk.Bad("Protocol error: expected '$', got '#{String.from_bytes(buf.slice(from, 1)).unwrap_or("?")}'")
  end

  case find_lf(buf, from)
    none -> return Bulk.More
    some(lf) ->
      case parse_int(line_text(buf, from + 1, lf))
        none -> return Bulk.Bad("Protocol error: invalid bulk length")
        some(n) -> return bulk_slice(buf, n, lf + 1)
      end
  end
end

# The payload is `n` bytes and then CR LF, which is skipped without a check.
def bulk_slice(buf: Bytes, n: Int, start: Int) -> Bulk
  if n < 0 or n > MAX_BULK
    return Bulk.Bad("Protocol error: invalid bulk length")
  end

  if start + n + 2 > buf.size
    return Bulk.More
  end

  return Bulk.Item(buf.slice(start, n), start + n + 2)
end
