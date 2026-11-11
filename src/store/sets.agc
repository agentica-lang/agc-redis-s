## Reading and writing the set at a key (Redis 7.2 t_set.c), over the `Members`
## of store/value.agc. A member, an add and a removal cost a few `Map` steps; a
## member by position (SPOP, SRANDMEMBER) costs one. A set is never empty:
## storing an empty one deletes the key, as Redis does after the last SREM.

import Keyspace from "keyspace"
import {Value} from "value"

## The members: `index` maps a member to its slot, `slots` the slot to the
## member. The slots are 0 up to size - 1 with no gap.
export struct Members
  index: Map[Bytes, Int]
  slots: Map[Int, Bytes]
end

## What a key holds, as a set command sees it.
export enum Held
  Missing
  Found(Members)
  ## A live key of another type: the command answers WRONGTYPE.
  Foreign
end

export def held(keyspace: Keyspace.Keyspace, key: Bytes, now_ms: Int) -> Held
  case Keyspace.get(keyspace, key, now_ms)
    none -> return Held.Missing
    some(value) ->
      case value
        Value.Members(index, slots) -> return Held.Found(Members(index: index, slots: slots))
        _ -> return Held.Foreign
      end
  end
end

## The keyspace with `members` at the key. A live key keeps its deadline (the
## write changes the old value); an empty set removes the key.
export def store(keyspace: Keyspace.Keyspace, key: Bytes, members: Members, now_ms: Int) -> Keyspace.Keyspace
  if members.slots.empty?
    return Keyspace.delete(keyspace, key)
  end

  return Keyspace.put(keyspace, key, Value.Members(members.index, members.slots), now_ms)
end

export def empty() -> Members
  return Members(index: {}, slots: {})
end

export def size(members: Members) -> Int
  return members.slots.size
end

export def has?(members: Members, member: Bytes) -> Bool
  return members.index.has_key?(member)
end

## The set with `member` added; a member that is there leaves it as it is.
export def add(members: Members, member: Bytes) -> Members
  if has?(members, member)
    return members
  end

  slot = members.slots.size
  return Members(index: members.index.put(member, slot), slots: members.slots.put(slot, member))
end

## The set without `member`: the last member takes its slot.
export def remove(members: Members, member: Bytes) -> Members
  case members.index.get(member)
    none -> return members
    some(slot) ->
      last = members.slots.size - 1
      moved = members.slots.get(last, member)
      slots = members.slots.delete(last)
      index = members.index.delete(member)
      if slot == last
        return Members(index: index, slots: slots)
      end

      return Members(index: index.put(moved, slot), slots: slots.put(slot, moved))
  end
end

## The member in a slot, 0 up to size - 1.
export def at(members: Members, slot: Int) -> Bytes
  return members.slots.get(slot, "".bytes)
end

## All the members, in slot order.
export def list(members: Members) -> List[Bytes]
  return members.slots.values
end

export def from_list(items: List[Bytes]) -> Members
  return items.reduce(empty()) do |members, item| add(members, item) end
end
