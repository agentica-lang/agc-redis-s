## Reading and writing the list at a key (Redis 7.2 t_list.c), over the `Deque`
## of store/value.agc. Every operation here costs one or a few `Map` steps, not
## a copy of the list; only `to_list` and `from_list` (LINSERT, LREM) walk it.
## A list is never empty: storing an empty one deletes the key, as Redis does
## when the last element is popped.

import Keyspace from "keyspace"
import {Value} from "value"

## The elements of a list: the element at index i is `items[head + i]`.
export struct Seq
  items: Map[Int, Bytes]
  head: Int
end

## What a key holds, as a list command sees it.
export enum Held
  Missing
  Items(Seq)
  ## A live key of another type: the command answers WRONGTYPE.
  Foreign
end

## An end of a list, as LMOVE and LMPOP name it.
export enum End
  Head
  Tail
end

## An inclusive range of indexes, both inside the list.
export struct Span
  first: Int
  last: Int
end

export def held(keyspace: Keyspace.Keyspace, key: Bytes, now_ms: Int) -> Held
  case Keyspace.get(keyspace, key, now_ms)
    none -> return Held.Missing
    some(value) ->
      case value
        Value.Deque(items, head) -> return Held.Items(Seq(items: items, head: head))
        _ -> return Held.Foreign
      end
  end
end

## The keyspace with `seq` at the key. A live key keeps its deadline (the write
## changes the old value); an empty list removes the key.
export def store(keyspace: Keyspace.Keyspace, key: Bytes, seq: Seq, now_ms: Int) -> Keyspace.Keyspace
  if seq.items.empty?
    return Keyspace.delete(keyspace, key)
  end

  return Keyspace.put(keyspace, key, Value.Deque(seq.items, seq.head), now_ms)
end

export def empty() -> Seq
  return Seq(items: {}, head: 0)
end

export def length(seq: Seq) -> Int
  return seq.items.size
end

## The element at index `index`, 0 for the head; none outside the list.
export def get(seq: Seq, index: Int) -> Optional[Bytes]
  if index < 0 or index >= length(seq)
    return none
  end

  return seq.items.get(seq.head + index)
end

## The list with `element` before its first one (LPUSH of one element).
export def push_front(seq: Seq, element: Bytes) -> Seq
  return Seq(items: seq.items.put(seq.head - 1, element), head: seq.head - 1)
end

## The list with `element` after its last one (RPUSH of one element).
export def push_back(seq: Seq, element: Bytes) -> Seq
  return Seq(items: seq.items.put(seq.head + length(seq), element), head: seq.head)
end

## The list with `element` at `side`.
export def push(seq: Seq, element: Bytes, side: End) -> Seq
  case side
    End.Head -> return push_front(seq, element)
    End.Tail -> return push_back(seq, element)
  end
end

## The element at `end` of a non-empty list.
export def edge(seq: Seq, side: End) -> Bytes
  index = 0
  case side
    End.Head -> index = 0
    End.Tail -> index = length(seq) - 1
  end

  return get(seq, index).unwrap_or("".bytes)
end

## The list without its `count` elements at `side` (at most the length).
export def drop(seq: Seq, side: End, count: Int) -> Seq
  case side
    End.Head -> return drop_front(seq, count)
    End.Tail -> return drop_back(seq, count)
  end
end

## The list without its first `count` elements (the count is at most the
## length): one `Map` step each.
export def drop_front(seq: Seq, count: Int) -> Seq
  items = seq.items
  for offset in 0...count
    items = items.delete(seq.head + offset)
  end

  return Seq(items: items, head: seq.head + count)
end

## The list without its last `count` elements (at most the length).
export def drop_back(seq: Seq, count: Int) -> Seq
  last = seq.head + length(seq) - 1
  items = seq.items
  for offset in 0...count
    items = items.delete(last - offset)
  end

  return Seq(items: items, head: seq.head)
end

## The list with the element at `index` (inside the list) replaced.
export def set(seq: Seq, index: Int, element: Bytes) -> Seq
  return Seq(items: seq.items.put(seq.head + index, element), head: seq.head)
end

## All the elements in order: O(n), for the commands that rebuild the list
## (LINSERT, LREM), as they do in Redis.
export def to_list(seq: Seq) -> List[Bytes]
  picked: List[Bytes] = []
  for offset in 0...length(seq)
    picked = picked.push(seq.items.get(seq.head + offset, "".bytes))
  end

  return picked
end

export def from_list(elements: List[Bytes]) -> Seq
  items: Map[Int, Bytes] = {}
  for index in 0...elements.size
    items = items.put(index, elements[index])
  end

  return Seq(items: items, head: 0)
end

## The range `start` to `stop` of a list of `size` elements as Redis reads it
## (addListRangeReply, ltrimCommand): a negative index counts from the tail, a
## start before the head is the head, a stop past the tail is the tail. None
## when nothing is left.
export def span_of(size: Int, start: Int, stop: Int) -> Optional[Span]
  first = start
  last = stop
  if first < 0
    first = size + first
  end

  if last < 0
    last = size + last
  end

  if first < 0
    first = 0
  end

  if first > last or first >= size
    return none
  end

  if last >= size
    last = size - 1
  end

  return some(Span(first: first, last: last))
end
