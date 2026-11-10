## The RESP2 request reader: bytes to one request. It resumes from a `Partial`
## and slices only the arguments, so a read that holds many pipelined requests
## walks the buffer once, and a request that arrives in pieces is never parsed
## twice. A request is an array of bulk strings or an inline line (`redis-cli`,
## telnet).

import Integer from "integer"

MAX_BULK = 536_870_912
# A deliberate memory guard, stricter than Redis 7 (which allows INT_MAX items).
MAX_ARRAY = 1_048_576
# Redis closes a client that holds more than this in its query buffer.
MAX_QUERY = 1_073_741_824
# Redis's PROTO_INLINE_MAX_SIZE: a header or inline line longer than this
# without a LF is an error, so a line that never ends cannot grow the buffer.
export MAX_LINE = 65_536
LF = 10
CR = 13
DOLLAR = 36
STAR = 42
ZERO = 48
NINE = 57
DQUOTE = 34
SQUOTE = 39
BACKSLASH = 92
LOWER_X = 120

## Where reading goes on, and what an unfinished array holds so far.
export struct Partial
  ## Offset in the buffer where the next step starts.
  at: Int = 0
  ## Bytes, counted from `at`, the buffer must hold before a retry can go
  ## further. The caller waits for them instead of parsing again.
  need: Int = 1
  ## Bytes after `at` already seen to hold no LF, so a line is scanned once.
  scanned: Int = 0
  ## The step waits for the LF of a line: the caller needs no new parse until
  ## a chunk holds a LF or the line passes MAX_LINE.
  line: Bool = false
  items: List[Bytes] = []
  ## Items of the array still to come; 0 outside an array.
  remaining: Int = 0
  ## Bytes of `items`, for the query buffer limit.
  held: Int = 0
end

export enum Read
  ## One request; `next` is the offset after it.
  Request(List[Bytes], Int)
  ## An empty line or an empty array: nothing to run, go on at the offset.
  Skip(Int)
  ## The buffer ends inside a request: read more and try again from here.
  Incomplete(Partial)
  ## A protocol error; the text is the reply, and the connection closes.
  Invalid(String)
  ## The request is past the query buffer limit; Redis closes without a reply.
  Overflow
end

enum Line
  Found(Int)
  Stop(Read)
end

enum Bulk
  Item(Bytes, Int)
  More(Int, Int, Bool)
  Fail(Read)
end

enum Arg
  Done(List[Int], Int)
  Unbalanced
end

## Reads the request that starts at `from.at`.
export def read_request(buf: Bytes, from: Partial) -> Read
  if from.remaining > 0
    return array_items(buf, from)
  end

  if from.at >= buf.size
    return Read.Incomplete(from.with(need: 1, scanned: 0, line: false))
  end

  if buf[from.at] == STAR
    return read_array(buf, from)
  end

  return read_inline(buf, from)
end

# The offset of the LF of the line at `from.at`. Without one, the line may
# still grow, up to MAX_LINE.
def find_line(buf: Bytes, from: Partial, too_big: String) -> Line
  i = from.at + from.scanned
  while i < buf.size
    if buf[i] == LF
      return Line.Found(i)
    end

    i += 1
  end

  seen = buf.size - from.at
  if seen > MAX_LINE
    return Line.Stop(Read.Invalid(too_big))
  end

  return Line.Stop(Read.Incomplete(from.with(need: seen + 1, scanned: seen, line: true)))
end

# The line without its CR LF; `lf` is the offset of the LF.
def line_text(buf: Bytes, from: Int, lf: Int) -> Bytes
  stop = lf
  if stop > from and buf[stop - 1] == CR
    stop -= 1
  end

  return buf.slice(from, stop - from)
end

def read_inline(buf: Bytes, from: Partial) -> Read
  case find_line(buf, from, "Protocol error: too big inline request")
    Line.Stop(read) -> return read
    Line.Found(lf) -> return inline_request(line_text(buf, from.at, lf), lf + 1)
  end
end

def inline_request(line: Bytes, next: Int) -> Read
  case split_args(line)
    none -> return Read.Invalid("Protocol error: unbalanced quotes in request")
    some(words) ->
      if words.empty?
        return Read.Skip(next)
      end

      return Read.Request(words, next)
  end
end

# Words are bytes: an argument that is not UTF-8 is still an argument. A line
# with no quote and no NUL splits on whitespace alone, which is the common case.
def split_args(line: Bytes) -> Optional[List[Bytes]]
  if plain?(line)
    return some(split_words(line))
  end

  return split_quoted(cut_at_nul(line))
end

def plain?(line: Bytes) -> Bool
  for byte in line
    if byte == DQUOTE or byte == SQUOTE or byte == 0
      return false
    end
  end

  return true
end

# Redis reads the line as a C string: a NUL ends it.
def cut_at_nul(line: Bytes) -> Bytes
  for i in 0...line.size
    if line[i] == 0
      return line.take(i)
    end
  end

  return line
end

# Redis skips leading blanks with C isspace, but an unquoted word ends only at
# a space, LF, CR, TAB or NUL: `a\vb` is one word.
def split_words(line: Bytes) -> List[Bytes]
  words: List[Bytes] = []
  i = 0
  while true
    while i < line.size and space?(line[i])
      i += 1
    end

    if i >= line.size
      return words
    end

    start = i
    while i < line.size and not word_end?(line[i])
      i += 1
    end

    words = words.push(line.slice(start, i - start))
  end

  return words
end

def word_end?(byte: Int) -> Bool
  return byte == 32 or byte == LF or byte == CR or byte == 9 or byte == 0
end

def space?(byte: Int) -> Bool
  return byte == 32 or (byte >= 9 and byte <= 13)
end

