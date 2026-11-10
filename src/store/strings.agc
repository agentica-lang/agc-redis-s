## Operations on the bytes of a string value. Pure and sized as Redis's: a
## string holds at most `proto-max-bulk-len` bytes.

import Keyspace from "keyspace"
import {Value, joined_text, pending?, string?, value_size, with_more} from "value"

## 512 MB, the default of `proto-max-bulk-len`.
export MAX_BYTES = 536_870_912

## What a read of some keys saw: the keyspace with their pieces joined, and
## whether that changed anything (then the command answers with `write`).
export struct Settled
  keyspace: Keyspace.Keyspace
  changed: Bool
end

## True when the key holds a live value that is not a string: the string
## commands answer WRONGTYPE.
export def foreign?(keyspace: Keyspace.Keyspace, key: Bytes, now_ms: Int) -> Bool
  case Keyspace.get(keyspace, key, now_ms)
    none -> return false
    some(value) -> return not string?(value)
  end
end

## `count` zero bytes, built by doubling, so the copies add up to `count`.
export def zeros(count: Int) -> Bytes
  built = "".bytes
  piece = Bytes.from_list([0]).unwrap!
  left = count
  while left > 0
    if left % 2 == 1
      built = built + piece
    end

    piece = piece + piece
    left = left / 2
  end

  return built
end

## `old` with `value` written at `offset`, zero bytes filling a gap, as SETRANGE
## does. The offset is at most MAX_BYTES (the command checks it).
export def set_range(old: Bytes, offset: Int, value: Bytes) -> Bytes
  head = old.take(offset)
  if old.size < offset
    head = old + zeros(offset - old.size)
  end

  return Bytes.concat([head, value, old.drop(offset + value.size)])
end

## The bytes from `start` to `stop` inclusive; a negative index counts from the
## end, and an index past an end is cut to it, as GETRANGE does.
export def get_range(text: Bytes, start: Int, stop: Int) -> Bytes
  size = text.size
  if start < 0 and stop < 0 and start > stop
    return "".bytes
  end

  from = start
  to = stop
  if from < 0
    from = size + from
  end

  if to < 0
    to = size + to
  end

  if from < 0
    from = 0
  end

  if to < 0
    to = 0
  end

  if to >= size
    to = size - 1
  end

  if from > to or size == 0
    return "".bytes
  end

  return text.slice(from, to - from + 1)
end

## The value after APPEND of `more`, or none when the total would pass `limit`
## (the handler passes MAX_BYTES). The total counts the stored size, not the
## new piece alone, and nothing is joined.
export def append(held: Optional[Value], more: Bytes, limit: Int) -> Optional[Value]
  base = held.unwrap_or(Value.Str("".bytes))
  if value_size(base) + more.size > limit
    return none
  end

  return some(with_more(base, more))
end

## The keyspace with the string at each of `keys` joined into one `Str`. A value
## built by many APPENDs is joined here once; the command stores the result, so
## the next read finds one piece and copies nothing.
export def settle(keyspace: Keyspace.Keyspace, keys: List[Bytes], now_ms: Int) -> Settled
  result = Settled(keyspace: keyspace, changed: false)
  for key in keys
    case Keyspace.get(result.keyspace, key, now_ms)
      none -> nil
      some(value) ->
        if pending?(value)
          joined = Keyspace.put(result.keyspace, key, Value.Str(joined_text(value)), now_ms)
          result = Settled(keyspace: joined, changed: true)
        end
    end
  end

  return result
end
