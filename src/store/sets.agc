## Reading and writing the set at a key (Redis 7.2 t_set.c), over the `Members`
## of store/value.agc. A member, an add and a removal cost a few `Map` steps; a
## member by position (SPOP, SRANDMEMBER) costs one. A set is never empty:
## storing an empty one deletes the key, as Redis does after the last SREM.

import Keyspace from "keyspace"
import {Value} from "value"

## The members: `index` maps a member to its slot, `slots` the slot to the
## member. The slots are 0 up to size - 1 with no gap.
struct Members
  index: Map[Bytes, Int]
  slots: Map[Int, Bytes]
end

## What a key holds, as a set command sees it.
enum Held
  Missing
  Found(Members)
  ## A live key of another type: the command answers WRONGTYPE.
  Foreign
end

def held(keyspace: Keyspace.Keyspace, key: Bytes, now_ms: Int) -> Held
  case Keyspace.get(keyspace, key, now_ms)
    none -> Held.Missing
    some(value) ->
      case value
        Value.Members(index, slots) -> Held.Found(Members(index: index, slots: slots))
        _ -> Held.Foreign
      end
  end
end

## The keyspace with `members` at the key. A live key keeps its deadline (the
## write changes the old value); an empty set removes the key.
def store(keyspace: Keyspace.Keyspace, key: Bytes, members: Members, now_ms: Int) -> Keyspace.Keyspace
  return Keyspace.delete(keyspace, key) if members.slots.empty?

  Keyspace.put(keyspace, key, Value.Members(members.index, members.slots), now_ms)
end

## The keyspace with `members` as a new value at the key, whatever it held and
## whatever deadline it had (setKey, which the STORE commands use); an empty set
## removes the key.
def replace(keyspace: Keyspace.Keyspace, key: Bytes, members: Members) -> Keyspace.Keyspace
  return Keyspace.delete(keyspace, key) if members.slots.empty?

  Keyspace.set(keyspace, key, Value.Members(members.index, members.slots))
end

def empty() -> Members = Members(index: {}, slots: {})

def size(members: Members) -> Int = members.slots.size

def has?(members: Members, member: Bytes) -> Bool = members.index.has_key?(member)

## The set with `member` added; a member that is there leaves it as it is.
def add(members: Members, member: Bytes) -> Members
  return members if has?(members, member)

  slot = members.slots.size
  Members(index: members.index.put(member, slot), slots: members.slots.put(slot, member))
end

## The set without `member`: the last member takes its slot.
def remove(members: Members, member: Bytes) -> Members
  case members.index.get(member)
    none -> members
    some(slot) ->
      last = members.slots.size - 1
      moved = members.slots.get(last, member)
      slots = members.slots.delete(last)
      index = members.index.delete(member)
      return Members(index: index, slots: slots) if slot == last

      Members(index: index.put(moved, slot), slots: slots.put(slot, moved))
  end
end

## The sets at the keys, in order, a missing key being the empty set; none when
## a live key holds another type (Redis checks every key before it works).
def gather(keyspace: Keyspace.Keyspace, keys: List[Bytes], now_ms: Int) -> Optional[List[Members]]
  found: List[Members] = []
  for key in keys
    case held(keyspace, key, now_ms)
      Held.Foreign -> return none
      Held.Missing -> found = found.push(empty())
      Held.Found(members) -> found = found.push(members)
    end
  end

  some(found)
end

## The members of any of the sets, each once.
def union(sets: List[Members]) -> List[Bytes] = list(sets.reduce(empty()) do |all, members| merge(all, members) end)

## The members of all the sets, taken from the smallest one: at most `limit` of
## them when `limit` is above 0 (SINTERCARD stops there).
def intersection(sets: List[Members], limit: Int) -> List[Bytes]
  return [] if sets.empty?

  ordered = sets.sort_by do |members| size(members) end
  others = ordered.drop(1)
  common: List[Bytes] = []
  for member in list(ordered[0])
    if in_all?(others, member)
      common = common.push(member)
      break if limit > 0 and common.size >= limit
    end
  end

  common
end

## The members of the first set that no other one has.
def difference(sets: List[Members]) -> List[Bytes]
  return [] if sets.empty?

  others = sets.drop(1)
  list(sets[0]).select do |member| not in_any?(others, member) end
end

## The member in a slot, 0 up to size - 1.
def at(members: Members, slot: Int) -> Bytes = members.slots.get(slot, "".bytes)

## All the members, in slot order.
def list(members: Members) -> List[Bytes] = members.slots.values

def from_list(items: List[Bytes]) -> Members = items.reduce(empty()) do |members, item| add(members, item) end

private

def merge(into: Members, more: Members) -> Members = list(more).reduce(into) do |all, member| add(all, member) end

def in_all?(sets: List[Members], member: Bytes) -> Bool = sets.all? do |members| has?(members, member) end

def in_any?(sets: List[Members], member: Bytes) -> Bool = sets.any? do |members| has?(members, member) end
