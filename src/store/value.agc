## What a key holds. One variant per data type; each later type adds its
## variant here and its operations in its own file of this folder.

## A string is one `Str`, or `Appended`: the pieces APPEND added, in order, with
## their total size. Bytes are immutable, so joining at every APPEND would copy
## the whole value each time; the pieces are joined once, by the first command
## that reads the text, and that command writes the `Str` back (`settle` in
## store/strings.agc).
## Invariants of `Appended`: the size is the sum of the sizes of the pieces, and
## no piece is empty.
export enum Value
  Str(Bytes)
  Appended(List[Bytes], Int)
end

## The bytes of a string value. For `Appended` this joins the pieces: a command
## that wants the text uses `settled`, so the join happens once per value.
export def joined_text(value: Value) -> Bytes
  case value
    Value.Str(bytes) -> return bytes
    Value.Appended(pieces, _) -> return Bytes.concat(pieces)
  end
end

## The size in bytes of a string value, without joining.
export def value_size(value: Value) -> Int
  case value
    Value.Str(bytes) -> return bytes.size
    Value.Appended(_, total) -> return total
  end
end

## The value with `more` added at its end, in O(1) of the size: the pieces are
## kept, not joined.
export def with_more(value: Value, more: Bytes) -> Value
  if more.empty?
    return value
  end

  case value
    Value.Str(bytes) ->
      if bytes.empty?
        return Value.Str(more)
      end

      return Value.Appended([bytes, more], bytes.size + more.size)
    Value.Appended(pieces, total) -> return Value.Appended(pieces.push(more), total + more.size)
  end
end

## True when reading the text joins pieces.
export def pending?(value: Value) -> Bool
  case value
    Value.Str(_) -> return false
    Value.Appended(_, _) -> return true
  end
end