# Redis's sdssplitargs: quotes may start inside a word, and a closing quote
# must be followed by a space or the end of the line.
def split_quoted(line: Bytes) -> Optional[List[Bytes]]
  words: List[Bytes] = []
  i = 0
  while true
    while i < line.size and space?(line[i])
      i += 1
    end

    if i >= line.size
      return some(words)
    end

    case read_word(line, i)
      Arg.Unbalanced -> return none
      Arg.Done(bytes, next) ->
        words = words.push(Bytes.from_list(bytes).unwrap!)
        i = next
    end
  end

  return some(words)
end

def read_word(line: Bytes, start: Int) -> Arg
  out: List[Int] = []
  i = start
  quote = 0
  while true
    if i >= line.size
      if quote != 0
        return Arg.Unbalanced
      end

      return Arg.Done(out, i)
    end

    byte = line[i]
    if quote == 0
      if word_end?(byte)
        return Arg.Done(out, i)
      end

      if byte == DQUOTE or byte == SQUOTE
        quote = byte
      else
        out = out.push(byte)
      end

      i += 1
    elsif byte == quote
      if i + 1 < line.size and not space?(line[i + 1])
        return Arg.Unbalanced
      end

      return Arg.Done(out, i + 1)
    elsif byte == BACKSLASH and quote == DQUOTE and hex_escape?(line, i)
      out = out.push(hex_value(line[i + 2]) * 16 + hex_value(line[i + 3]))
      i += 4
    elsif byte == BACKSLASH and quote == DQUOTE and i + 1 < line.size
      out = out.push(escaped(line[i + 1]))
      i += 2
    elsif byte == BACKSLASH and quote == SQUOTE and i + 1 < line.size and line[i + 1] == SQUOTE
      out = out.push(SQUOTE)
      i += 2
    else
      out = out.push(byte)
      i += 1
    end
  end

  return Arg.Unbalanced
end

def hex_escape?(line: Bytes, i: Int) -> Bool
  return i + 3 < line.size and line[i + 1] == LOWER_X and hex_value(line[i + 2]) >= 0 and hex_value(line[i + 3]) >= 0
end

# -1 when the byte is not a hex digit.
def hex_value(byte: Int) -> Int
  if byte >= ZERO and byte <= NINE
    return byte - ZERO
  end

  if byte >= 97 and byte <= 102
    return byte - 87
  end

  if byte >= 65 and byte <= 70
    return byte - 55
  end

  return -1
end

# After a backslash in double quotes; any other byte stands for itself.
def escaped(byte: Int) -> Int
  return case byte
    110 -> LF
    114 -> CR
    116 -> 9
    98 -> 8
    97 -> 7
    _ -> byte
  end
end

def read_array(buf: Bytes, from: Partial) -> Read
  case find_line(buf, from, "Protocol error: too big mbulk count string")
    Line.Stop(read) -> return read
    Line.Found(lf) ->
      case Integer.parse(line_text(buf, from.at + 1, lf))
        none -> return Read.Invalid("Protocol error: invalid multibulk length")
        some(n) ->
          if n > MAX_ARRAY
            return Read.Invalid("Protocol error: invalid multibulk length")
          end

          if n <= 0
            return Read.Skip(lf + 1)
          end

          return array_items(buf, Partial(at: lf + 1, remaining: n))
      end
  end
end

# Goes on with the items of an array. When the buffer ends, the items so far
# and the offset of the unfinished one go back in the `Partial`.
def array_items(buf: Bytes, from: Partial) -> Read
  pos = from.at
  scanned = from.scanned
  remaining = from.remaining
  held = from.held
  items = from.items
  while remaining > 0
    case read_bulk(buf, pos, scanned, held)
      Bulk.Item(data, next) ->
        items = items.push(data)
        held += data.size
        remaining -= 1
        pos = next
        scanned = 0
      Bulk.More(need, seen, line) ->
        return Read.Incomplete(
          Partial(at: pos, need: need, scanned: seen, line: line, items: items, remaining: remaining, held: held),
        )
      Bulk.Fail(read) -> return read
    end
  end

  return Read.Request(items, pos)
end

def read_bulk(buf: Bytes, from: Int, scanned: Int, held: Int) -> Bulk
  if from >= buf.size
    return Bulk.More(1, 0, false)
  end

  if buf[from] != DOLLAR
    return Bulk.Fail(
      Read.Invalid("Protocol error: expected '$', got '#{String.from_bytes(buf.slice(from, 1)).unwrap_or("?")}'"),
    )
  end

  case find_line(buf, Partial(at: from, scanned: scanned), "Protocol error: too big bulk count string")
    Line.Stop(Read.Incomplete(p)) -> return Bulk.More(p.need, p.scanned, true)
    Line.Stop(read) -> return Bulk.Fail(read)
    Line.Found(lf) ->
      case Integer.parse(line_text(buf, from + 1, lf))
        none -> return Bulk.Fail(Read.Invalid("Protocol error: invalid bulk length"))
        some(n) -> return bulk_slice(buf, from, n, lf + 1, held)
      end
  end
end

# The payload is `n` bytes and then CR LF, which is skipped without a check, as
# Redis does. A short buffer asks for the whole bulk at once, so the caller
# joins its chunks one time instead of at each receive.
def bulk_slice(buf: Bytes, from: Int, n: Int, start: Int, held: Int) -> Bulk
  if n < 0 or n > MAX_BULK
    return Bulk.Fail(Read.Invalid("Protocol error: invalid bulk length"))
  end

  if held + n > MAX_QUERY
    return Bulk.Fail(Read.Overflow)
  end

  if start + n + 2 > buf.size
    return Bulk.More(start + n + 2 - from, 0, false)
  end

  return Bulk.Item(buf.slice(start, n), start + n + 2)
end
