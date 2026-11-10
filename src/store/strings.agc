## Operations on the bytes of a string value. Pure and sized as Redis's: a
## string holds at most `proto-max-bulk-len` bytes.

## 512 MB, the default of `proto-max-bulk-len`.
export MAX_BYTES = 536_870_912

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
