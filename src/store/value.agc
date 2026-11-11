## What a key holds. One variant per data type; each later type adds its
## variant here and its operations in its own file of this folder.

## A string is one `Str`, or `Appended`: the pieces APPEND added, in order, with
## their total size. Bytes are immutable, so joining at every APPEND would copy
## the whole value each time; the pieces are joined once, by the first command
## that reads the text, and that command writes the `Str` back (`settle` in
## store/strings.agc).
## Invariants of `Appended`: the size is the sum of the sizes of the pieces, and
## no piece is empty.
##
## A hash is a `Hash`: field to value, in the order the fields were first set
## (a `Map` keeps it, as a Redis listpack does; the fields of a big Redis hash
## come in no order, so no client can rely on one). A hash is never empty:
## deleting its last field deletes the key (store/hashes.agc).
##
## A list is a `Deque`: the elements by position number, and the number of the
## first one (`head`), so the element at index i is `items[head + i]`. A push at
## the head takes `head - 1` (the number may go negative), a push at the tail
## takes `head + size`, and a pop removes the end's number: both ends cost one
## `Map` step, as does an element by index. A list is never empty: removing its
## last element deletes the key (store/lists.agc).
##
## A set is `Members`: the member to its slot number, and the slots by number
## (0 up to size - 1, no gaps), so a member costs one `Map` step to find and one
## to pick by position, which SPOP and SRANDMEMBER need. Removing a member moves
## the last one into its slot. A set is never empty (store/sets.agc).
##
## The string helpers below answer for a string only; a command checks the
## variant first (`string?`) and answers WRONGTYPE for the others.
export enum Value
  Str(Bytes)
  Appended(List[Bytes], Int)
  Hash(Map[Bytes, Bytes])
  Deque(Map[Int, Bytes], Int)
  Members(Map[Bytes, Int], Map[Int, Bytes])
end

## The name `TYPE` and `SCAN ... TYPE` use.
export def type_name(value: Value) -> String
  case value
    Value.Str(_) -> return "string"
    Value.Appended(_, _) -> return "string"
    Value.Hash(_) -> return "hash"
    Value.Deque(_, _) -> return "list"
    Value.Members(_, _) -> return "set"
  end
end

export def string?(value: Value) -> Bool
  return type_name(value) == "string"
end

## The bytes of a string value. For `Appended` this joins the pieces: a command
## that wants the text uses `settled`, so the join happens once per value.
export def joined_text(value: Value) -> Bytes
  case value
    Value.Str(bytes) -> return bytes
    Value.Appended(pieces, _) -> return Bytes.concat(pieces)
    Value.Hash(_) -> return "".bytes
    Value.Deque(_, _) -> return "".bytes
    Value.Members(_, _) -> return "".bytes
  end
end

## The size in bytes of a string value, without joining.
export def value_size(value: Value) -> Int
  case value
    Value.Str(bytes) -> return bytes.size
    Value.Appended(_, total) -> return total
    Value.Hash(_) -> return 0
    Value.Deque(_, _) -> return 0
    Value.Members(_, _) -> return 0
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
    Value.Hash(_) -> return value
    Value.Deque(_, _) -> return value
    Value.Members(_, _) -> return value
  end
end

## True when reading the text joins pieces.
export def pending?(value: Value) -> Bool
  case value
    Value.Str(_) -> return false
    Value.Appended(_, _) -> return true
    Value.Hash(_) -> return false
    Value.Deque(_, _) -> return false
    Value.Members(_, _) -> return false
  end
end
