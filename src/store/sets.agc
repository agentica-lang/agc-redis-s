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

## The keyspace with `members` as a new value at the key, whatever it held and
## whatever deadline it had (setKey, which the STORE commands use); an empty set
## removes the key.
export def replace(keyspace: Keyspace.Keyspace, key: Bytes, members: Members) -> Keyspace.Keyspace
  if members.slots.empty?
    return Keyspace.delete(keyspace, key)
  end

  return Keyspace.set(keyspace, key, Value.Members(members.index, members.slots))
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

## The sets at the keys, in order, a missing key being the empty set; none when
## a live key holds another type (Redis checks every key before it works).
export def gather(keyspace: Keyspace.Keyspace, keys: List[Bytes], now_ms: Int) -> Optional[List[Members]]
  found: List[Members] = []
  for key in keys
    case held(keyspace, key, now_ms)
      Held.Foreign -> return none
      Held.Missing -> found = found.push(empty())
      Held.Found(members) -> found = found.push(members)
    end
  end

  return some(found)
end

## The members of any of the sets, each once.
export def union(sets: List[Members]) -> List[Bytes]
  return list(sets.reduce(empty()) do |all, members| merge(all, members) end)
end

## The members of all the sets, taken from the smallest one: at most `limit` of
## them when `limit` is above 0 (SINTERCARD stops there).
export def intersection(sets: List[Members], limit: Int) -> List[Bytes]
  if sets.empty?
    return []
  end

  ordered = sets.sort_by do |members| size(members) end
  others = ordered.drop(1)
  common: List[Bytes] = []
  for member in list(ordered[0])
    if in_all?(others, member)
      common = common.push(member)
      if limit > 0 and common.size >= limit
        break
      end
    end
  end

  return common
end

## The members of the first set that no other one has.
export def difference(sets: List[Members]) -> List[Bytes]
  if sets.empty?
    return []
  end

  others = sets.drop(1)
  return list(sets[0]).select do |member| not in_any?(others, member) end
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

def merge(into: Members, more: Members) -> Members
  return list(more).reduce(into) do |all, member| add(all, member) end
end

def in_all?(sets: List[Members], member: Bytes) -> Bool
  return sets.all? do |members| has?(members, member) end
end

def in_any?(sets: List[Members], member: Bytes) -> Bool
  return sets.any? do |members| has?(members, member) end
end
